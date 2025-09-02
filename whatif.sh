#!/usr/bin/env bash
set -euo pipefail

# whatif.sh
# Packages the infra folder into a universal package and publishes it to Azure DevOps,
# then removes the local packaged artifact directory.
# Requirements:
#  - Azure CLI installed and logged in (az login)
#  - Azure DevOps extension installed (az extension add --name azure-devops)
#  - Proper permissions to publish to the target feed
# Usage: ./whatif.sh [optional-base-name] [--dry-run]
# Environment toggles:
#   FORCE_PLAIN_VERSION=1        -> use plain 4-part numeric version immediately
#   CREATE_FEED_IF_MISSING=1     -> attempt to create the feed if it does not exist
#   WHATIF_DEBUG=1               -> enable bash xtrace

if [[ "${WHATIF_DEBUG:-}" == 1 ]]; then
  set -x
fi

ORG_URL="https://dev.azure.com/jonathanlittleton0381/"
FEED="terraform-temporary-plans"
INFRA_DIR="infra"
DRY_RUN=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    *)
      POSITIONAL+=("$arg")
      ;;
  esac
done
set -- "${POSITIONAL[@]}"

BASENAME="${1:-my-first-package}"
DATE_TAG="$(date +%Y.%m.%d)"            # e.g., 2025.09.01
TIME_TAG="$(date +%H%M%S)"              # e.g., 142355
## Versioning rules (Azure DevOps Universal Packages):
# * Must be lowercase SemVer 2.0
# * No build metadata ('+' segment) allowed
# We'll derive: MAJOR=year, MINOR=month, PATCH=day (numeric, no leading zeros) and append a numeric prerelease time -HHMMSS
# This yields e.g. 2025.9.1-202215 (which is SemVer compliant and lowercase)
YEAR=$(date +%Y)
MONTH=$(date +%m); MONTH=$((10#$MONTH))
DAY=$(date +%d); DAY=$((10#$DAY))
MAJOR="$YEAR"; MINOR="$MONTH"; PATCH="$DAY"
VERSION_BASE="${MAJOR}.${MINOR}.${PATCH}"
PRERELEASE="$(date +%H%M%S)"  # time portion for uniqueness
VERSION="${VERSION_BASE}-${PRERELEASE}"  # primary attempt WITHOUT build metadata

# If user forces plain version (no prerelease) use base; optionally bump patch with seconds for uniqueness
if [[ -n "${FORCE_PLAIN_VERSION:-}" ]]; then
  # Patch uniqueness: add seconds since midnight to patch if requested
  if [[ -n "${UNIQUE_PATCH:-}" ]]; then
    SECS=$((10#$(date +%H)*3600 + 10#$(date +%M)*60 + 10#$(date +%S)))
    PATCH=$((PATCH))
    VERSION="${MAJOR}.${MINOR}.$((PATCH))"  # base
    VERSION="${MAJOR}.${MINOR}.$((PATCH))"  # keep simple; user requested plain
  else
    VERSION="${VERSION_BASE}"  # no prerelease
  fi
fi

DESCRIPTION="Universal package snapshot of repo 'local-infra-tool' infra folder on $(date -Iseconds)"

if [ ! -d "$INFRA_DIR" ]; then
  echo "Error: $INFRA_DIR directory not found" >&2
  exit 1
fi

if ! az account show >/dev/null 2>&1; then
  echo "Warning: Not logged into Azure (az account show failed). Run 'az login' if publish fails." >&2
fi

# Check feed existence (ignore errors unless user wants auto-create)
if ! az artifacts feed show --organization "$ORG_URL" --feed "$FEED" >/dev/null 2>&1; then
  echo "Info: Feed '$FEED' not found or inaccessible." >&2
  if [[ "${CREATE_FEED_IF_MISSING:-}" == 1 ]]; then
    echo "Attempting to create feed '$FEED'..." >&2
    if ! az artifacts feed create --organization "$ORG_URL" --name "$FEED" >/dev/null 2>&1; then
      echo "Warning: Failed to create feed '$FEED'. Continuing; publish will likely fail." >&2
    else
      echo "Feed '$FEED' created." >&2
    fi
  fi
fi

# Create a temp staging directory to publish (Azure universal packages publish a path)
STAGING_DIR=".whatif_package_staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy infra contents
cp -R "$INFRA_DIR" "$STAGING_DIR/"  # results in .whatif_package_staging/infra

# Show tree (best effort)
if command -v tree >/dev/null 2>&1; then
  tree "$STAGING_DIR" || true
else
  find "$STAGING_DIR" -maxdepth 4 -print
fi

echo "Publishing universal package: feed=$FEED name=$BASENAME version=$VERSION (dry-run=$DRY_RUN)" >&2

# Ensure azure devops extension context (optional; user may have set az devops configure defaults)
if ! az extension show --name azure-devops >/dev/null 2>&1; then
  echo "Azure DevOps CLI extension not found. Installing..." >&2
  az extension add --name azure-devops
fi

# Optionally set defaults (commented out to avoid overriding user config)
# az devops configure --defaults organization="$ORG_URL" project="<PROJECT_NAME>"

PUBLISH_LOG="publish_full.log"
rm -f publish.err "$PUBLISH_LOG" || true

attempt_publish() {
  local ver="$1"
  echo "Attempting publish with version=$ver" >&2
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY RUN: az artifacts universal publish --organization '$ORG_URL' --feed '$FEED' --name '$BASENAME' --version '$ver' --description '$DESCRIPTION' --path '$STAGING_DIR'" >&2
    return 0
  fi
  az artifacts universal publish \
    --organization "$ORG_URL" \
    --feed "$FEED" \
    --name "$BASENAME" \
    --version "$ver" \
    --description "$DESCRIPTION" \
    --path "$STAGING_DIR" 1>"$PUBLISH_LOG" 2>publish.err
}

STATUS=0
attempt_publish "$VERSION" || STATUS=$?

## Fallback logic if invalid version error occurs
if [[ $STATUS -ne 0 ]]; then
  if grep -qi 'version provided is invalid' publish.err 2>/dev/null; then
    echo "Detected invalid version error. Applying fallbacks..." >&2
    # 1. Retry without prerelease (base version)
    CLEAN_VERSION="$VERSION_BASE"
    attempt_publish "$CLEAN_VERSION" || STATUS=$?
    if [[ $STATUS -eq 0 ]]; then
      VERSION="$CLEAN_VERSION"
    else
      # 2. Increment patch up to 5 attempts
      i=1
      while [[ $i -le 5 && $STATUS -ne 0 ]]; do
        NEW_PATCH=$((PATCH + i))
        NEXT_VERSION="${MAJOR}.${MINOR}.${NEW_PATCH}"
        echo "Retrying with incremented patch: $NEXT_VERSION" >&2
        attempt_publish "$NEXT_VERSION" || STATUS=$?
        if [[ $STATUS -eq 0 ]]; then
          VERSION="$NEXT_VERSION"
          break
        fi
        i=$((i+1))
      done
      # 3. As last resort append a lowercase prerelease tag 'a' + time (if not already plain base)
      if [[ $STATUS -ne 0 ]]; then
        LAST_VERSION="${MAJOR}.${MINOR}.${PATCH}-a${PRERELEASE}"
        echo "Final fallback with prerelease: $LAST_VERSION" >&2
        attempt_publish "$LAST_VERSION" || STATUS=$?
        if [[ $STATUS -eq 0 ]]; then
          VERSION="$LAST_VERSION"
        fi
      fi
    fi
  fi
fi

if [[ $STATUS -ne 0 ]]; then
  echo "Publish failed after fallbacks (exit $STATUS). See publish.err (if any) and $PUBLISH_LOG." >&2
  [[ -f publish.err ]] && sed 's/^/FINAL_ERR: /' publish.err >&2 || true
  rm -rf "$STAGING_DIR"
  exit $STATUS
fi

echo "Publish succeeded for version $VERSION." >&2
[[ -f "$PUBLISH_LOG" ]] && head -n 30 "$PUBLISH_LOG" | sed 's/^/LOG: /' >&2 || true

echo "Cleaning up staging directory..." >&2
rm -rf "$STAGING_DIR"

if [ -d "$STAGING_DIR" ]; then
  echo "Warning: staging directory still exists (remove manually)." >&2
else
  echo "Cleanup complete." >&2
fi

echo "Done." >&2

#!/usr/bin/env bash
set -euo pipefail

# Creates an archive (tar.gz preferred, zip fallback) of the infra directory,
# verifies the archive exists, then deletes it.
# Usage: ./package_infra.sh [archive_basename]

INFRA_DIR="infra"
BASENAME="${1:-infra-archive}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE=""

if [ ! -d "$INFRA_DIR" ]; then
  echo "Error: $INFRA_DIR directory not found" >&2
  exit 1
fi

create_tar() {
  local name="$BASENAME-$TIMESTAMP.tar.gz"
  tar -czf "$name" "$INFRA_DIR" 2>/dev/null || return 1
  ARCHIVE="$name"
  return 0
}

create_zip() {
  local name="$BASENAME-$TIMESTAMP.zip"
  zip -rq "$name" "$INFRA_DIR" 2>/dev/null || return 1
  ARCHIVE="$name"
  return 0
}

if command -v tar >/dev/null 2>&1; then
  if ! create_tar; then
    echo "tar command present but failed, attempting zip fallback" >&2
    if ! command -v zip >/dev/null 2>&1 || ! create_zip; then
      echo "Error: failed to create archive with tar or zip" >&2
      exit 1
    fi
  fi
elif command -v zip >/dev/null 2>&1; then
  if ! create_zip; then
    echo "Error: failed to create archive with zip" >&2
    exit 1
  fi
else
  echo "Error: neither tar nor zip is available in PATH" >&2
  exit 1
fi

if [ -z "$ARCHIVE" ]; then
  echo "Error: archive variable empty after attempt" >&2
  exit 1
fi

if [ ! -f "$ARCHIVE" ]; then
  echo "Error: archive $ARCHIVE not found after creation" >&2
  exit 1
fi

echo "Created archive: $ARCHIVE (size: $(wc -c < "$ARCHIVE") bytes)"

# Verification: list contents (first few lines) for transparency
if [[ "$ARCHIVE" == *.tar.gz ]]; then
  echo "Archive contents (tar):"
  tar -tzf "$ARCHIVE" | head -n 10
elif [[ "$ARCHIVE" == *.zip ]]; then
  echo "Archive contents (zip):"
  unzip -l "$ARCHIVE" | head -n 10
fi

echo "Deleting archive $ARCHIVE..."
rm -f -- "$ARCHIVE"

if [ -f "$ARCHIVE" ]; then
  echo "Error: failed to delete $ARCHIVE" >&2
  exit 1
fi

echo "Archive verification complete and file removed successfully."

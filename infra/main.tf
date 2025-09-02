terraform {
  required_providers {
    random = {
      source = "hashicorp/random"
      version = ">= 3.0.0"
    }
  }
}

provider "random" {}

resource "random_pet" "test" {
  length    = 2
  separator = "-"
}

output "pet_name" {
  value = random_pet.test.id
}

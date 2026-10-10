# =============================================================================
# versions.tf — the official Octopus provider, PINNED (CLAUDE.md §0.5).
# 1.20.0 resolved from the Terraform registry 2026-10-10 (published 2026-09-21).
#
# Credentials: the API key is read from OCTOPUS_APIKEY in the environment — never
# a variable, never a file. It belongs to a SERVICE ACCOUNT with Space manager
# on this space (CICD design notes §8 for the key's handling).
# =============================================================================

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    octopusdeploy = {
      source  = "OctopusDeploy/octopusdeploy"
      version = "1.20.0"
    }
  }
}

provider "octopusdeploy" {
  address = var.octopus_server_url
}

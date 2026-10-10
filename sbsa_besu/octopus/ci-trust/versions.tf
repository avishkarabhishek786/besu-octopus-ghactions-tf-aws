# =============================================================================
# versions.tf — the same provider pin as octopus/terraform (1.20.0, CD-67).
#
# Credentials: OCTOPUS_APIKEY in the environment, belonging to an Octopus
# ADMINISTRATOR — not the besu-terraform Space-manager key. Users and user roles
# are system-level objects; a Space manager cannot create them, and must not be
# able to: this root decides what CI may do in Octopus (see main.tf).
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

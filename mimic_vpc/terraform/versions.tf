# =============================================================================
# versions.tf
# -----------------------------------------------------------------------------
# Pins Terraform core and the AWS provider, and configures the provider with the
# mandatory default tag set applied to every taggable resource.
#
# Pinned to match the `besu-aws` reference repository so that behaviour observed
# there is reproducible here. 1.5.0 is the core floor because it introduced
# `check` blocks.
#
# This project needs ONLY the AWS provider. There is deliberately no kubernetes
# or helm provider: this project owns the network and nothing else (CLAUDE.md
# prime directive 3). If you find yourself adding one, you are building
# something that belongs in `sbsa_besu`.
# =============================================================================

terraform {
  required_version = ">= 1.10.0" # use_lockfile (S3-native state locking) landed in 1.10;
  #                                       DynamoDB locking is deprecated as of 1.11 and we do
  #                                       not use it. A 1.5-1.9 CLI cannot init these backends.

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

locals {
  common_tags = {
    Project       = var.project_name
    Environment   = var.environment
    ManagedBy     = "terraform"
    DeletionGroup = var.deletion_group
    Owner         = var.owner
    CostCenter    = var.cost_center
    # Marks every resource as belonging to the SIMULATED network layer. In
    # production these resources are the cloud team's and carry their tags.
    NetworkOwner = "cloud-team-mimic"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

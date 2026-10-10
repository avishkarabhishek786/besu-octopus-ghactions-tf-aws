# =============================================================================
# versions.tf
# -----------------------------------------------------------------------------
# Pinned to the same lines as the sibling mimics so behaviour is reproducible.
# Only the AWS provider: this project creates one IAM role and its policy.
# =============================================================================

terraform {
  required_version = ">= 1.10.0" # use_lockfile (S3-native state locking) landed in 1.10

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
    # In production the registry and this grant are the cloud team's (CD-27).
    NetworkOwner = "cloud-team-mimic"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

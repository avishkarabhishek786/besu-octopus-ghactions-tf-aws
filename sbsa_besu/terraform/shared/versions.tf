# =============================================================================
# versions.tf — the `shared` root
# -----------------------------------------------------------------------------
# Mirrors the chain root's pinning and default_tags contract, trimmed to the
# providers this root actually uses. `shared` creates only VPC endpoints and a
# private hosted zone: pure AWS-layer, no Kubernetes or Helm, so it applies
# fine from the laptop (no in-VPC runner required).
#
# The `aws.primary` alias is kept even though there is one region, so every
# root in this repository passes providers to modules the same way.
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
  }
}

provider "aws" {
  alias  = "primary"
  region = var.primary_region

  default_tags {
    tags = merge(local.common_tags, { Region = "primary" })
  }
}

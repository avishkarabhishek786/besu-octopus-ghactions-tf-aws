# =============================================================================
# versions.tf — same pins as the platform roots.
# =============================================================================

terraform {
  required_version = ">= 1.10.0" # use_lockfile (S3-native state locking)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project       = var.project_name
      ManagedBy     = "terraform"
      DeletionGroup = var.deletion_group
      Owner         = var.owner
      CostCenter    = var.cost_center
      Component     = "octopus-aws-trust"
    }
  }
}

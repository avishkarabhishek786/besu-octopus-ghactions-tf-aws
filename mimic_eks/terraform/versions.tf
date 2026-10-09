terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5"
    }
  }
}

# B25 (2026-10-09): this block was MISSING. With no provider "aws" the provider
# fell back to the laptop profile's default region (us-east-1), so the first
# apply built its IAM roles, KMS key and log group there and then failed on
# InvalidVpcID.NotFound — the VPC is in af-south-1. The region_agreement gate
# passed throughout, because it compared two variables that were both right;
# it now also asserts the region the provider is ACTUALLY using.
provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

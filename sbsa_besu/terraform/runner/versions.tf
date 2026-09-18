# =============================================================================
# terraform/runner/versions.tf — the in-VPC RUNNER as its OWN root/state (C1)
# -----------------------------------------------------------------------------
# WHY A SEPARATE ROOT (C1, F4/F5). The runner used to live in the chain root and
# was gated on `deploy_runner`. Because it SHARED the chain's state, a chain
# `terraform apply` without `-var deploy_runner=true` planned to DESTROY the
# runner (F5), and the flag had to come after -var-file (F4). Moving it to its
# own state removes both traps: the chain apply can never touch the runner, and
# the runner apply can never touch the chain. The runner reads what it needs
# (VPC/subnet/cluster/SG + the bootstrap secret names + repo URL) from the chain
# root's outputs via terraform_remote_state — the same "don't mix" seam app/infra
# uses. This root is pure AWS-layer (EC2 + IAM + EKS access entry + secret reads),
# so it applies fine from the laptop.
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

provider "aws" {
  region = var.region

  # Mirror the chain's tagging so the runner carries Project/DeletionGroup/etc.
  # (the full-delete script keys on DeletionGroup). Values read from chain state.
  default_tags {
    tags = {
      Project       = try(local.chain.project_name, "besu-aws")
      Environment   = "prod"
      ManagedBy     = "terraform"
      DeletionGroup = try(local.chain.deletion_group, "unknown")
      Component     = "runner"
      Region        = "primary"
    }
  }
}

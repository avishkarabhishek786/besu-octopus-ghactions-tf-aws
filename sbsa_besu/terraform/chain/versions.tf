# =============================================================================
# versions.tf
# -----------------------------------------------------------------------------
# PURPOSE
#   Pins the Terraform core version and every provider version used by this
#   repository, and configures the AWS providers (one per region) with the
#   MANDATORY default tag set that is applied automatically to every taggable
#   resource Terraform creates.
#
# WHY THIS FILE MATTERS
#   * Version pinning makes deployments reproducible. An unpinned provider can
#     silently change behaviour between `terraform init` runs on different
#     machines or different days, which for production financial infrastructure
#     is unacceptable. We pin to a known-good MAJOR.MINOR and allow only patch
#     drift via the "~>" pessimistic operator.
#   * `default_tags` on the provider is how we guarantee EVERY resource is
#     tagged consistently without having to remember to tag each resource by
#     hand. This is the backbone of:
#       - cost allocation (filter the AWS bill by Project / DeletionGroup)
#       - the AWS Resource Group (see modules/resource-group)
#       - the full-delete script (scripts/maintenance/full-delete.sh discovers
#         resources by the DeletionGroup tag)
#
# AWS PROVIDER (single, aliased `primary`)
#   The deployment is single-region. The provider keeps the `aws.primary` alias
#   so modules receive it explicitly via `providers = { aws = aws.primary }` from
#   main.tf (a stable convention, even with one region).
# =============================================================================

terraform {
  # ---------------------------------------------------------------------------
  # Terraform core version.
  # 1.5.0 is the floor because that release introduced `check` blocks and
  # stabilised several features we rely on. We do NOT pin an upper bound on the
  # core version here; CI should pin the exact core version separately.
  # ---------------------------------------------------------------------------
  required_version = ">= 1.10.0" # use_lockfile (S3-native state locking) landed in 1.10;
  #                                       DynamoDB locking is deprecated as of 1.11 and we do
  #                                       not use it. A 1.5-1.9 CLI cannot init these backends.

  required_providers {
    # AWS provider: the workhorse. Pinned to the 5.x line. 5.x is required for
    # current EKS (1.31+) addon handling, EKS Pod Identity, and gp3 defaults.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }

    # TLS provider: used by the self-managed CA path (modules/pki in a later
    # stage) to generate the CA key/cert and to sign CSRs without an external
    # dependency. Declared here so the lockfile is complete from stage 1.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }

    # Helm provider: drives `helm_release` resources that deploy the Besu charts
    # and kube-prometheus-stack. Used from later stages; declared now so all
    # stages share one lockfile.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }

    # Kubernetes provider: applies raw manifests (PDBs, ConfigMaps, the
    # permissioning files) that are not owned by a Helm chart.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }

    # TLS/keypair + random helpers used for secret material naming and keystore
    # passwords in later stages.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# -----------------------------------------------------------------------------
# locals: the canonical tag set.
# -----------------------------------------------------------------------------
# These locals build the tag map ONCE so both providers (and any module that
# needs to read the tags, e.g. the Resource Group) use an identical set.
#
# Tag meanings:
#   Project       Static identifier for this whole system. Lets you find all
#                 Besu infra across deployments.
#   Environment   From var.environment ("sit" | "uat" | "prod"). NOT hardcoded: deploy-tests
#                 run in us-east-1 and production in af-south-1, and tagging test
#                 resources as "prod" would corrupt cost allocation and make a
#                 test deployment indistinguishable from the real one.
#   ManagedBy     Always "terraform" — signals to humans NOT to hand-edit these
#                 resources in the console (doing so causes drift).
#   DeletionGroup A UNIQUE-per-deployment id (from var.deletion_group). This is
#                 the single most important operational tag: the full-delete
#                 script targets EXACTLY this value, so a second independent
#                 deployment in the same account is never caught in the blast
#                 radius. Treat it like a deployment serial number.
#   Owner         Team/email accountable for the resources (from var.owner).
#   CostCenter    For finance chargeback (from var.cost_center).
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Region provider (var.primary_region). default_tags here mean: every resource
# created with this provider gets common_tags PLUS Region=primary, merged.
# Resource-level tags (if any) override these on key collision, which is the
# documented AWS provider behaviour.
# -----------------------------------------------------------------------------
provider "aws" {
  alias  = "primary"
  region = var.primary_region

  default_tags {
    tags = merge(local.common_tags, { Region = "primary" })
  }
}

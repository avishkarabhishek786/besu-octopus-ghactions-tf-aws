# =============================================================================
# main.tf (root) — wires the two modules.
# -----------------------------------------------------------------------------
# This project creates a VPC, 15 subnets, 15 route tables, 3 NACLs, a DHCP
# option set, flow logs, and (by default) two free gateway endpoints.
#
# IT CREATES NOTHING ELSE. In particular there is no Internet Gateway, no NAT
# Gateway, no Elastic IP, no public subnet and no 0.0.0.0/0 route anywhere —
# CLAUDE.md prime directive 2, which has no toggle and no exception. If a
# downstream component cannot work without egress, that is a finding to fix in
# `sbsa_besu`, not a reason to weaken this project.
# =============================================================================

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

module "vpc" {
  source = "./modules/vpc"

  name_prefix             = local.name_prefix
  region                  = var.region
  vpc_cidr                = var.vpc_cidr
  enable_secondary_cidr   = var.enable_secondary_cidr
  secondary_cidr          = var.secondary_cidr
  enable_flow_logs        = var.enable_flow_logs
  flow_log_retention_days = var.flow_log_retention_days
  tags                    = {}
}

module "subnets" {
  source = "./modules/subnets"

  name_prefix = local.name_prefix
  region      = var.region
  vpc_id      = module.vpc.vpc_id

  subnets        = local.subnets
  lb_subnet_tags = local.lb_subnet_tags

  gateway_endpoints_created_here = var.gateway_endpoints_created_here
  simulate_central_endpoints     = var.simulate_central_endpoints

  # CT-1a / D-32 — the cloud team's subnet security rules. Deny-by-default,
  # permitting only requirement #34's F-1..F-10. The old allow-all baseline is
  # still reachable as nacl_mode = "permissive", but it is no longer the default,
  # because a fixture that cannot reject anything cannot prove a checker works.
  vpc_cidr          = var.vpc_cidr
  nacl_mode         = var.nacl_mode
  nacl_break_flow   = var.nacl_break_flow
  s3_cidrs          = var.s3_cidrs
  egress_proxy_cidr = var.egress_proxy_cidr
  egress_proxy_port = var.egress_proxy_port
  sipn_cidr         = var.sipn_cidr

  nacl_source_mode      = var.nacl_source_mode
  ledger_subnets_in_use = var.ledger_subnets_in_use
  nacl_rule_limit       = var.nacl_rule_limit

  tags = {}

  # The secondary CIDR association must exist before subnets are created, so
  # that a later move to VPC CNI custom networking finds the block already
  # attached rather than requiring a VPC change on a live ledger (#17).
  depends_on = [module.vpc]
}

# -----------------------------------------------------------------------------
# Post-apply contract assertions.
# -----------------------------------------------------------------------------
# `check` blocks report WITHOUT failing the apply, which is what we want here:
# these validate the SHAPE of the hand-over, and a warning that names the broken
# requirement is more useful during iteration than a hard stop.
#
# scripts/verify-contract.sh re-asserts the same things against the live AWS API
# rather than against state — that is the authoritative gate.
# -----------------------------------------------------------------------------
check "subnet_plan_is_coherent" {
  assert {
    condition     = length(local.subnets) == 15 && length(distinct([for k, v in local.subnets : v.cidr])) == 15
    error_message = "Subnet plan must yield 15 subnets with 15 DISTINCT CIDRs. A duplicate means two roles collided on a cidrsubnet() netnum in locals.tf."
  }
}

# No subnet can land in the secondary CIDR by construction: every CIDR in the
# plan is derived with cidrsubnet(var.vpc_cidr, ...), and vpc_cidr is validated
# to be the /20 primary. #17 is therefore enforced by the derivation itself, and
# re-asserted against live AWS by scripts/verify-contract.sh.

check "distinct_lb_and_endpoint_subnets" {
  assert {
    condition = length(setintersection(
      toset([for k, v in local.subnets : v.cidr if v.role == "lb"]),
      toset([for k, v in local.subnets : v.cidr if v.role == "endpoint"]),
    )) == 0
    error_message = "#16: endpoint subnets must be distinct from load-balancer subnets."
  }
}

# -----------------------------------------------------------------------------
# REGION PORTABILITY GATE.
# -----------------------------------------------------------------------------
# The whole configuration is region-parameterised: switching production to
# af-south-1 is a tfvars change, not a code change. The one input that does NOT
# travel is `az_ids` — AZ IDs are region-scoped (use1-az1 vs afs1-az1), so a
# region switch with stale AZ IDs is the obvious way to get this wrong.
#
# Without this gate the failure is a confusing "InvalidParameterValue" partway
# through creating subnets. With it, the plan refuses immediately and says why.
#
# terraform_data creates no infrastructure — it is an assertion carrier. A
# `check` block would only warn, and this must block.
# -----------------------------------------------------------------------------
data "aws_availability_zones" "this" {
  state = "available"
}

resource "terraform_data" "az_ids_belong_to_region" {
  input = var.az_ids

  lifecycle {
    precondition {
      condition     = length(setsubtract(toset(var.az_ids), toset(data.aws_availability_zones.this.zone_ids))) == 0
      error_message = "az_ids ${jsonencode(var.az_ids)} are not all valid in region ${var.region}. Valid AZ IDs here: ${jsonencode(data.aws_availability_zones.this.zone_ids)}. AZ IDs are region-scoped — update az_ids in the tfvars when you change region."
    }
  }
}

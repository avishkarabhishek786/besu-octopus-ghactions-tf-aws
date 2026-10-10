# =============================================================================
# variables.tf  (root)
# -----------------------------------------------------------------------------
# Every value the cloud team would decide when provisioning the shared VPC.
# Nothing here is hardcoded downstream: the subnet plan in locals.tf is derived
# from var.vpc_cidr, and AZ placement is derived from var.az_ids.
#
# Requirement numbers (#N) refer to docs/spec/network-requirements.md.
# =============================================================================

# --- Identity & tagging -------------------------------------------------------
variable "project_name" {
  description = "Project identifier used in resource names and the Project tag."
  type        = string
  default     = "sbsa-besu"
}

variable "environment" {
  description = "Environment name (sit | uat | prod), matching the Octopus environments SIT, UAT and PROD. All three run in af-south-1."
  type        = string
}

variable "deletion_group" {
  description = "UNIQUE per deployment. Teardown tooling keys on this tag."
  type        = string
}

variable "owner" {
  description = "Team or email accountable for these resources."
  type        = string
}

variable "cost_center" {
  description = "Cost centre for chargeback."
  type        = string
}

# --- Region & AZs -------------------------------------------------------------
variable "region" {
  description = "AWS region. af-south-1 (Africa, Cape Town) for ALL THREE environments -- a deploy-test in another region does not prove endpoint availability, per-AZ instance types or AZ IDs. OPT-IN region: enable it on the account first."
  type        = string
}

variable "az_ids" {
  description = <<-EOT
    #5 — Availability Zone IDs, NOT names. AZ names map to different physical
    zones in different accounts, so the hand-over must be expressed in AZ IDs
    (af-south-1: afs1-az1/2/3; us-east-1: use1-az1/2/4...). Exactly 3 required
    for QBFT validator topology spread.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.az_ids) == 3
    error_message = "#5: exactly 3 AZ IDs are required (QBFT validator spread across 3 AZs)."
  }
}

# --- Addressing ---------------------------------------------------------------
variable "vpc_cidr" {
  description = <<-EOT
    #7 — Primary VPC CIDR. MUST be a /20: the subnet plan in locals.tf is
    calculated for a /20 and allocates 2,880 of 4,096 addresses, leaving 1,216
    in reserve. See docs/spec Appendix A for the sizing derivation.
  EOT
  type        = string
  default     = "10.60.0.0/20"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && tonumber(split("/", var.vpc_cidr)[1]) == 20
    error_message = "#7: vpc_cidr must be a valid /20. The subnet plan in locals.tf is derived for a /20 only.\n\nThis stays a HARD /20 (2026-09-09): a /20 per environment is what we have formally requested from the cloud team (sbsa_besu/docs/CIDR_ALLOCATION_REVIEW.md), so the mimic must keep rehearsing the shape we intend to be given. The offered allocations were SIT 10.103.53.0/24, UAT 10.103.0.0/21, PROD 10.108.13.0/24; if the request is refused, change the plan HERE FIRST and re-run a rehearsal, because a mimic that does not match production proves the platform works rather than that it fits."
  }
}

variable "enable_secondary_cidr" {
  description = "#17 — associate the CG-NAT secondary CIDR. Held UNUSED; no subnets are created in it."
  type        = bool
  default     = true
}

variable "secondary_cidr" {
  description = <<-EOT
    #17 — Carrier-grade NAT space (RFC 6598), associated but deliberately unused.
    Costs the cloud team nothing (not RFC 1918, never routed outside the VPC) and
    converts a future move to VPC CNI custom networking from a rolling replacement
    of every node into a configuration change. Use 198.19.0.0/16 if 100.64.0.0/10
    is already in use on the bank network.
  EOT
  type        = string
  default     = "100.64.0.0/16"
}

# --- EKS discovery tags -------------------------------------------------------
variable "ledger_cluster_name" {
  description = "Name of the ledger EKS cluster. Used for subnet discovery tags (#4)."
  type        = string
  default     = "sbsa-besu-ledger"
}

variable "app_cluster_name" {
  description = "Name of the application EKS cluster. Used for subnet discovery tags (#4)."
  type        = string
  default     = "sbsa-besu-app"
}

# --- Ownership toggles (mimic the cloud team's answer to open questions) ------
variable "gateway_endpoints_created_here" {
  description = <<-EOT
    #10 — Creating an S3/DynamoDB gateway endpoint writes a route into every
    route table it associates with, and the route tables are the cloud team's.

      true  = this project creates them (mimics the cloud team accepting #10 by
              creating the endpoints themselves).
      false = not created here; the platform creates them (mimics the cloud team
              granting association permission instead).

    Both are free. EXERCISE BOTH PATHS at least once — the real answer to #10 is
    not yet known and the platform must work either way.
  EOT
  type        = bool
  default     = true
}

variable "simulate_central_endpoints" {
  description = <<-EOT
    Q-2 — when true, this project creates the interface endpoints, mimicking a
    cloud team that operates them centrally. Default false: the platform creates
    its own (decision D-11), which is the position we have asked for.
  EOT
  type        = bool
  default     = false
}

# --- Flow logs ----------------------------------------------------------------
variable "enable_flow_logs" {
  description = "VPC-level flow logs. In production these are the cloud team's; the platform adds subnet-level logs on the ledger subnets (#14)."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "CloudWatch retention for VPC flow logs. Keep SHORT in deploy-tests — this is the only billable resource in this project."
  type        = number
  default     = 7
}

# =============================================================================
# Subnet security rules (CT-1a, D-29, D-32) — added 2026-10-09
# =============================================================================
# The cloud team said their subnets have security rules defined. Until
# 2026-10-09 this project shipped an allow-all NACL baseline on the ledger
# subnets with a comment deferring the rules to the platform. That was wrong in
# both directions — the rules are THEIRS under CT-1a, and an allow-all fixture
# cannot reject anything, so the platform's verify-subnet-rules.sh would have
# been written against a check that could never fail (B12).
#
# Full reasoning, including what a stateless ACL cannot protect: see
# modules/subnets/nacl.tf.
# =============================================================================

variable "nacl_mode" {
  description = "flows (default — deny by default, only #34's F-1..F-10 and the cluster's own C-1..C-4) | permissive (the old allow-all baseline, for bisecting a connectivity problem) | none (no NACLs; models a security-groups-only cloud team, question C)."
  type        = string
  default     = "flows"
}

variable "nacl_break_flow" {
  description = "Drop every NACL rule whose flow label contains this string, so the platform's checker is proven to detect an ABSENT rule. Try \"F-1 peer UDP\" (discovery dies while the chain looks fine), \"F-6\" (pulls stall mid-layer) or \"F-5\" (every AWS call hangs)."
  type        = string
  default     = ""
}

variable "s3_cidrs" {
  description = "#34 F-6 — S3's regional prefixes. A NACL cannot reference a prefix list; empty falls back to 0.0.0.0/0, which is what a real cloud team would most likely do."
  type        = list(string)
  default     = []
}

variable "egress_proxy_cidr" {
  description = "#34 F-8 — the egress proxy's prefix (mimic_egress emits it as egress_vpc_cidr). Empty omits the rule, modelling the R-10 ticket not yet being answered."
  type        = string
  default     = ""
}

variable "egress_proxy_port" {
  description = "#34 F-8 — the proxy's CONNECT port."
  type        = number
  default     = 3128
}

variable "sipn_cidr" {
  description = "The prefix SWIFT reaches the RPC NLBs from over MV-SIPN. Empty falls back to the VPC CIDR, which is what a mimic with no Transit Gateway can actually test."
  type        = string
  default     = ""
}

variable "nacl_source_mode" {
  description = "summarised (default — fits AWS's 20-rule-per-direction NACL limit) | narrow (per-subnet sources everywhere; needs the quota raised to 40). See modules/subnets/variables.tf for the arithmetic."
  type        = string
  default     = "summarised"
}

variable "ledger_subnets_in_use" {
  description = "#28 — true only when a dedicated ledger node group was granted AND our pods run in the ledger subnets. Under CT-5 the default is false: our pods land in the application subnets."
  type        = bool
  default     = false
}

variable "nacl_rule_limit" {
  description = "AWS's per-NACL per-direction rule quota. 20 by default, 40 after a quota increase. The subnets module fails the PLAN rather than letting AWS reject a rule mid-apply."
  type        = number
  default     = 20
}

# =============================================================================
# variables.tf  (root)
# -----------------------------------------------------------------------------
# Every value the cloud team would decide when running a shared egress service —
# plus the two things they would take from OUR ticket (R-10): the source address
# to allowlist and the Octopus instance whose two hostnames are the only
# permitted destinations.
#
# Nothing here is hardcoded downstream. Decision references (CD-N) point at
# sbsa_besu/docs/CICD_DESIGN_NOTES.md §3 / §7.3.
# =============================================================================

# --- Identity & tagging -------------------------------------------------------
variable "project_name" {
  description = "Project identifier used in resource names and the Project tag."
  type        = string
  default     = "sbsa-besu"
}

variable "environment" {
  description = "Environment name (sit | uat | prod), matching the Octopus environments. Must match the mimic_vpc environment whose hand-over this project consumes."
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

# --- Region & AZ --------------------------------------------------------------
variable "region" {
  description = "AWS region. Must equal the ledger VPC's region (network_region in the hand-over) — a VPC peering is same-region here by design; the bank's TGW is regional too."
  type        = string
}

variable "az_id" {
  description = <<-EOT
    AZ ID (not name) for the egress VPC's single public subnet. The bank's VIP is
    multi-AZ; a mimic's need not be — one AZ keeps the proxy and the NLB node in
    the same zone and the bill at one instance. Pick one of the ledger's az_ids so
    the peering path is intra-AZ (no cross-AZ data charge on the polling channel).
  EOT
  type        = string
}

# --- Addressing ---------------------------------------------------------------
variable "egress_vpc_cidr" {
  description = <<-EOT
    CIDR of the egress VPC. A /24 is plenty (one subnet, one instance, one NLB
    node). MUST NOT overlap the ledger's primary /20 OR its 100.64.0.0/16
    secondary — VPC peering refuses overlapping CIDRs, and the secondary counts
    even though it is unused. Validated against the hand-over in main.tf.
  EOT
  type        = string

  validation {
    condition     = can(cidrnetmask(var.egress_vpc_cidr)) && tonumber(split("/", var.egress_vpc_cidr)[1]) >= 16 && tonumber(split("/", var.egress_vpc_cidr)[1]) <= 26
    error_message = "egress_vpc_cidr must be a valid IPv4 CIDR between /16 and /26 (a /24 is the intended size)."
  }
}

# --- The proxy (CD-56 explicit CONNECT proxy at a VIP) ------------------------
variable "proxy_port" {
  description = "TCP port the proxy listens on and the NLB exposes. 3128 is Squid's default; banks often use 8080. A variable for exactly that reason — the platform reads it from the hand-over, never assumes it (CD-56)."
  type        = number
  default     = 3128

  validation {
    condition     = var.proxy_port > 1024 && var.proxy_port < 65536
    error_message = "proxy_port must be an unprivileged TCP port (1025-65535)."
  }
}

variable "proxy_dns_zone" {
  description = "Private hosted zone name that stands in for the bank's corporate DNS — the proxy is handed to the platform as a HOSTNAME, never an IP (CD-56). Associated to the ledger VPC so it resolves there."
  type        = string
  default     = "egress.mimic.internal"
}

variable "proxy_hostname" {
  description = "Host label for the VIP inside proxy_dns_zone. The hand-over's egress_proxy_host is `<proxy_hostname>.<proxy_dns_zone>`."
  type        = string
  default     = "proxy"
}

variable "instance_type" {
  description = "Proxy instance type. t3.micro carries a polling Tentacle's traffic with room to spare; this is a mimic, not the bank's estate."
  type        = string
  default     = "t3.micro"
}

# --- The allowlist (CD-59 destinations, CD-60 source) -------------------------
variable "octopus_instance" {
  description = <<-EOT
    The Octopus Cloud instance name — the `<instance>` in `https://<instance>.octopus.app`.
    The ONLY two permitted destinations are derived from it (CD-59):
      <instance>.octopus.app          REST (registration, octo CLI)
      polling.<instance>.octopus.app  Halibut polling over 443
    No wildcard — `.octopus.app` would admit every other customer's instance.
    For deploy-tests this is your free-tier instance; in the bank it is theirs.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.octopus_instance))
    error_message = "octopus_instance must be the bare instance label (lowercase letters, digits, hyphens) — not a URL, not a hostname."
  }
}

variable "runner_private_ip" {
  description = <<-EOT
    The platform runner's PINNED private IP — the single allowlisted SOURCE, as a
    /32 (CD-60). The platform must launch its runner with exactly this address
    (`runner_private_ip` in sbsa_besu's runner root reads it from the egress
    hand-over as `egress_allowed_source`). It must lie inside one of the ledger
    subnets and outside AWS's reserved first four / last one addresses; the
    platform validates that, the proxy simply refuses anything else.

    There is deliberately NO list here and no second source: a shared bank proxy
    allowlists per consumer, and we are asking for one address (R-10).
  EOT
  type        = string

  validation {
    condition     = can(cidrhost("${var.runner_private_ip}/32", 0))
    error_message = "runner_private_ip must be a single IPv4 address (no prefix length)."
  }
}

# --- Flow logs ----------------------------------------------------------------
variable "enable_flow_logs" {
  description = "VPC-level flow logs on the egress VPC. Useful evidence that only the runner ever reached the proxy."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "CloudWatch retention for the flow logs. Keep SHORT in deploy-tests."
  type        = number
  default     = 1
}

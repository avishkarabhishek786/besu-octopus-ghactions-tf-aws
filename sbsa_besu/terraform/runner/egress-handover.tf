# =============================================================================
# egress-handover.tf — the bank's egress service, as this root consumes it.
# -----------------------------------------------------------------------------
# Values arrive in `egress-handover.auto.tfvars` (a symlink to
# ../egress-handover.auto.tfvars, like the network hand-over), produced during
# development by the sibling project `mimic_egress/scripts/emit-handover.sh`
# and, in production, typed BY HAND from the cloud team's reply to the R-10
# ticket. Only CLIENT CONFIGURATION crosses this boundary (CD-56..CD-60):
# a hostname, a port, a routed prefix, the allowlisted source and destinations.
#
# EVERY VARIABLE IS OPTIONAL. Without the file the runner is built exactly as
# before (no pinned IP, no proxy) — the Octopus path is additive. With it, the
# runner's address defaults to the allowlisted /32 so the two cannot drift.
#
# The runner's Terraform needs only egress_allowed_source. The rest is declared
# so the shared file loads without warnings, and so install-tentacle.sh can
# read egress_proxy_host/port from the very same file on the runner (it is
# delivered there by push-deploy-config.sh).
# =============================================================================

variable "egress_allowed_source" {
  description = "Hand-over: the /32 the egress proxy admits (CD-60). When set and runner_private_ip is not, the runner is pinned to this address."
  type        = string
  default     = null

  validation {
    condition     = var.egress_allowed_source == null || can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/32$", var.egress_allowed_source))
    error_message = "egress_allowed_source must be a single IPv4 address with a /32 suffix, e.g. 10.60.0.250/32 — that is what the proxy allowlists."
  }
}

variable "egress_proxy_host" {
  description = "Hand-over: the egress VIP hostname. Consumed by install-tentacle.sh on the runner (Tentacle polling-proxy, CD-57), not by Terraform."
  type        = string
  default     = null
}

variable "egress_proxy_port" {
  description = "Hand-over: the egress VIP port. Consumed by install-tentacle.sh on the runner."
  type        = number
  default     = null
}

variable "egress_vpc_cidr" {
  description = "Hand-over: the prefix the ledger route tables route to the egress service. Informational here; the H6 NetworkPolicy check uses it."
  type        = string
  default     = null
}

variable "egress_allowed_destinations" {
  description = "Hand-over: the two Octopus hostnames the proxy permits. Informational."
  type        = list(string)
  default     = null
}

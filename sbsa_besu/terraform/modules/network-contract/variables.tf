# =============================================================================
# modules/network-contract/variables.tf
# -----------------------------------------------------------------------------
# The hand-over contract, as delivered by the cloud team in a
# `network-handover.auto.tfvars` fragment.
#
# These arrive as PLAIN VALUES, never via terraform_remote_state. The real cloud
# team will not grant state access, so a remote_state dependency would work in
# deploy-tests and fail at go-live (CLAUDE.md §3).
# =============================================================================

variable "vpc_id" { type = string }
variable "vpc_cidr_primary" { type = string }

variable "vpc_cidr_secondary" {
  description = "#17 — CG-NAT block, associated but unused. null if not granted."
  type        = string
  default     = null
}

variable "az_ids" {
  description = "#5 — AZ IDs, not names. Exactly 3."
  type        = list(string)
}

variable "ledger_subnet_ids" { type = map(string) }
variable "app_subnet_ids" { type = map(string) }
variable "lb_subnet_ids" { type = map(string) }
variable "endpoint_subnet_ids" { type = map(string) }
variable "data_subnet_ids" { type = map(string) }

variable "ledger_route_table_ids" { type = map(string) }
variable "app_route_table_ids" { type = map(string) }
variable "lb_route_table_ids" { type = map(string) }
variable "endpoint_route_table_ids" { type = map(string) }

variable "eks_service_cidr" {
  description = <<-EOT
    #9 — the CIDR EKS assigns Kubernetes Service IPs from. NOT part of the VPC,
    but it must not overlap the VPC's CIDRs or anything reachable over the
    Transit Gateway. IMMUTABLE after cluster creation — a collision found later
    means rebuilding the cluster, not reconfiguring it.
  EOT
  type        = string
  default     = "172.20.0.0/16"
}

variable "min_free_ips_ledger" {
  description = "Floor for free addresses in each ledger subnet before we will build on it."
  type        = number
  default     = 100
}

variable "min_free_ips_other" {
  type    = number
  default = 30
}

variable "network_region" {
  description = "#5 — the region the cloud team's VPC lives in, from the hand-over."
  type        = string
}

variable "deploy_region" {
  description = "The region this root is configured to deploy into (var.primary_region)."
  type        = string
}

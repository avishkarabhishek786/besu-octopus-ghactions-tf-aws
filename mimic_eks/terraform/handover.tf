# =============================================================================
# handover.tf — the network this cluster is built in, as the mimic consumes it.
# -----------------------------------------------------------------------------
# mimic_eks sits BETWEEN the two existing mimics and the platform:
#
#   mimic_vpc  -> network-handover.auto.tfvars -> mimic_eks -> eks-handover.auto.tfvars -> sbsa_besu
#                                              \-> mimic_egress -> egress-handover.auto.tfvars -/
#
# It consumes the network hand-over exactly as the platform does, which is also
# a fidelity check on that file: if the cluster cannot be built from it, the
# platform could not have been either.
#
# Only the subset the cluster needs is declared. The file carries more; unused
# variables in a root are harmless, and declaring only what we use keeps it
# obvious what a shared cluster actually depends on.
# =============================================================================

variable "vpc_id" { type = string }
variable "vpc_cidr_primary" { type = string }

variable "network_region" {
  description = "Asserted equal to var.region — a cluster cannot be built in a different region from its subnets, and the failure without this gate is a confusing mid-apply one."
  type        = string
}

variable "az_ids" { type = list(string) }

variable "app_subnet_ids" {
  description = "CT-1a: the cloud team's APPLICATION subnets. Under CT-5 our pods land here — we have no ledger subnets of our own unless #28 is granted."
  type        = map(string)
}

variable "ledger_subnet_ids" {
  description = "CT-1a: used as the dedicated node group's subnets when #28 is granted (node_group_dedicated), to reproduce that half of D-26 too."
  type        = map(string)
  default     = {}
}

variable "lb_subnet_ids" {
  description = "Where the platform may place its two internal NLBs. Passed straight through to the cluster hand-over (#34 F-2)."
  type        = map(string)
}

variable "endpoint_subnet_ids" {
  type    = map(string)
  default = {}
}

variable "data_subnet_ids" {
  description = "#37 — where a policy-mandated database would go."
  type        = map(string)
  default     = {}
}

# Declared so a hand-over produced by mimic_vpc loads without complaint; the
# cluster does not use them. *.auto.tfvars is loaded wholesale, and an undeclared
# variable in it is an ERROR, not a warning — so this list must stay in step with
# what mimic_vpc emits.
variable "vpc_cidr_secondary" {
  type    = string
  default = null
}
variable "dhcp_options_id" {
  type    = string
  default = null
}
variable "ledger_route_table_ids" {
  type    = map(string)
  default = {}
}
variable "app_route_table_ids" {
  type    = map(string)
  default = {}
}
variable "lb_route_table_ids" {
  type    = map(string)
  default = {}
}
variable "endpoint_route_table_ids" {
  type    = map(string)
  default = {}
}
variable "ledger_nacl_ids" {
  type    = map(string)
  default = {}
}
variable "gateway_endpoints_exist" {
  type    = bool
  default = false
}
variable "central_interface_endpoints" {
  type    = bool
  default = false
}
variable "subnet_cidrs_by_role" {
  type    = map(map(string))
  default = {}
}

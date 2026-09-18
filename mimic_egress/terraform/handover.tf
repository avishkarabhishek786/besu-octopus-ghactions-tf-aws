# =============================================================================
# handover.tf — the ledger VPC, as this project sees it.
# -----------------------------------------------------------------------------
# The bank's egress team knows the consumer VPC only by what the network team
# tells them: its ID, its CIDR, and which route tables get the route. So this
# project consumes `mimic_vpc`'s hand-over file — `network-handover.auto.tfvars`,
# copied in from the sibling project — as PLAIN VARIABLES, exactly as the
# platform does. Never `terraform_remote_state` (CLAUDE.md §0 #5).
#
# Only four values are used (vpc_id, vpc_cidr_primary, vpc_cidr_secondary,
# ledger_route_table_ids, plus network_region for the same-region assertion).
# The rest are declared with null defaults so the shared file loads without
# "undeclared variable" warnings, and so its SHAPE is checked here too.
# =============================================================================

variable "vpc_id" {
  description = "Hand-over: the ledger VPC to peer with."
  type        = string
}
variable "vpc_cidr_primary" {
  description = "Hand-over: the ledger /20. Routed from the egress VPC; the proxy SG admits it."
  type        = string
}
variable "vpc_cidr_secondary" {
  description = "Hand-over: the ledger's unused CG-NAT block. Not routed — but it must not overlap ours, or the peering is refused."
  type        = string
  default     = null
}
variable "network_region" {
  description = "Hand-over: the region the ledger VPC lives in. Must equal var.region (peering here is same-region)."
  type        = string
}
variable "ledger_route_table_ids" {
  description = "Hand-over: the LEDGER-role route tables — the ONLY tables that receive the egress route (CD-60). App/lb/endpoint/data never learn a path to the proxy."
  type        = map(string)
}

# Declared so the shared file loads cleanly; unused here.
variable "dhcp_options_id" {
  type    = string
  default = null
}
variable "az_ids" {
  type    = list(string)
  default = null
}
variable "ledger_subnet_ids" {
  type    = map(string)
  default = null
}
variable "app_subnet_ids" {
  type    = map(string)
  default = null
}
variable "lb_subnet_ids" {
  type    = map(string)
  default = null
}
variable "endpoint_subnet_ids" {
  type    = map(string)
  default = null
}
variable "data_subnet_ids" {
  type    = map(string)
  default = null
}
variable "app_route_table_ids" {
  type    = map(string)
  default = null
}
variable "lb_route_table_ids" {
  type    = map(string)
  default = null
}
variable "endpoint_route_table_ids" {
  type    = map(string)
  default = null
}
variable "ledger_nacl_ids" {
  type    = map(string)
  default = null
}
variable "gateway_endpoints_exist" {
  type    = bool
  default = null
}
variable "central_interface_endpoints" {
  type    = bool
  default = null
}
variable "subnet_cidrs_by_role" {
  type    = map(map(string))
  default = null
}

variable "name_prefix" { type = string }
variable "egress_vpc_id" { type = string }
variable "egress_vpc_cidr" { type = string }
variable "egress_route_table_id" { type = string }
variable "ledger_vpc_id" { type = string }
variable "ledger_vpc_cidr" { type = string }
variable "ledger_route_table_ids" {
  description = "LEDGER-role route tables only (from the hand-over). Each gets exactly one route: egress_vpc_cidr -> peering."
  type        = map(string)
}
variable "tags" {
  type    = map(string)
  default = {}
}

variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "subnet_id" { type = string }
variable "proxy_port" { type = number }
variable "target_instance_id" { type = string }
variable "dns_zone" {
  description = "Private hosted zone name — the mimic of the bank's corporate DNS."
  type        = string
}
variable "hostname" {
  description = "Host label inside dns_zone for the VIP."
  type        = string
}
variable "consumer_vpc_id" {
  description = "The ledger VPC. The zone is associated to it so the proxy hostname resolves where the runner lives."
  type        = string
}
variable "tags" {
  type    = map(string)
  default = {}
}

variable "name_prefix" { type = string }
variable "region" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" {
  description = "The egress VPC's own CIDR — the NLB health checks originate here and must reach the proxy port."
  type        = string
}
variable "subnet_id" { type = string }
variable "instance_type" { type = string }
variable "proxy_port" { type = number }
variable "allowed_source_cidr" {
  description = "CD-60: the single /32 the ACL admits."
  type        = string
}
variable "allowed_destinations" {
  description = "CD-59: the two Octopus hostnames — the only permitted CONNECT targets."
  type        = list(string)
}
variable "client_cidr" {
  description = "Security-group scope for the proxy port: the whole ledger VPC. The Squid ACL narrows to the /32; the SG only keeps the internet out."
  type        = string
}
variable "tags" {
  type    = map(string)
  default = {}
}

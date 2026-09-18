variable "name_prefix" { type = string }
variable "vpc_cidr" { type = string }
variable "enable_secondary_cidr" { type = bool }
variable "secondary_cidr" { type = string }
variable "region" { type = string }
variable "enable_flow_logs" { type = bool }
variable "flow_log_retention_days" { type = number }
variable "tags" {
  type    = map(string)
  default = {}
}

variable "name_prefix" { type = string }
variable "region" { type = string }
variable "vpc_cidr" { type = string }
variable "az_id" { type = string }
variable "enable_flow_logs" { type = bool }
variable "flow_log_retention_days" { type = number }
variable "tags" {
  type    = map(string)
  default = {}
}

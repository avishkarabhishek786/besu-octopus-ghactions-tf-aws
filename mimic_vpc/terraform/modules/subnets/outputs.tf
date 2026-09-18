# Keyed by AZ ID so the platform can place workloads deterministically (#5).
output "subnet_ids_by_role" {
  description = "role => { az_id => subnet_id }"
  value = {
    for role in distinct([for v in var.subnets : v.role]) :
    role => { for k, v in var.subnets : v.az_id => aws_subnet.this[k].id if v.role == role }
  }
}

output "route_table_ids_by_role" {
  description = "role => { az_id => route_table_id }"
  value = {
    for role in distinct([for v in var.subnets : v.role]) :
    role => { for k, v in var.subnets : v.az_id => aws_route_table.this[k].id if v.role == role }
  }
}

output "ledger_nacl_ids" {
  description = "az_id => nacl_id. The platform manages the RULES on these (#13)."
  value       = { for k in local.ledger_subnet_keys : var.subnets[k].az_id => aws_network_acl.ledger[k].id }
}

output "subnet_cidrs_by_role" {
  value = {
    for role in distinct([for v in var.subnets : v.role]) :
    role => { for k, v in var.subnets : v.az_id => v.cidr if v.role == role }
  }
}

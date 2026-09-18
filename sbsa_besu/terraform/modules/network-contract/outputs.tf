# Re-export the validated contract. Downstream modules consume THESE, never the
# raw variables, so nothing can be built from an unvalidated network.
output "vpc_id" {
  value      = data.aws_vpc.this.id
  depends_on = [terraform_data.vpc_attributes, terraform_data.az_placement, terraform_data.no_egress, terraform_data.capacity]
}
output "vpc_cidr_primary" { value = data.aws_vpc.this.cidr_block }
output "az_ids" { value = var.az_ids }
output "ledger_subnet_ids" { value = var.ledger_subnet_ids }
output "app_subnet_ids" { value = var.app_subnet_ids }
output "lb_subnet_ids" { value = var.lb_subnet_ids }
output "endpoint_subnet_ids" { value = var.endpoint_subnet_ids }
output "data_subnet_ids" { value = var.data_subnet_ids }
output "endpoint_route_table_ids" { value = var.endpoint_route_table_ids }
output "all_route_table_ids" { value = local.all_route_table_ids }

output "free_ips_by_subnet" {
  description = "Feeds the free-IP CloudWatch alarm — exhaustion must be noticed before a validator fails to schedule."
  value       = { for k, s in data.aws_subnet.this : k => s.available_ip_address_count }
}

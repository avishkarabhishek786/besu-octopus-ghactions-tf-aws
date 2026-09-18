# =============================================================================
# outputs.tf — THE HAND-OVER CONTRACT
# -----------------------------------------------------------------------------
# This is the deliverable of the entire project. `scripts/emit-handover.sh`
# renders these into a `network-handover.auto.tfvars` fragment that the platform
# project drops in unmodified.
#
# The platform consumes these as PLAIN INPUT VARIABLES and must NEVER read this
# project's state with terraform_remote_state. The real cloud team will not grant
# state access, so allowing it here would let the platform build a dependency
# that works in deploy-tests and fails at go-live.
#
# Subnet and route-table maps are keyed by AZ ID (#5), never by index or AZ name.
# =============================================================================

output "vpc_id" { value = module.vpc.vpc_id }
output "vpc_cidr_primary" { value = module.vpc.vpc_cidr_primary }
output "vpc_cidr_secondary" { value = module.vpc.vpc_cidr_secondary }
output "dhcp_options_id" { value = module.vpc.dhcp_options_id }
output "az_ids" { value = var.az_ids }
output "region" { value = var.region }

output "ledger_subnet_ids" { value = module.subnets.subnet_ids_by_role["ledger"] }
output "app_subnet_ids" { value = module.subnets.subnet_ids_by_role["app"] }
output "lb_subnet_ids" { value = module.subnets.subnet_ids_by_role["lb"] }
output "endpoint_subnet_ids" { value = module.subnets.subnet_ids_by_role["endpoint"] }
output "data_subnet_ids" { value = module.subnets.subnet_ids_by_role["data"] }

output "ledger_route_table_ids" { value = module.subnets.route_table_ids_by_role["ledger"] }
output "app_route_table_ids" { value = module.subnets.route_table_ids_by_role["app"] }
output "lb_route_table_ids" { value = module.subnets.route_table_ids_by_role["lb"] }
output "endpoint_route_table_ids" { value = module.subnets.route_table_ids_by_role["endpoint"] }

output "ledger_nacl_ids" { value = module.subnets.ledger_nacl_ids }

# Tells the platform whether it must create the S3/DynamoDB gateway endpoints
# itself, or whether they already exist (#10). The platform branches on this.
output "gateway_endpoints_created_here" { value = var.gateway_endpoints_created_here }

# Q-2: when true the interface endpoints already exist and the platform must NOT
# create its own.
output "central_interface_endpoints" { value = var.simulate_central_endpoints }

output "subnet_cidrs_by_role" {
  description = "Informational — for security-group and NACL rule authoring in the platform."
  value       = module.subnets.subnet_cidrs_by_role
}

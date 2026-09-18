# =============================================================================
# outputs.tf — the `shared` root
# -----------------------------------------------------------------------------
# Consumed by the `chain` and `app` roots via terraform_remote_state. Keep these
# stable: renaming one breaks the other roots' next plan.
# =============================================================================

output "endpoint_security_group_id" {
  description = "SG on the interface endpoint ENIs. Empty when endpoints are operated centrally (Q-2)."
  value       = try(aws_security_group.endpoints[0].id, "")
}

output "interface_endpoint_ids" {
  description = "Service short name -> endpoint id, for the endpoints this root created."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "interface_endpoint_services" {
  description = "Service short names actually endpointed here. Empty when the cloud team runs them centrally — in that case reachability is THEIR responsibility and a missing service still hangs rather than errors."
  value       = sort(local.interface_services)
}

output "gateway_endpoint_ids" {
  description = "S3/DynamoDB gateway endpoint ids; empty when the cloud team already created them (#10)."
  value = {
    s3       = try(aws_vpc_endpoint.s3[0].id, "")
    dynamodb = try(aws_vpc_endpoint.dynamodb[0].id, "")
  }
}

output "private_dns_zone_id" {
  description = "Zone the chain root writes the rpc record into. Empty when the cloud team hosts the zone."
  value       = try(aws_route53_zone.private[0].zone_id, "")
}

output "private_dns_zone_name" {
  description = "Zone name; the RPC server certificate is issued for rpc.<this>."
  value       = var.private_dns_zone
}

# -----------------------------------------------------------------------------
# Cost visibility. Interface endpoints are billed per ENI-hour, so the count is
# the number of endpoints x AZs, not the number of services.
# -----------------------------------------------------------------------------
output "billable_endpoint_eni_count" {
  description = "Interface endpoint ENIs created here (services x AZs). Each bills ~$7/mo plus data processing; this is the largest fixed line item in the air-gapped design."
  value       = length(local.interface_services) * length(local.endpoint_subnet_ids)
}

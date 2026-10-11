# =============================================================================
# modules/rpc-access/outputs.tf
# =============================================================================

output "rpc_target_group_arn" {
  description = "Target group ARN the in-cluster TargetGroupBinding registers RPC pods into. Null if the edge is disabled."
  value       = var.enable_rpc_ingress ? aws_lb_target_group.rpc[0].arn : null
}

output "rpc_nlb_dns_name" {
  description = "Internal DNS name of the RPC NLB (the SWIFT endpoint host over SIPN)."
  value       = var.enable_rpc_ingress ? aws_lb.rpc[0].dns_name : null
}

output "rpc_nlb_arn" {
  description = "ARN of the RPC NLB."
  value       = var.enable_rpc_ingress ? aws_lb.rpc[0].arn : null
}

output "privatelink_service_name" {
  description = "PrivateLink endpoint service name the future app VPC connects to (null unless enabled)."
  value       = var.enable_rpc_ingress && var.enable_privatelink ? aws_vpc_endpoint_service.rpc[0].service_name : null
}

output "lb_controller_role_arn" {
  description = "IRSA role ARN of the AWS Load Balancer Controller."
  value       = aws_iam_role.lbc.arn
}

# --- Stage 8: app-rpc edge ---------------------------------------------------
output "app_rpc_target_group_arns" {
  description = "App-rpc NLB target group ARNs by port name (http/ws) for the besu-app-rpc-edge TargetGroupBindings. Empty if the app edge is disabled."
  value = var.enable_app_rpc_ingress ? merge(
    { http = aws_lb_target_group.app_rpc_http[0].arn },
    var.app_rpc_ws_enabled ? { ws = aws_lb_target_group.app_rpc_ws[0].arn } : {},
  ) : {}
}

output "app_rpc_nlb_dns_name" {
  description = "Internal DNS name of the app-rpc NLB. Null if the app edge is disabled."
  value       = var.enable_app_rpc_ingress ? aws_lb.app_rpc[0].dns_name : null
}

output "app_rpc_privatelink_service_name" {
  description = "Dedicated PrivateLink endpoint service name the app VPC connects to. Null if the app edge is disabled."
  value       = var.enable_app_rpc_ingress ? aws_vpc_endpoint_service.app_rpc[0].service_name : null
}

output "lb_controller_release" {
  description = "The LB controller's Helm release name, or \"\" when not installed. Consumers reference it to install AFTER the controller (its webhook can refuse Services created before its pods are ready) — a reference orders resources without a module-level depends_on, which would defer every data source in the consumer (B51)."
  value       = try(helm_release.lbc[0].name, "")
}

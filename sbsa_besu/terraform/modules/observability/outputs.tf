# =============================================================================
# modules/observability/outputs.tf
# =============================================================================

output "sns_topic_arn" {
  description = "SNS alerts topic ARN (Alertmanager + CloudWatch alarms publish here)."
  value       = aws_sns_topic.alerts.arn
}

output "pods_log_group" {
  description = "CloudWatch log group receiving pod logs from Fluent Bit."
  value       = aws_cloudwatch_log_group.pods.name
}

output "cloudtrail_bucket" {
  description = "S3 bucket holding the CloudTrail audit log (null if disabled)."
  value       = var.enable_cloudtrail ? aws_s3_bucket.trail[0].id : null
}

output "fluentbit_role_arn" {
  description = "IRSA role ARN for Fluent Bit."
  value       = aws_iam_role.fluentbit.arn
}

output "alertmanager_role_arn" {
  description = "IRSA role ARN for Alertmanager (sns:Publish)."
  value       = aws_iam_role.alertmanager.arn
}

output "grafana_release" {
  description = "kube-prometheus-stack release name (null if in-cluster skipped)."
  value       = var.deploy_in_cluster_resources ? helm_release.kube_prometheus_stack[0].name : null
}

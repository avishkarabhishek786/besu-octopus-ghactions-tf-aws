output "deploy_role_arns" {
  description = "Per-environment role ARNs — the octopus root's aws_role_arns."
  value       = { for k, r in aws_iam_role.deploy : k => r.arn }
}

output "deploy_config_secrets" {
  description = "Per-environment secret names — fill with: ENV=<env> AWS_REGION=<region> scripts/runner/push-deploy-config.sh <name>"
  value       = { for k, s in aws_secretsmanager_secret.deploy_config : k => s.name }
}

output "trusted_subjects" {
  description = "Exactly what each role trusts. Compare with Octopus's task log if an assume is refused."
  value       = local.subjects
}

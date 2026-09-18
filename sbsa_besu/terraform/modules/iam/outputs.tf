# =============================================================================
# modules/iam/outputs.tf
# -----------------------------------------------------------------------------
# The IRSA role ARN is consumed by the Helm values (later stage) where the Besu
# service account is annotated with it, completing the IRSA binding.
# =============================================================================

output "besu_secrets_role_arn" {
  description = "ARN of the IRSA role the Besu secrets service account assumes. Annotate the Kubernetes service account with eks.amazonaws.com/role-arn = this value."
  value       = aws_iam_role.besu_secrets.arn
}

output "besu_secrets_role_name" {
  description = "Name of the IRSA role (for reference / further policy attachments)."
  value       = aws_iam_role.besu_secrets.name
}

output "secrets_service_account_name" {
  description = "The service account name the role is bound to (echoed for the Helm values)."
  value       = var.secrets_service_account_name
}

output "besu_genesis_role_arn" {
  description = "ARN of the write-capable IRSA role for the stage-3 genesis Job. Annotate the genesis service account with this."
  value       = aws_iam_role.besu_genesis.arn
}

output "genesis_service_account_name" {
  description = "Service account name the genesis (write) role is bound to."
  value       = var.genesis_service_account_name
}

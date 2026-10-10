# =============================================================================
# outputs.tf — the values the platform receives, as from the cloud team.
# =============================================================================

output "ecr_push_role_arn" {
  description = "GitHub secret AWS_ECR_PUSH_ROLE_ARN."
  value       = aws_iam_role.ecr_push.arn
}

output "ecr_registry" {
  description = "GitHub secret ECR_REGISTRY, and the chain root's registry_host."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_prefix" {
  description = "GitHub variable ECR_PREFIX, and the value of every entry in the chain root's registry_repo_prefixes."
  value       = var.ecr_prefix
}

output "trusted_subjects" {
  description = "The exact OIDC subjects the role trusts — compare with what the workflow printed if the assume is refused."
  value       = local.subjects
}

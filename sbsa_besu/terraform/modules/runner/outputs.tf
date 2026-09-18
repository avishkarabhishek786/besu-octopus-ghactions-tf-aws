# =============================================================================
# modules/runner/outputs.tf
# =============================================================================

output "instance_id" {
  description = "EC2 instance ID of the runner. Connect with: aws ssm start-session --target <this>."
  value       = aws_instance.runner.id
}

output "role_arn" {
  description = "IAM role ARN of the runner (granted an EKS access entry with cluster-admin)."
  value       = aws_iam_role.runner.arn
}

output "ssm_start_command" {
  description = "Convenience command to open a shell on the runner via SSM Session Manager."
  value       = "aws ssm start-session --target ${aws_instance.runner.id} --region ${var.region}"
}

output "private_ip" {
  description = "The runner's primary private IP — pinned when var.private_ip is set (CD-60). This is the /32 the egress proxy allowlists."
  value       = aws_instance.runner.private_ip
}

output "subnet_id" {
  description = "The subnet the runner lives in (the allowlist's /24 fallback, CD-60)."
  value       = aws_instance.runner.subnet_id
}

# =============================================================================
# terraform/runner/outputs.tf
# =============================================================================
output "runner_instance_id" {
  description = "EC2 instance ID of the runner."
  value       = module.runner.instance_id
}

# H5: which deploy policy the runner role carries (scoped by default; admin only via break-glass).
output "runner_role_arn" {
  description = "The runner instance role. Feed it to scripts/validation/simulate-runner-policy.sh to screen the deploy policy for missing actions BEFORE a billed apply -- an IAM reduction fails at apply time, never at plan time (CD-54)."
  value       = module.runner.role_arn
}

output "runner_deploy_policy_arn" {
  description = "IAM policy ARN attached to the runner for deploys. Three modes: AdministratorAccess when use_admin_deploy_policy=true (break-glass); the CD-54 in-cluster floor when runner_scope=\"in-cluster\"; otherwise the scoped H5 full-stack policy."
  value       = local.runner_deploy_policy_arn
}

output "runner_ssm_command" {
  description = "Open a shell on the runner via SSM Session Manager (no SSH, no public IP)."
  value       = module.runner.ssm_start_command
}

# F28 (C11): check the bootstrap ACTUALLY succeeded before relying on the runner.
# The bootstrap writes /opt/besu-deploy/BOOTSTRAP_STATUS (OK/FAILED/SKIPPED) and a
# failed clone now fails cloud-init itself. Run this after the apply (+ ~2 min):
output "runner_bootstrap_check" {
  description = "One-liner to verify the runner bootstrap (clone + deploy-config) succeeded."
  value       = "aws ssm send-command --instance-ids ${module.runner.instance_id} --region ${var.region} --document-name AWS-RunShellScript --parameters 'commands=[\"cloud-init status; cat /opt/besu-deploy/BOOTSTRAP_STATUS 2>/dev/null || echo NO STATUS FILE YET - bootstrap still running\"]' --query Command.CommandId --output text  # then: aws ssm get-command-invocation --command-id <id> --instance-id ${module.runner.instance_id} --region ${var.region} --query StandardOutputContent --output text"
}

# CD-60: the address the egress proxy allowlists — what goes in the R-10 ticket.
output "runner_private_ip" {
  description = "The runner's private IP (pinned from the egress hand-over when present). This /32 is the allowlist source in the R-10 egress ticket; the /24 fallback is its subnet."
  value       = "${module.runner.private_ip}/32"
}

output "runner_subnet_id" {
  description = "The ledger subnet the runner lives in (see runner_az_id)."
  value       = module.runner.subnet_id
}

output "runner_az_id" {
  description = "AZ ID of the runner's subnet — runner_subnet_az_id, or the first ledger AZ in sorted order."
  value       = local.runner_az_id
}

# CD-57: how to turn this runner into the Octopus worker, once the egress path exists.
output "runner_tentacle_install_hint" {
  description = "On the runner (over SSM, as root), after push-deploy-config.sh has delivered egress-handover.auto.tfvars."
  value       = "sudo env OCTOPUS_INSTANCE=<instance> OCTOPUS_SPACE='<space>' OCTOPUS_WORKER_POOL=<pool> OCTOPUS_API_KEY_SECRET=<secret-name> EXPECTED_POLLING_CERT_SHA256=<baseline> TENTACLE_CERT_SECRET=<secret-name> bash /opt/besu-deploy/sbsa_besu/scripts/runner/install-tentacle.sh"
}

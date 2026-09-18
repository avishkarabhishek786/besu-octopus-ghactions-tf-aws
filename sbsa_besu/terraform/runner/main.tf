# =============================================================================
# terraform/runner/main.tf — instantiate the runner from the chain's outputs (C1)
# =============================================================================
data "terraform_remote_state" "chain" {
  backend = "s3"
  config = {
    bucket = var.chain_state_bucket
    key    = var.chain_state_key
    region = var.chain_state_region
  }
}

locals {
  chain = data.terraform_remote_state.chain.outputs

  # The chain exports ledger subnets as a map keyed by AZ ID (#5) — there is no
  # `private_subnet_ids` list. Pick deterministically: the requested AZ, or the
  # first in sorted order. (The old `private_subnet_ids[0]` reference failed at
  # plan time: build finding B17.)
  runner_az_id     = var.runner_subnet_az_id != "" ? var.runner_subnet_az_id : sort(keys(local.chain.ledger_subnet_ids))[0]
  runner_subnet_id = local.chain.ledger_subnet_ids[local.runner_az_id]

  # CD-60: explicit override > the egress hand-over's allowlisted /32 > AWS picks.
  runner_private_ip = var.runner_private_ip != "" ? var.runner_private_ip : (
    var.egress_allowed_source != null ? split("/", var.egress_allowed_source)[0] : null
  )
}

module "runner" {
  source = "../modules/runner"

  name_prefix                       = local.chain.name_prefix
  vpc_id                            = local.chain.vpc_id
  subnet_id                         = local.runner_subnet_id
  private_ip                        = local.runner_private_ip # CD-60; null = unpinned
  cluster_name                      = local.chain.eks_cluster_name
  cluster_primary_security_group_id = local.chain.eks_node_security_group_id
  region                            = var.region
  instance_type                     = var.instance_type

  # H5: least-privilege deploy policy by default (deploy-policy.tf); AdministratorAccess
  # only via the use_admin_deploy_policy break-glass.
  deploy_policy_arn = local.runner_deploy_policy_arn

  # Code + config delivery (D-21 / F16). The chain root created both destinations
  # during the AWS-layer apply, so they exist before this instance boots:
  #   - artifacts_bucket: toolchain + source, pushed by push-runner-bundle.sh and
  #     pulled over the S3 gateway endpoint. No package manager, no internet.
  #   - deploy_config_secret_name: the gitignored env config, pushed by
  #     push-deploy-config.sh. Soft-fails at boot by design — the operator may
  #     push it after the runner is up and re-run fetch-deploy-config.sh.
  artifacts_bucket          = local.chain.runner_artifacts_bucket
  artifacts_bucket_arn      = local.chain.runner_artifacts_bucket_arn
  deploy_config_secret_name = try(local.chain.runner_deploy_config_secret, "")
}

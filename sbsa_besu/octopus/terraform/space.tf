# =============================================================================
# space.tf — the Space-level objects every project shares
# -----------------------------------------------------------------------------
# THE OCTOPUS SPACE AS CODE (CD-67). A bank deliverable: nothing below names a
# person, an instance or an account — those are variables (CD-10).
#
# Environments, the lifecycle (CD-41), one worker pool per environment for the
# In-VPC EC2 Runner (§7.2: the runner's Tentacle registers into ITS
# environment's pool, so a SIT deployment can never execute on the PROD runner),
# one AWS OIDC account per environment (no stored keys, CD-9), and the project
# group that keeps the three projects visibly apart from anything else in the
# space.
# =============================================================================

data "octopusdeploy_space" "this" {
  name = var.space_name
}

locals {
  space_id = data.octopusdeploy_space.this.id
  # env NAME (as shown in Octopus) -> lower-case slug (state keys, secrets, roles)
  envs = { for e in var.environments : e => lower(e) }
}

resource "octopusdeploy_project_group" "besu" {
  space_id    = local.space_id
  name        = var.project_group_name
  description = "Besu ledger platform — besu-infra, besu-workloads, besu-validators (CICD design notes §5)."
}

# No sort_order: Octopus appends a new environment after the space's existing ones
# and ignores the requested position on create, which provider 1.20.0 reports as
# "inconsistent result after apply" (seen 2026-10-10: asked 0, got 3). Promotion
# order is the lifecycle's job, not the environment list's.
resource "octopusdeploy_environment" "this" {
  for_each = var.manage_environments ? local.envs : {}

  space_id = local.space_id
  name     = each.key
  slug     = each.value
}

data "octopusdeploy_environments" "existing" {
  space_id = local.space_id
  take     = 100
}

locals {
  env_id = var.manage_environments ? { for k, e in octopusdeploy_environment.this : k => e.id } : {
    for e in data.octopusdeploy_environments.existing.environments : e.name => e.id if contains(var.environments, e.name)
  }
}

# CD-41: the first environment (SIT) deploys automatically when a release is
# created; every later one is a manual promotion. PROD's approval is a manual-
# intervention STEP in each project, not a lifecycle setting — the lifecycle
# orders environments, the step enforces sign-off.
resource "octopusdeploy_lifecycle" "besu" {
  space_id    = local.space_id
  name        = "Besu SIT → UAT → PROD"
  description = "CD-41: SIT automatic on release; UAT and PROD manual promotion. Each phase requires the previous."

  dynamic "phase" {
    for_each = var.environments
    content {
      name                                  = phase.value
      automatic_deployment_targets          = phase.key == 0 ? [local.env_id[phase.value]] : []
      optional_deployment_targets           = phase.key == 0 ? [] : [local.env_id[phase.value]]
      minimum_environments_before_promotion = 0
      is_optional_phase                     = false
    }
  }
}

# One pool per environment for the runner's polling Tentacle. install-tentacle.sh
# registers the worker INTO this pool by name, so the name is the contract.
resource "octopusdeploy_static_worker_pool" "runner" {
  for_each = local.envs

  space_id    = local.space_id
  name        = "besu-runner-${each.value}"
  description = "${each.key}: the In-VPC EC2 Runner's polling Tentacle (CD-57). The only workers that can reach the private EKS endpoint."
}

# CD-67: Octopus's own identity, exchanged for the environment's deploy role.
# The subject keys produce space:<s>:project:<p>:environment:<e>, which is
# exactly what octopus/aws-trust trusts — nothing broader.
resource "octopusdeploy_aws_openid_connect_account" "deploy" {
  for_each = local.envs

  space_id               = local.space_id
  name                   = "besu-aws-${each.value}"
  description            = "${each.key} deploy role, via OIDC (octopus/aws-trust). No stored keys (CD-9)."
  role_arn               = var.aws_role_arns[each.value]
  region                 = var.aws_region
  session_duration       = var.aws_session_duration_seconds
  environments           = [local.env_id[each.key]]
  execution_subject_keys = ["space", "project", "environment"]
}

data "octopusdeploy_worker_pools" "hosted" {
  space_id = local.space_id
  name     = var.hosted_worker_pool_name
}

data "octopusdeploy_feeds" "builtin" {
  space_id  = local.space_id
  feed_type = "BuiltIn"
}

# Besu's own feed for the worker-tools image, rather than any Docker feed that
# happens to exist in the space (one did, created by hand): the platform's
# toolchain source is then part of the reviewed code, and repointing it at the
# bank's registry is a variable.
resource "octopusdeploy_docker_container_registry" "worker_tools" {
  space_id = local.space_id
  name     = "Besu worker tools"
  feed_uri = var.worker_container.feed_uri
}

locals {
  hosted_pool_id = one([for p in data.octopusdeploy_worker_pools.hosted.worker_pools : p.id if p.name == var.hosted_worker_pool_name])
  builtin_feed   = data.octopusdeploy_feeds.builtin.feeds[0].id
}

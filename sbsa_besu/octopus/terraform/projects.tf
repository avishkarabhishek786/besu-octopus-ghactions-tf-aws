# =============================================================================
# projects.tf — besu-infra, besu-workloads, besu-validators (CD-4, CD-5, CD-67)
# -----------------------------------------------------------------------------
# Every step runs a script FROM THE PACKAGE (octopus/steps/*.sh), so the logic is
# versioned with the platform it deploys and reviewed like any other code; the
# step bodies here only map Octopus variables to environment variables.
#
# STEP PROPERTY NAMES. Provider 1.20.0 does not type step properties: they are
# the Octopus action-property keys, discovered from Octopus itself (provider
# guide "How to Find Step Properties"). The Manual-intervention keys are from the
# provider's own example; the script / AWS-script / package keys are the
# documented action properties, and are VERIFIED against the instance's step
# templates before the first deployment (RUNBOOK). A wrong key is not rejected —
# it is silently ignored — which is why that check is a step, not a hope.
# =============================================================================

locals {
  # --- shared step fragments --------------------------------------------------
  package_ref = {
    platform = {
      package_id           = var.package_id
      feed_id              = local.builtin_feed
      acquisition_location = "ExecutionTarget"
      properties = {
        Extract       = "True"
        SelectionMode = "immediate"
        Purpose       = ""
      }
    }
  }
  pkg = "#{Octopus.Action.Package[platform].ExtractedPath}"

  # Hosted-worker steps run inside this (variables.tf: worker_container).
  worker_container = {
    feed_id = octopusdeploy_docker_container_registry.worker_tools.id
    image   = var.worker_container.image
  }

  bash_inline = {
    "Octopus.Action.RunOnServer"         = "true" # = run on a worker, not a deployment target
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "Bash"
  }

  # Octopus's AWS CLI script step: the account variable is exchanged for
  # credentials via OIDC before the script starts.
  aws_script = merge(local.bash_inline, {
    "Octopus.Action.AwsAccount.Variable"        = "Besu.AwsAccount"
    "Octopus.Action.AwsAccount.UseInstanceRole" = "False"
    "Octopus.Action.Aws.AssumeRole"             = "False"
    "Octopus.Action.Aws.Region"                 = "#{Besu.Region}"
  })

  infra_env = <<-EOT
    export BESU_ENV="#{Octopus.Environment.Name}"
    export BESU_STATE_BUCKET="#{Besu.StateBucket}" BESU_STATE_REGION="#{Besu.StateRegion}"
    export BESU_DEPLOY_CONFIG="#{Besu.DeployConfigSecret}" BESU_CHAIN_EXTRA_ARGS="#{Besu.ChainExtraArgs}"
    export AWS_REGION="#{Besu.Region}"
  EOT

  runner_env = <<-EOT
    export BESU_CLUSTER="#{Besu.Cluster}" AWS_REGION="#{Besu.Region}"
    export BESU_TOOLS_IMAGE="#{Besu.ToolsImage}" BESU_LEDGER_NAMESPACE="#{Besu.LedgerNamespace}"
  EOT

  prod_env_ids = [for e in var.approval_environments : local.env_id[e]]
}

# =============================================================================
# Variables shared by all three projects (a library variable set)
# =============================================================================
resource "octopusdeploy_library_variable_set" "besu" {
  space_id    = local.space_id
  name        = "Besu platform"
  description = "Per-environment values for besu-infra / besu-workloads / besu-validators. No secrets: the deploy config lives in Secrets Manager (octopus/aws-trust)."
}

locals {
  # name => { env => value } ; "" env key = unscoped.
  # Octopus leaves an UNDEFINED variable as the literal text "#{Name}", so every
  # variable a script reads has a value in every environment it runs in —
  # ChainExtraArgs and ValidatorSetArgs get an unscoped "" default.
  lvs_values = {
    "Besu.Region"           = { "" = var.aws_region }
    "Besu.StateBucket"      = { "" = var.state_bucket }
    "Besu.StateRegion"      = { "" = var.state_region }
    "Besu.ToolsImage"       = { "" = var.tools_image }
    "Besu.LedgerNamespace"  = { "" = var.ledger_namespace }
    "Besu.ChainExtraArgs"   = merge({ "" = "" }, var.chain_extra_args)
    "Besu.Cluster"          = var.cluster_names
    "Besu.ValidatorSetArgs" = { "" = "" }
    "Besu.DeployConfigSecret" = {
      for e, slug in local.envs : e => "${var.name_prefix}-${slug}-octopus-deploy-config"
    }
  }
  lvs_flat = merge([
    for name, byenv in local.lvs_values : {
      for env, value in byenv : "${name}|${env}" => { name = name, env = env, value = value }
    }
  ]...)
}

resource "octopusdeploy_variable" "lvs" {
  for_each = local.lvs_flat

  space_id = local.space_id
  owner_id = octopusdeploy_library_variable_set.besu.id
  name     = each.value.name
  type     = "String"
  value    = each.value.value

  dynamic "scope" {
    for_each = each.value.env == "" ? [] : [each.value.env]
    content {
      environments = [local.env_id[scope.value]]
    }
  }
}

# The AWS account and the runner pool are TYPED variables, scoped per
# environment, so a step cannot pick up another environment's account or pool.
resource "octopusdeploy_variable" "aws_account" {
  for_each = local.envs

  space_id = local.space_id
  owner_id = octopusdeploy_library_variable_set.besu.id
  name     = "Besu.AwsAccount"
  type     = "AmazonWebServicesAccount"
  value    = octopusdeploy_aws_openid_connect_account.deploy[each.key].id
  scope { environments = [local.env_id[each.key]] }
}

resource "octopusdeploy_variable" "runner_pool" {
  for_each = local.envs

  space_id = local.space_id
  owner_id = octopusdeploy_library_variable_set.besu.id
  name     = "Besu.RunnerPool"
  type     = "WorkerPool"
  value    = octopusdeploy_static_worker_pool.runner[each.key].id
  scope { environments = [local.env_id[each.key]] }
}

# =============================================================================
# besu-infra — the AWS layer, on a hosted worker: shared -> chain -> runner
# =============================================================================
resource "octopusdeploy_project" "infra" {
  space_id                       = local.space_id
  name                           = "besu-infra"
  description                    = "Terraform, AWS layer only: shared -> chain (AWS) -> runner. Hosted worker; OIDC account per environment (CD-67)."
  project_group_id               = octopusdeploy_project_group.besu.id
  lifecycle_id                   = octopusdeploy_lifecycle.besu.id
  included_library_variable_sets = [octopusdeploy_library_variable_set.besu.id]
  default_guided_failure_mode    = "Off"
}

resource "octopusdeploy_process" "infra" {
  space_id   = local.space_id
  project_id = octopusdeploy_project.infra.id
}

resource "octopusdeploy_process_step" "infra_approve" {
  # An Octopus step with an EMPTY environments set runs in EVERY environment, so
  # with no approval environments the step must not exist at all.
  count        = length(local.prod_env_ids) > 0 ? 1 : 0
  space_id     = local.space_id
  process_id   = octopusdeploy_process.infra.id
  name         = "Approve infrastructure change"
  type         = "Octopus.Manual"
  environments = local.prod_env_ids
  execution_properties = {
    "Octopus.Action.RunOnServer"                       = "true"
    "Octopus.Action.Manual.Instructions"               = "CD-15/CD-41: review the release's Terraform changes before the AWS layer of this environment is applied."
    "Octopus.Action.Manual.BlockConcurrentDeployments" = "True"
  }
}

resource "octopusdeploy_process_step" "infra_root" {
  for_each = { shared = 1, chain = 2, runner = 3 }

  space_id       = local.space_id
  process_id     = octopusdeploy_process.infra.id
  name           = "terraform: ${each.key}"
  type           = "Octopus.AwsRunScript"
  worker_pool_id = local.hosted_pool_id
  container      = local.worker_container
  packages       = local.package_ref
  execution_properties = merge(local.aws_script, {
    "Octopus.Action.Script.ScriptBody" = "${local.infra_env}bash \"${local.pkg}/octopus/steps/infra-terraform.sh\" ${each.key}\n"
  })
}

# Between chain and runner: the runner's bootstrap is FATAL without its S3
# bundle, and the bucket only exists once chain has applied (runner-bundle.sh).
resource "octopusdeploy_process_step" "infra_bundle" {
  space_id       = local.space_id
  process_id     = octopusdeploy_process.infra.id
  name           = "runner bundle + config"
  type           = "Octopus.AwsRunScript"
  worker_pool_id = local.hosted_pool_id
  container      = local.worker_container
  packages       = local.package_ref
  execution_properties = merge(local.aws_script, {
    "Octopus.Action.Script.ScriptBody" = "${local.infra_env}bash \"${local.pkg}/octopus/steps/runner-bundle.sh\"\n"
  })
}

resource "octopusdeploy_process_steps_order" "infra" {
  space_id   = local.space_id
  process_id = octopusdeploy_process.infra.id
  steps = concat(octopusdeploy_process_step.infra_approve[*].id, [
    octopusdeploy_process_step.infra_root["shared"].id,
    octopusdeploy_process_step.infra_root["chain"].id,
    octopusdeploy_process_step.infra_bundle.id,
    octopusdeploy_process_step.infra_root["runner"].id,
  ])
}

# =============================================================================
# besu-workloads — the in-cluster layer, on the runner's Tentacle
# =============================================================================
# CD-5: the validator release is never CHANGED by this project. The in-cluster
# step applies the chain root's in-cluster layer, which INSTALLS the validators
# on a fresh chain (there is no running chain to halt) and is refused by its own
# plan-safety gate if it would update, replace or delete an existing one
# (workloads-incluster.sh step 5); after that H1 makes the apply a no-op on them.
resource "octopusdeploy_project" "workloads" {
  space_id                       = local.space_id
  name                           = "besu-workloads"
  description                    = "In-cluster layer on the In-VPC EC2 Runner (polling Tentacle). Installs validators on a fresh chain; never changes an existing one (CD-5)."
  project_group_id               = octopusdeploy_project_group.besu.id
  lifecycle_id                   = octopusdeploy_lifecycle.besu.id
  included_library_variable_sets = [octopusdeploy_library_variable_set.besu.id]
  default_guided_failure_mode    = "Off"
}

resource "octopusdeploy_process" "workloads" {
  space_id   = local.space_id
  project_id = octopusdeploy_project.workloads.id
}

resource "octopusdeploy_process_step" "workloads_approve" {
  # An Octopus step with an EMPTY environments set runs in EVERY environment, so
  # with no approval environments the step must not exist at all.
  count        = length(local.prod_env_ids) > 0 ? 1 : 0
  space_id     = local.space_id
  process_id   = octopusdeploy_process.workloads.id
  name         = "Approve in-cluster change"
  type         = "Octopus.Manual"
  environments = local.prod_env_ids
  execution_properties = {
    "Octopus.Action.RunOnServer"                       = "true"
    "Octopus.Action.Manual.Instructions"               = "CD-15: approve the in-cluster change for this environment."
    "Octopus.Action.Manual.BlockConcurrentDeployments" = "True"
  }
}

resource "octopusdeploy_process_step" "workloads_smoke" {
  space_id             = local.space_id
  process_id           = octopusdeploy_process.workloads.id
  name                 = "cluster smoke: nodes, quota'd namespace, #38 pull canary, C-2 DNS"
  type                 = "Octopus.Script"
  worker_pool_variable = "Besu.RunnerPool"
  packages             = local.package_ref
  execution_properties = merge(local.bash_inline, {
    "Octopus.Action.Script.ScriptBody" = "${local.runner_env}bash \"${local.pkg}/octopus/steps/workloads-smoke.sh\"\n"
  })
}

# After the smoke step, so the #38 pull canary has proved the cluster can pull
# from the mirror before anything larger is attempted. Same state, same
# variables as besu-infra's chain step (infra_env + lib.sh chain_tf_vars).
resource "octopusdeploy_process_step" "workloads_incluster" {
  space_id             = local.space_id
  process_id           = octopusdeploy_process.workloads.id
  name                 = "terraform: chain in-cluster (CSI, LBC, monitoring, Besu, Blockscout)"
  type                 = "Octopus.Script"
  worker_pool_variable = "Besu.RunnerPool"
  packages             = local.package_ref
  execution_properties = merge(local.bash_inline, {
    "Octopus.Action.Script.ScriptBody" = "${local.infra_env}${local.runner_env}bash \"${local.pkg}/octopus/steps/workloads-incluster.sh\"\n"
  })
}

resource "octopusdeploy_process_steps_order" "workloads" {
  space_id   = local.space_id
  process_id = octopusdeploy_process.workloads.id
  steps = concat(octopusdeploy_process_step.workloads_approve[*].id, [
    octopusdeploy_process_step.workloads_smoke.id,
    octopusdeploy_process_step.workloads_incluster.id,
  ])
}

# =============================================================================
# besu-validators — the ONLY path to a validator, behind a gate in EVERY env
# =============================================================================
# CD-5 / §6: the manual intervention runs in ALL environments, SIT included —
# SIT exists to rehearse the PROD procedure, not a faster one.
resource "octopusdeploy_project" "validators" {
  space_id                       = local.space_id
  name                           = "besu-validators"
  description                    = "Validators ONLY, via rolling-besu-apply.sh, one pod at a time, behind a manual gate in every environment (CD-5, H1)."
  project_group_id               = octopusdeploy_project_group.besu.id
  lifecycle_id                   = octopusdeploy_lifecycle.besu.id
  included_library_variable_sets = [octopusdeploy_library_variable_set.besu.id]
  default_guided_failure_mode    = "Off"
}

resource "octopusdeploy_process" "validators" {
  space_id   = local.space_id
  project_id = octopusdeploy_project.validators.id
}

resource "octopusdeploy_process_step" "validators_gate" {
  space_id   = local.space_id
  process_id = octopusdeploy_process.validators.id
  name       = "Approve validator roll (QBFT: one validator at a time)"
  type       = "Octopus.Manual"
  execution_properties = {
    "Octopus.Action.RunOnServer"                       = "true"
    "Octopus.Action.Manual.Instructions"               = "H1/CD-5: this rolls validators ONE AT A TIME with rolling-besu-apply.sh. 4 validators tolerate exactly one down. Confirm the chain is healthy (H35) and no other validator change is in flight."
    "Octopus.Action.Manual.BlockConcurrentDeployments" = "True"
  }
}

resource "octopusdeploy_process_step" "validators_roll" {
  space_id             = local.space_id
  process_id           = octopusdeploy_process.validators.id
  name                 = "rolling-besu-apply.sh"
  type                 = "Octopus.Script"
  worker_pool_variable = "Besu.RunnerPool"
  packages             = local.package_ref
  execution_properties = merge(local.bash_inline, {
    "Octopus.Action.Script.ScriptBody" = "${local.runner_env}export SET_ARGS=\"#{Besu.ValidatorSetArgs}\"\nbash \"${local.pkg}/octopus/steps/validators-rolling.sh\"\n"
  })
}

resource "octopusdeploy_process_steps_order" "validators" {
  space_id   = local.space_id
  process_id = octopusdeploy_process.validators.id
  steps = [
    octopusdeploy_process_step.validators_gate.id,
    octopusdeploy_process_step.validators_roll.id,
  ]
}

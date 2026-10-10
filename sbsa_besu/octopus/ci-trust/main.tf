# =============================================================================
# octopus/ci-trust — what GitHub Actions may do in Octopus (CD-68)
# -----------------------------------------------------------------------------
# A root of its own, applied ONCE per instance by an Octopus ADMINISTRATOR —
# never by CI and never with the besu-terraform key. It is aws-trust's
# counterpart: a pipeline that could edit its own permissions could grant
# itself anything, so the boundary is that this file is applied outside it.
#
# Creates:
#   * a SERVICE ACCOUNT for release.yml. It has no password and no API key:
#     GitHub exchanges its OIDC token for a short-lived Octopus token
#     (OctopusDeploy/login, CD-9 — no stored keys, now on this side too);
#   * one OIDC identity per allowed ref, matching GitHub's `sub` EXACTLY — no
#     wildcard (the CD-66 lesson). The audience is left at Octopus's default,
#     the service account's own id, which is what OctopusDeploy/login sends;
#   * two narrow custom roles, granted through a team in the space:
#       publish  — push packages and create releases, in the Besu projects only;
#       deploy   — DeploymentCreate/View and TaskView in SIT only. Needed because
#                  creating a release deploys SIT automatically (lifecycle,
#                  CD-41), and so release.yml can wait for that deployment
#                  (CD-21). Never UAT or PROD (validated in variables.tf).
#
# WHY NOT THE BUILT-IN ROLES. "Package publisher" carries BuiltInFeedAdminister
# (replace or DELETE packages — a released version could change under its
# release number) and "Release creator" carries RunbookEdit. Neither belongs to
# a pipeline that only publishes.
#
# Two roles, not one, so that no permission depends on how Octopus treats an
# environment restriction on a permission that does not support one: every
# permission below supports every restriction its role is given.
# =============================================================================

data "octopusdeploy_space" "this" {
  name = var.space_name
}

data "octopusdeploy_projects" "besu" {
  for_each = toset(var.project_names)

  space_id     = data.octopusdeploy_space.this.id
  partial_name = each.key
}

data "octopusdeploy_environments" "all" {
  space_id = data.octopusdeploy_space.this.id
  take     = 100
}

locals {
  space_id = data.octopusdeploy_space.this.id

  # partial_name matches substrings; keep exact names only, and fail if one is
  # missing (one() errors on zero matches) rather than scope a role to nothing.
  project_ids = [for n in var.project_names : one([for p in data.octopusdeploy_projects.besu[n].projects : p.id if p.name == n])]
  env_ids     = [for n in var.deploy_environments : one([for e in data.octopusdeploy_environments.all.environments : e.id if e.name == n])]

  owner = split("/", var.github_repository)[0]
  repo  = split("/", var.github_repository)[1]
  subjects = {
    for r in var.allowed_refs : r => (
      var.github_ids == null
      ? "repo:${var.github_repository}:ref:${r}"
      : "repo:${local.owner}@${var.github_ids.owner}/${local.repo}@${var.github_ids.repository}:ref:${r}"
    )
  }
}

resource "octopusdeploy_user" "ci" {
  username     = var.service_account_username
  display_name = "${var.service_account_username} (GitHub Actions release.yml, OIDC)"
  is_service   = true
  is_active    = true
}

resource "octopusdeploy_service_account_oidc_identity" "github" {
  for_each = local.subjects

  service_account_id = octopusdeploy_user.ci.id
  name               = "github ${each.key}"
  issuer             = "https://token.actions.githubusercontent.com"
  subject            = each.value
}

resource "octopusdeploy_user_role" "publish" {
  name        = "Besu CI — publish"
  description = "release.yml (CD-68): push the platform package and create releases. Scoped to the Besu projects by the team."
  granted_space_permissions = [
    "BuiltInFeedPush", # projects
    "FeedView",
    "ReleaseCreate", # projects, tenants
    "ReleaseView",   # projects, tenants
    "ProjectView",   # projects, tenants
    "ProcessView",   # projects, tenants
    "LifecycleView",
  ]
}

resource "octopusdeploy_user_role" "deploy" {
  name        = "Besu CI — deploy first phase"
  description = "release.yml (CD-68): the automatic SIT deployment a release triggers (CD-41), and waiting for it (CD-21). Scoped to SIT and the Besu projects by the team."
  granted_space_permissions = [
    "DeploymentCreate", # environments, projects, tenants
    "DeploymentView",   # environments, projects, tenants
    "TaskView",         # environments, projects, tenants
    "EnvironmentView",  # environments
  ]
}

# No in-line user_role blocks: the provider cannot mix them with
# octopusdeploy_scoped_user_role on one team (it overwrites one with the other).
resource "octopusdeploy_team" "ci" {
  space_id    = local.space_id
  name        = "Besu CI"
  description = "GitHub Actions release.yml, signed in through OIDC (octopus/ci-trust, CD-68). Membership and roles are managed by Terraform."
  users       = [octopusdeploy_user.ci.id]
}

resource "octopusdeploy_scoped_user_role" "publish" {
  space_id     = local.space_id
  team_id      = octopusdeploy_team.ci.id
  user_role_id = octopusdeploy_user_role.publish.id
  project_ids  = local.project_ids
}

resource "octopusdeploy_scoped_user_role" "deploy" {
  space_id        = local.space_id
  team_id         = octopusdeploy_team.ci.id
  user_role_id    = octopusdeploy_user_role.deploy.id
  project_ids     = local.project_ids
  environment_ids = local.env_ids
}

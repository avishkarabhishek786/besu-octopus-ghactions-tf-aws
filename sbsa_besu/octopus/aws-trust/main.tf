# =============================================================================
# octopus/aws-trust — what Octopus may do in AWS, and where its env config lives
# -----------------------------------------------------------------------------
# A root of its own, applied ONCE per account by a human — never by Octopus.
# A deploy tool that could edit its own trust policy could grant itself
# anything; the boundary is that this file is applied outside the pipeline.
#
# Creates:
#   * the IAM OIDC provider for the Octopus instance (issuer = audience = the
#     instance host, per Octopus's AWS OIDC documentation);
#   * one deploy role per environment, assumable ONLY by the exact subject
#     `space:<space>:project:<project>:environment:<env>` of each project that
#     needs AWS (CD-67) — StringEquals, no wildcard (the CD-66 lesson);
#   * one EMPTY Secrets Manager secret per environment for the deploy config
#     (tfvars + hand-overs). The laptop fills it with the existing
#     scripts/runner/push-deploy-config.sh; Octopus steps read it with the
#     existing fetch-deploy-config.sh. The values never enter Octopus or any
#     Terraform state (D-21's principle).
#
# PERMISSIONS ARE BROAD, ON PURPOSE AND ON THE RECORD. besu-infra applies the
# shared, chain (AWS layer) and runner roots, which create EKS, IAM roles, KMS
# keys, endpoints and S3 — the same reach the operator's laptop credential has
# today. Narrowing it is follow-up work (CD-67), not a silent default:
# `deploy_policy_arns` is the one place to change it.
# =============================================================================

data "aws_caller_identity" "current" {}

locals {
  issuer_host = trimprefix(var.octopus_server_url, "https://")

  # Every (environment, project) pair that may assume that environment's role.
  subjects = {
    for env in var.environments : env => [
      for p in var.aws_projects : "space:${var.space_slug}:project:${p}:environment:${env}"
    ]
  }
}

resource "aws_iam_openid_connect_provider" "octopus" {
  url             = var.octopus_server_url
  client_id_list  = [local.issuer_host]
  thumbprint_list = var.oidc_thumbprints
}

data "aws_iam_policy_document" "trust" {
  for_each = local.subjects

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.octopus.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer_host}:aud"
      values   = [local.issuer_host]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer_host}:sub"
      values   = each.value
    }
  }
}

resource "aws_iam_role" "deploy" {
  for_each = local.subjects

  name                 = "${var.project_name}-${each.key}-octopus-deploy"
  description          = "Octopus ${each.key} deployments (CD-67): ${join(", ", var.aws_projects)}"
  assume_role_policy   = data.aws_iam_policy_document.trust[each.key].json
  max_session_duration = var.session_duration_seconds
}

resource "aws_iam_role_policy_attachment" "deploy" {
  for_each = {
    for pair in setproduct(var.environments, var.deploy_policy_arns) : "${pair[0]}|${pair[1]}" => {
      env = pair[0], arn = pair[1]
    }
  }

  role       = aws_iam_role.deploy[each.value.env].name
  policy_arn = each.value.arn
}

# Empty on purpose: the CONTENT is pushed from the laptop (push-deploy-config.sh)
# and read by the steps (fetch-deploy-config.sh). recovery_window 0 so a teardown
# is instant and a re-create of the same name does not collide (prime directive 8,
# and the inherited Secrets Manager 30-day-deletion trap).
resource "aws_secretsmanager_secret" "deploy_config" {
  for_each = toset(var.environments)

  name                    = "${var.project_name}-${each.key}-octopus-deploy-config"
  description             = "Octopus ${each.key}: base64 tar.gz of tfvars + hand-overs (push-deploy-config.sh)"
  recovery_window_in_days = 0
}

# The deploy role reads its own environment's config — and nothing else's.
data "aws_iam_policy_document" "read_config" {
  for_each = toset(var.environments)

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.deploy_config[each.key].arn]
  }
}

resource "aws_iam_role_policy" "read_config" {
  for_each = toset(var.environments)

  name   = "read-own-deploy-config"
  role   = aws_iam_role.deploy[each.key].id
  policy = data.aws_iam_policy_document.read_config[each.key].json
}

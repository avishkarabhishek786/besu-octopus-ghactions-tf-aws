# =============================================================================
# main.tf — the CI push grant to the registry (#25b, CD-27, R-5b)
# -----------------------------------------------------------------------------
# One IAM role that .github/workflows/supply-chain.yml assumes through GitHub
# OIDC (CD-9 — no stored AWS keys), allowed to push, and optionally create
# repositories, ONLY under our prefix. In production the registry is a central
# shared-services account and this grant is the cloud team's; here it is a
# stand-in, which is why it lives beside the other mimics and not in a
# platform root. The platform consumes it as two values — a role ARN and a
# registry host — exactly as it would receive them from the cloud team.
#
# WHAT IT DELIBERATELY DOES NOT GRANT
#   * ecr:DeleteRepository / BatchDeleteImage / PutLifecyclePolicy — the
#     registry has NO expiry (CLAUDE.md §5.2): a validator replaced months from
#     now must still find its exact digest. CI that could delete could break it.
#   * PutImageTagMutability — repositories are created IMMUTABLE by mirror.sh
#     and CI must not be able to relax that (H38's backstop).
#   * Anything outside `<prefix>/*`.
#
# It does NOT create the GitHub OIDC provider. That is one per account per URL
# and this account's already serves another repository's role; creating it
# here would collide, and destroying this project would break that role.
# =============================================================================

data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  # The OIDC `sub` for a branch run is repo:<owner>/<name>:ref:<ref>. EXACT
  # match, no wildcards in the owner or repository: `repo:owner*/…` also
  # matches any other owner whose name merely starts the same way.
  #
  # Repositories created after 2026-07-15 carry numeric IDs in `sub`. OBSERVED
  # 2026-10-10 (the workflow's "Show the OIDC subject" step, first dry run):
  #     repo:<owner>@<owner-id>/<name>@<repo-id>:ref:<ref>
  # The plain form was refused. Both are generated, exactly, for every allowed
  # ref — the IDs are what make a recreated or renamed repository NOT match,
  # which is the point. extra_subjects remains for anything else observed.
  _owner = split("/", var.github_repository)[0]
  _name  = split("/", var.github_repository)[1]
  subjects = concat(
    [for r in var.allowed_refs : "repo:${var.github_repository}:ref:${r}"],
    var.github_ids == null ? [] : [
      for r in var.allowed_refs : "repo:${local._owner}@${var.github_ids.owner}/${local._name}@${var.github_ids.repository}:ref:${r}"
    ],
    var.extra_subjects,
  )

  repo_arn_prefix = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${var.ecr_prefix}/*"
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.subjects
    }
  }
}

resource "aws_iam_role" "ecr_push" {
  name                 = "${var.project_name}-${var.environment}-ecr-push"
  description          = "GitHub Actions supply-chain mirror: push to ECR under ${var.ecr_prefix}/ (CD-9, CD-27)"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600 # the workflow's timeout is 45 min
}

data "aws_iam_policy_document" "push" {
  # GetAuthorizationToken cannot be scoped to a repository — no resource-level
  # permission exists for it.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # mirror.sh --check-repos lists every repository in one call and compares
  # locally; a list call cannot be scoped to a prefix. Read-only.
  statement {
    sid       = "ListRepositories"
    actions   = ["ecr:DescribeRepositories"]
    resources = ["*"]
  }

  # crane copy: HEAD/GET of the target manifest (idempotence — an existing
  # digest is skipped), then the blob upload and the manifest PUT.
  statement {
    sid = "PushUnderPrefix"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [local.repo_arn_prefix]
  }

  dynamic "statement" {
    for_each = var.allow_create_repositories ? [1] : []
    content {
      sid       = "CreateUnderPrefix"
      actions   = ["ecr:CreateRepository"]
      resources = [local.repo_arn_prefix]
    }
  }
}

resource "aws_iam_role_policy" "push" {
  name   = "ecr-push-under-prefix"
  role   = aws_iam_role.ecr_push.id
  policy = data.aws_iam_policy_document.push.json
}

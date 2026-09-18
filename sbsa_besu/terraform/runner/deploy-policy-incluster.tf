# =============================================================================
# deploy-policy-incluster.tf — the runner's IAM floor when it deploys ONLY the
# in-cluster layer (CD-54). Selected by `runner_scope = "in-cluster"`.
# -----------------------------------------------------------------------------
# WHY THIS EXISTS
#   `deploy-policy.tf` is broad because the runner could historically apply the
#   WHOLE chain root — its own "accepted residual" note says `ec2:*`/`eks:*` are
#   account-wide because "the stack creates those resources dynamically". CD-53
#   removes that premise: Octopus's `besu-infra` project owns the AWS layer, and
#   the runner is left with the in-cluster layer, the preflight checks, the
#   operational scripts and break-glass.
#
#   So the minimum is a FUNCTION OF THE SPLIT, not an absolute. Keep
#   `runner_scope = "full-stack"` while the runner still applies `chain`.
#
# WHY A SEPARATE DOCUMENT rather than conditional statements in the existing one
#   That file is security-critical and carefully argued. Threading eight
#   `dynamic` blocks through it to omit the IAM and KMS-management statements
#   would make both modes harder to review than either is now. This document is
#   short enough to read in one screen, which is the property that matters for a
#   policy someone has to approve.
#
# WHAT IS DELIBERATELY ABSENT, and why each is safe to drop
#   iam:*   writes   — the runner creates no roles here. This alone removes the
#                      entire H5 escalation surface: with no CreateRole and no
#                      PassRole there is nothing for the anti-escalation denies
#                      in deploy-policy.tf to defend, which is why they are not
#                      reproduced. Absence of capability beats a deny.
#   kms:CreateKey / key management — AWS-layer.
#   cloudtrail, acm-pca, sns, resource-groups — AWS-layer.
#   ec2 / eks / elasticloadbalancing / logs / cloudwatch WRITES — AWS-layer. The
#     runtime consumers (Fluent Bit, the load-balancer controller, the pods that
#     decrypt node keys) hold their OWN IRSA roles; they never borrowed the
#     runner's, so removing the write half breaks nothing at runtime.
#
# WHAT IS NOT DROPPABLE, though it looks like it should be
#   kms:Decrypt / Encrypt / GenerateDataKey on Project-tagged keys. A Secrets
#   Manager secret encrypted with a customer-managed CMK — which is exactly what
#   C12 does to the node and CA keys — cannot be read without kms:Decrypt on
#   that key. Dropping KMS entirely would break `GetSecretValue` with an error
#   that names KMS, not Secrets Manager, and send the reader to the wrong file.
#
# TEARDOWN IS NOT HERE, ON PURPOSE. `full-delete.sh` is a categorically
#   different capability from "deploy the in-cluster layer", and the established
#   practice is that a laptop-driven destroy plus EBS sweep is safest. If the
#   runner ever needs it, give it a separately-assumed role so that using it is
#   a visible act.
#
# HOW THIS FAILS: at APPLY time, with `AccessDenied ... not authorized to
#   perform <action>`, never at plan time. That is how every IAM reduction
#   fails. Add the action to `runner_deploy_extra_actions` (no code change) and
#   re-run; flip `runner_scope = "full-stack"` only as a temporary unblock.
#   Before the first real run, use scripts/validation/simulate-runner-policy.sh
#   — it costs nothing and catches most of the gaps.
# =============================================================================

data "aws_iam_policy_document" "runner_incluster" {
  count = local.runner_policy_mode == "in-cluster" ? 1 : 0

  # ---------------------------------------------------------------------------
  # Reach the cluster. `aws eks get-token` — which the kubernetes and helm
  # providers' exec auth calls — needs DescribeCluster for the endpoint and CA,
  # and signs with STS. Kubernetes-side authorisation is the EKS ACCESS ENTRY
  # (modules/runner), not this policy; these two actions only get us to the door.
  # ---------------------------------------------------------------------------
  statement {
    sid       = "AllowClusterAuth"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster", "eks:ListClusters", "sts:GetCallerIdentity"]
    resources = ["*"]
  }

  # ---------------------------------------------------------------------------
  # Read-only discovery: the preflight checks and every debugging session.
  # verify-endpoints.sh needs ec2:DescribeVpcEndpoints / DescribeVpcs /
  # DescribeSecurityGroups; the rest is what you reach for when the chain is
  # halted and you are trying to find out why.
  # ---------------------------------------------------------------------------
  statement {
    sid    = "AllowReadOnlyDiscovery"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "eks:Describe*",
      "eks:List*",
      "elasticloadbalancing:Describe*",
      "autoscaling:Describe*",
      "logs:Describe*",
      "logs:FilterLogEvents",
      "logs:GetLogEvents",
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*",
      "tag:GetResources",
    ]
    resources = ["*"]
  }

  # ---------------------------------------------------------------------------
  # ECR pull. NOT present in the full-stack policy before 2026-09-10 — an
  # omission from the move to ECR, which would have failed verify-images.sh from
  # the runner: the one place the RUNBOOK insists it must run, because a laptop
  # passes while the cluster still cannot pull.
  #
  # GetAuthorizationToken is REGISTRY-level and its resource is always "*". The
  # pull actions are "*" here too because the registry lives in a central
  # shared-services account (#25b) — the other half of the grant is that
  # account's repository policy, so narrowing the ARN here would only duplicate
  # a control we do not own.
  # ---------------------------------------------------------------------------
  statement {
    sid       = "AllowEcrAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowEcrPull"
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = ["*"]
  }

  # ---------------------------------------------------------------------------
  # Secrets Manager, scoped by RESOURCE exactly as the full-stack policy is.
  # Read for the permissioning and PKI scripts; write because
  # issue-server-cert.sh stores the keystore it builds.
  # ---------------------------------------------------------------------------
  statement {
    sid    = "AllowScopedSecretsManager"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:PutSecretValue",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = local.secret_arn_scopes
  }

  statement {
    sid       = "AllowSecretsManagerListing"
    effect    = "Allow"
    actions   = ["secretsmanager:ListSecrets"]
    resources = ["*"]
  }

  # ---------------------------------------------------------------------------
  # KMS — the narrow set, ABAC-scoped to this project's keys. See the header:
  # this is required for GetSecretValue on any CMK-encrypted secret, and its
  # absence surfaces as a KMS error during a Secrets Manager call.
  # ---------------------------------------------------------------------------
  statement {
    sid    = "AllowKmsUseOnProjectTaggedKeys"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [local.project]
    }
  }

  # ---------------------------------------------------------------------------
  # S3: this stack's Terraform state (including the `.tflock` object that
  # use_lockfile writes) and the runner's own artefact bucket. Same resource
  # scope as the full-stack policy.
  # ---------------------------------------------------------------------------
  statement {
    sid       = "AllowScopedS3"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:GetObjectVersion", "s3:ListBucket", "s3:GetBucketVersioning"]
    resources = local.s3_bucket_arns
  }

  statement {
    sid       = "AllowS3Listing"
    effect    = "Allow"
    actions   = ["s3:ListAllMyBuckets", "s3:GetBucketLocation"]
    resources = ["*"]
  }

  # ---------------------------------------------------------------------------
  # The same escape hatch the full-stack policy offers, so an AccessDenied found
  # mid-run is a tfvars change rather than a code change.
  # ---------------------------------------------------------------------------
  dynamic "statement" {
    for_each = length(var.deploy_extra_actions) > 0 ? [1] : []
    content {
      sid       = "AllowOperatorAddedActions"
      effect    = "Allow"
      actions   = var.deploy_extra_actions
      resources = ["*"]
    }
  }
}

resource "aws_iam_policy" "runner_incluster" {
  count       = local.runner_policy_mode == "in-cluster" ? 1 : 0
  name        = "${local.name_prefix}-runner-deploy-incluster"
  description = "CD-54: in-cluster-only deploy policy for the in-VPC runner. No IAM writes, no KMS key management, no AWS-layer writes — Octopus's besu-infra project owns those."
  policy      = data.aws_iam_policy_document.runner_incluster[0].json
}

resource "terraform_data" "incluster_policy_guard" {
  count = local.runner_policy_mode == "in-cluster" ? 1 : 0

  lifecycle {
    # The KMS statement is ABAC: an empty project name matches no key, so every
    # CMK-encrypted secret read would fail — deep into a run, naming KMS rather
    # than the real cause. Same trap the full-stack policy guards against.
    precondition {
      condition     = local.project != ""
      error_message = "CD-54: the chain state has no `project_name` output, so the in-cluster policy's KMS statement (conditioned on aws:ResourceTag/Project) would match no key and every CMK-encrypted secret read would fail. Re-apply the chain root so the output exists, then re-run this root."
    }

    precondition {
      condition     = length(replace(data.aws_iam_policy_document.runner_incluster[0].json, "/\\s/", "")) < 6144
      error_message = "CD-54: the rendered in-cluster deploy policy exceeds AWS's 6144-character limit for a managed policy. Trim `runner_deploy_extra_actions`."
    }
  }
}

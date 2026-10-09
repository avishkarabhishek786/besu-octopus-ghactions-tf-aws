# =============================================================================
# terraform/runner/deploy-policy.tf — scoped runner deploy policy (H5)
# -----------------------------------------------------------------------------
# WHAT: the IAM policy attached to the In-VPC EC2 Runner's instance role. The runner
# runs `terraform apply` for the WHOLE chain stack from inside the VPC (the EKS
# API endpoint is private), so it needs real deploy power. This file makes that
# power (a) service-scoped, (b) resource-scoped on every store that holds
# secrets, and (c) STRUCTURALLY incapable of privilege escalation.
#
# WHY: hardwiring AdministratorAccess meant "anyone with ssm:StartSession on the
# runner, or a supply-chain compromise of the curl|bash toolchain install, gets
# full ACCOUNT takeover". The 2026-07-06 whitebox pentest then showed the first
# scoped version was still PowerUser-EQUIVALENT and escalatable
# (CreateRole + PutRolePolicy + PassRole "*" ⇒ mint an admin role, pass it to
# EC2). This version closes that. AdministratorAccess remains only as an
# explicit break-glass (var.use_admin_deploy_policy).
#
# THE FOUR LAYERS (in the order they appear below)
#   1. SERVICE ALLOWLIST — an explicit list of the services the stack actually
#      uses (var.deploy_service_actions), replacing the old `NotAction ["iam:*",
#      "organizations:*", "account:*"]` PowerUser shape. Adding a service is a
#      tfvars change, not a code change (var.deploy_extra_actions).
#   2. RESOURCE-SCOPED SENSITIVE STORES — Secrets Manager, KMS and S3 are scoped
#      to this stack's namespace (`besu-*` / `<name_prefix>-*` / this stack's
#      state + CloudTrail buckets / keys tagged Project=<project>). The runner
#      can no longer read every secret and decrypt every key in the account.
#   3. RESOURCE-SCOPED IAM — role / policy / instance-profile writes only on
#      `<name_prefix>-*`, service-linked roles only under /aws-service-role/,
#      the IRSA OIDC provider only for this region's EKS issuer, and PassRole
#      only to `<name_prefix>-*` roles.
#   4. ANTI-ESCALATION DENIES — the part that actually closes H5:
#        a. `iam:CreateRole` / `iam:PutRolePermissionsBoundary` are DENIED unless
#           the request carries EXACTLY the stack's permissions boundary
#           (terraform/iam-boundary.tf). Every role the runner can create is
#           therefore permanently incapable of iam:*/organizations:*/account:*.
#        b. `iam:DeleteRolePermissionsBoundary` is denied outright — a boundary
#           cannot be lifted after the fact.
#        c. The runner may not modify its OWN role, instance profile, deploy
#           policy, or the boundary policy (no self-escalation, no re-writing
#           the ceiling), and may not PassRole itself.
#        d. Attaching the AWS-managed Administrator/PowerUser/IAMFull policies to
#           anything is denied (the simplest one-call escalation).
#
# WHY PassRole IS NOT ALSO CONDITIONED ON iam:PassedToService: every role the
# runner may pass is boundary-capped, so passing one to any service yields at
# most "everything except IAM" — which the runner already has. The condition
# would add apply-fragility (the correct service-principal set differs per AWS
# service and changes over time) for no reduction in privilege.
#
# ACCEPTED RESIDUAL (documented, not hidden). What a compromised runner CAN
# still do, and why each is accepted rather than fixed here:
#   * `ec2:*` / `eks:*` / `elasticloadbalancing:*` are account-wide. The stack
#     creates those resources dynamically, and EC2 resource-level permissions
#     cannot be pre-scoped by name before the resources exist.
#   * Read this stack's validator key secrets and kms:Decrypt this stack's CMKs.
#     Inherent to being the thing that deploys the chain, not a defect.
#   * Stop/delete THIS stack's CloudTrail and delete objects in its audit bucket
#     (anti-forensics). Not closed here because the operator directive of
#     2026-07-06 forbids anything that blocks immediate teardown — S3 Object Lock
#     and deny-delete are excluded by that rule (backlog H19). A long-lived
#     go-live chain should ship the trail to a separate, locked account.
#   * Create a boundary-capped role whose TRUST policy names an external
#     principal (cross-account persistence). IAM exposes no condition key for the
#     principals in a trust policy, so this cannot be denied in-policy; the
#     boundary still caps what such a role could ever do to "no IAM".
#   * Grant Kubernetes cluster-admin via `eks:CreateAccessEntry` — the runner
#     already holds cluster-admin, so this is not an escalation.
# The security property this file guarantees is narrower and precise: **a
# compromised runner stays inside this stack's blast radius and can never become
# account admin.** Treat `ssm:StartSession` on the runner as equivalent to
# "deploy operator", and gate it accordingly.
#
# HOW TO DO IT BY HAND: IAM console → Policies → Create policy → JSON → paste the
# rendered document (`terraform show -json` or the plan output) → name it
# `<name_prefix>-runner-deploy-scoped` → attach it to `<name_prefix>-runner-role`
# INSTEAD of AdministratorAccess.
#
# FAILURE MODES / RUNBOOK
#   * Apply fails `AccessDenied ... not authorized to perform <action>`:
#       1. Read the action out of the error (or CloudTrail
#          `errorCode=AccessDenied` on the runner role).
#       2. If it is a whole service the stack legitimately needs, add it to
#          `runner_deploy_extra_actions` in the runner tfvars — no code edit.
#       3. Re-apply. Only if that is impractical mid-run, flip
#          `use_admin_deploy_policy = true` as a TEMPORARY unblock, finish the
#          run, then fold the action in and flip it back.
#   * Apply fails `explicit deny ... RequirePermissionsBoundaryOnRoleCreate`: a
#     role is being created WITHOUT the boundary. Either the chain is being
#     applied with `enable_iam_permissions_boundary = false` (then the deny is
#     inconsistent — see the guard below, which omits it when the chain reports
#     no boundary), or a module creates a role that does not thread
#     `permissions_boundary`. Fix the module; do not weaken the deny.
#   * Adopting on an ALREADY-APPLIED chain: roles created before this change have
#     no boundary. The next chain apply adds it in place (needs
#     iam:PutRolePermissionsBoundary, allowed here when the ARN matches). Until
#     that apply lands, those roles remain uncapped.
#   * A Phase-C (from-the-runner) apply that wants to CHANGE the boundary policy
#     itself fails with `explicit deny ... DenyRunnerSelfMutation`. That is BY
#     DESIGN — the ceiling must not be editable by the principal it constrains.
#     The boundary is an AWS-layer resource, so change it in a Phase-A apply from
#     the laptop, then re-run Phase C. (Related: F33, the 2026-07-11 finding that
#     the runner's first Phase-C plan diverges from the laptop's Phase-A state —
#     if that divergence ever includes the boundary policy, Phase C will now stop
#     instead of silently rewriting it. Root-cause F33 alongside this change.)
#
# STATUS: the PREVIOUS (PowerUser-shaped) version of this policy was live-
# validated on the 2026-07-11 mock — it completed Phase B, Phase C and cert
# issuance with no AccessDenied, and its Deny fired under attack. THIS tightened
# version is statically validated only and MUST be exercised on the next mock
# deploy before go-live (backlog H5 acceptance).
# =============================================================================

data "aws_partition" "runner" {}
data "aws_caller_identity" "runner" {}

locals {
  partition  = data.aws_partition.runner.partition
  account_id = data.aws_caller_identity.runner.account_id

  # Everything the stack owns is named `<name_prefix>-*`; the chain's Secrets
  # Manager entries are the un-prefixed `besu-*` namespace (H27 — namespacing
  # those under name_prefix is a deferred backlog item; until then this is the
  # tightest correct scope).
  name_prefix = local.chain.name_prefix
  project     = try(local.chain.project_name, "")

  # The boundary the chain attaches to every role it creates. Empty string means
  # the chain was applied with enable_iam_permissions_boundary = false — in that
  # case the boundary-enforcing denies are OMITTED (they would deny every
  # CreateRole and make the stack un-deployable). That is a deliberate, visible
  # coupling: no boundary ⇒ no escalation protection ⇒ do not run this way in prod.
  boundary_arn     = try(local.chain.iam_permissions_boundary_arn, "")
  enforce_boundary = local.boundary_arn != ""

  # IAM ARNs this policy scopes to / protects.
  iam_role_prefix_arn      = "arn:${local.partition}:iam::${local.account_id}:role/${local.name_prefix}-*"
  iam_policy_prefix_arn    = "arn:${local.partition}:iam::${local.account_id}:policy/${local.name_prefix}-*"
  iam_instance_profile_arn = "arn:${local.partition}:iam::${local.account_id}:instance-profile/${local.name_prefix}-*"
  iam_service_linked_arn   = "arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/*"
  iam_oidc_provider_arn    = "arn:${local.partition}:iam::${local.account_id}:oidc-provider/oidc.eks.${var.region}.amazonaws.com/*"

  # The runner's OWN identity — never writable by the runner itself (self-escalation
  # guard). These are created by THIS root, applied from the laptop by an admin.
  self_role_arn             = "arn:${local.partition}:iam::${local.account_id}:role/${local.name_prefix}-runner-role"
  self_instance_profile_arn = "arn:${local.partition}:iam::${local.account_id}:instance-profile/${local.name_prefix}-runner-profile"
  self_policy_arn           = "arn:${local.partition}:iam::${local.account_id}:policy/${local.name_prefix}-runner-deploy-scoped"
  protected_iam_arns = compact([
    local.self_role_arn,
    local.self_instance_profile_arn,
    local.self_policy_arn,
    local.boundary_arn, # the ceiling itself must be immutable from the runner
  ])

  # Secrets Manager: the chain's `besu-*` namespace + anything name-prefixed
  # (the runner's own github-token / deploy-config secrets), + operator additions.
  secret_arn_scopes = concat([
    "arn:${local.partition}:secretsmanager:${var.region}:${local.account_id}:secret:besu-*",
    "arn:${local.partition}:secretsmanager:${var.region}:${local.account_id}:secret:${local.name_prefix}-*",
  ], var.deploy_extra_secret_arns)

  # S3: the Terraform state bucket this stack uses + any bucket the stack creates
  # (the CloudTrail audit bucket is `<name_prefix>-cloudtrail-<account>`).
  s3_bucket_arns = concat([
    "arn:${local.partition}:s3:::${var.chain_state_bucket}",
    "arn:${local.partition}:s3:::${var.chain_state_bucket}/*",
    "arn:${local.partition}:s3:::${local.name_prefix}-*",
    "arn:${local.partition}:s3:::${local.name_prefix}-*/*",
  ], var.deploy_extra_s3_arns)
}

data "aws_iam_policy_document" "runner_deploy" {
  count = local.runner_policy_mode == "full-stack" ? 1 : 0

  # ---------------------------------------------------------------------------
  # LAYER 1 — service allowlist (replaces the old PowerUser-shaped NotAction).
  # Derived from the stack's actual resource inventory; see var.deploy_service_actions.
  # ---------------------------------------------------------------------------
  statement {
    sid       = "AllowStackServices"
    effect    = "Allow"
    actions   = concat(var.deploy_service_actions, var.deploy_extra_actions)
    resources = ["*"]
  }

  # ---------------------------------------------------------------------------
  # LAYER 2 — resource-scoped sensitive stores.
  # ---------------------------------------------------------------------------

  # Secrets Manager — full CRUD, but ONLY inside this stack's namespace. The
  # RESOURCE list is the control here, not the action list: `secretsmanager:*` on
  # `besu-*` / `<name_prefix>-*` grants nothing outside the chain's own secrets,
  # and enumerating actions instead would only add "the apply died on an action we
  # forgot" failure modes. (The list/generate actions take no resource, so they
  # need their own statement below.)
  statement {
    sid       = "AllowScopedSecretsManager"
    effect    = "Allow"
    actions   = ["secretsmanager:*"]
    resources = local.secret_arn_scopes
  }

  statement {
    sid       = "AllowSecretsManagerListing"
    effect    = "Allow"
    actions   = ["secretsmanager:ListSecrets", "secretsmanager:GetRandomPassword"]
    resources = ["*"]
  }

  # KMS — use/manage only keys tagged with this project (ABAC). Covers the C12
  # node-key CMK and the H7 EKS-secrets CMK, both of which carry Project via the
  # provider's default_tags. A key belonging to another workload is out of reach.
  # As with Secrets Manager, the TAG CONDITION is the control, not the action list:
  # the runner already legitimately needs Decrypt + PutKeyPolicy on these keys
  # (it is what deploys them), so enumerating the rest buys nothing but breakage.
  statement {
    sid       = "AllowKmsOnProjectTaggedKeys"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [local.project]
    }
  }

  # KMS actions with no taggable resource (a key has no tags until it exists; an
  # alias is not taggable at all). Creating a key or an alias is not an escalation.
  statement {
    sid    = "AllowKmsCreateAndList"
    effect = "Allow"
    actions = [
      "kms:CreateKey",
      "kms:ListKeys",
      "kms:ListAliases",
      "kms:CreateAlias",
      "kms:DeleteAlias",
      "kms:UpdateAlias",
    ]
    resources = ["*"]
  }

  # S3 — the Terraform state bucket and the stack's own buckets only.
  statement {
    sid       = "AllowScopedS3"
    effect    = "Allow"
    actions   = ["s3:*"]
    resources = local.s3_bucket_arns
  }

  statement {
    sid       = "AllowS3Listing"
    effect    = "Allow"
    actions   = ["s3:ListAllMyBuckets", "s3:GetBucketLocation"]
    resources = ["*"]
  }

  # ---------------------------------------------------------------------------
  # LAYER 3 — resource-scoped IAM.
  # ---------------------------------------------------------------------------

  # Read-only introspection: Terraform refreshes roles/policies on every plan.
  statement {
    sid       = "AllowIamRead"
    effect    = "Allow"
    actions   = ["iam:Get*", "iam:List*", "iam:SimulatePrincipalPolicy", "iam:SimulateCustomPolicy"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowScopedRoleWrites"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = [local.iam_role_prefix_arn]
  }

  statement {
    sid    = "AllowScopedPolicyWrites"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [local.iam_policy_prefix_arn]
  }

  statement {
    sid    = "AllowScopedInstanceProfiles"
    effect = "Allow"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
    ]
    resources = [local.iam_instance_profile_arn, local.iam_role_prefix_arn]
  }

  # EKS / ELB / autoscaling create service-linked roles on first use. SLRs carry
  # AWS-authored trust + permission policies the caller cannot choose, so they are
  # not an escalation vector — but they cannot take a permissions boundary either,
  # which is why they get their own path-scoped statement.
  statement {
    sid    = "AllowServiceLinkedRoles"
    effect = "Allow"
    actions = [
      "iam:CreateServiceLinkedRole",
      "iam:DeleteServiceLinkedRole",
      "iam:GetServiceLinkedRoleDeletionStatus",
    ]
    resources = [local.iam_service_linked_arn]
  }

  # The IRSA OIDC provider for THIS region's EKS issuer.
  statement {
    sid    = "AllowEksOidcProvider"
    effect = "Allow"
    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider",
    ]
    resources = [local.iam_oidc_provider_arn]
  }

  # PassRole only to this stack's roles (all boundary-capped). Needed for the EKS
  # cluster role, the node role, and the VPC flow-logs role.
  statement {
    sid       = "AllowScopedPassRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [local.iam_role_prefix_arn]
  }

  # ---------------------------------------------------------------------------
  # LAYER 4 — anti-escalation denies. These are what close H5; an explicit Deny
  # beats every Allow above, including anything added via deploy_extra_actions.
  # ---------------------------------------------------------------------------

  # (a) No role may be created — and no boundary set — except with EXACTLY the
  # stack's boundary. StringNotEquals is true when the key is absent, so a
  # CreateRole that omits the boundary entirely is denied too. Omitted when the
  # chain reports no boundary (otherwise nothing could ever be created).
  dynamic "statement" {
    for_each = local.enforce_boundary ? [1] : []
    content {
      sid       = "RequirePermissionsBoundaryOnRoleCreate"
      effect    = "Deny"
      actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
      resources = ["*"]
      condition {
        test     = "StringNotEquals"
        variable = "iam:PermissionsBoundary"
        values   = [local.boundary_arn]
      }
    }
  }

  # (b) A boundary, once set, cannot be lifted by the runner.
  dynamic "statement" {
    for_each = local.enforce_boundary ? [1] : []
    content {
      sid       = "DenyRemovingPermissionsBoundary"
      effect    = "Deny"
      actions   = ["iam:DeleteRolePermissionsBoundary"]
      resources = ["*"]
    }
  }

  # (c) Self-protection: the runner cannot rewrite its own role/profile/policy or
  # the boundary policy, and cannot pass its own (deliberately un-capped) role to
  # another service. Reads stay allowed (the validation harness calls iam:GetRole
  # and iam:SimulatePrincipalPolicy on this role).
  statement {
    sid    = "DenyRunnerSelfMutation"
    effect = "Deny"
    actions = [
      "iam:Create*",
      "iam:Delete*",
      "iam:Update*",
      "iam:Put*",
      "iam:Attach*",
      "iam:Detach*",
      "iam:Tag*",
      "iam:Untag*",
      "iam:SetDefaultPolicyVersion",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:PassRole",
    ]
    resources = local.protected_iam_arns
  }

  # (d) The one-call escalation: attaching an AWS-managed admin policy to anything.
  # The stack only ever attaches specific scoped policies (AmazonEKS*, its own), so
  # this never impedes a legitimate apply.
  statement {
    sid       = "DenyAttachingAdminManagedPolicies"
    effect    = "Deny"
    actions   = ["iam:AttachRolePolicy", "iam:AttachUserPolicy", "iam:AttachGroupPolicy"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values = [
        "arn:${local.partition}:iam::aws:policy/AdministratorAccess",
        "arn:${local.partition}:iam::aws:policy/PowerUserAccess",
        "arn:${local.partition}:iam::aws:policy/IAMFullAccess",
      ]
    }
  }
}

resource "aws_iam_policy" "runner_deploy" {
  count       = local.runner_policy_mode == "full-stack" ? 1 : 0
  name        = "${local.name_prefix}-runner-deploy-scoped"
  description = "H5: least-privilege deploy policy for the in-VPC runner — service allowlist + resource-scoped secrets/KMS/S3/IAM + permissions-boundary enforcement (no privilege escalation)."
  policy      = data.aws_iam_policy_document.runner_deploy[0].json
}

locals {
  # THREE modes, in decreasing privilege. admin is break-glass only; the default
  # is the H5 scoped full-stack policy; in-cluster is CD-54's floor, valid only
  # once Octopus owns the AWS layer (CD-53).
  runner_policy_mode = var.use_admin_deploy_policy ? "admin" : var.runner_scope

  # The policy the runner's instance role attaches.
  # `one()` rather than `[0]`: an untaken branch of a conditional must not index
  # a count=0 resource. Verified working with plain [0] on Terraform 1.16.1, but
  # required_version is >= 1.10 and this expression selects an IAM POLICY -- not
  # somewhere to depend on a version-specific evaluation order.
  runner_deploy_policy_arn = (
    local.runner_policy_mode == "admin" ? "arn:${local.partition}:iam::aws:policy/AdministratorAccess" :
    local.runner_policy_mode == "in-cluster" ? one(aws_iam_policy.runner_incluster[*].arn) :
    one(aws_iam_policy.runner_deploy[*].arn)
  )

  # Rendered size the way AWS measures it: characters, whitespace excluded.
  # Guarded by a precondition below (limit: 6,144 for a customer-managed policy).
  # The in-cluster document has its own guard in deploy-policy-incluster.tf.
  policy_size = length(replace(coalesce(one(data.aws_iam_policy_document.runner_deploy[*].json), "{}"), "/\\s/", ""))
}

# -----------------------------------------------------------------------------
# GUARDRAIL: refuse to build the scoped policy against a chain that has no
# permissions boundary. Without the boundary, the anti-escalation denies above
# are silently omitted and the policy degrades to "PowerUser + scoped stores" —
# exactly the H5 residual this change exists to close. Fail loudly at PLAN time
# rather than shipping a policy that looks hardened but is not.
# -----------------------------------------------------------------------------
resource "terraform_data" "boundary_guard" {
  # Only meaningful in full-stack mode. In in-cluster mode the runner cannot
  # create a role at all, so there is no boundary to enforce and nothing to
  # escalate with -- the guard would fail on a chain that legitimately has no
  # boundary while the policy it guards is not even selected.
  count = local.runner_policy_mode == "full-stack" ? 1 : 0

  lifecycle {
    precondition {
      condition     = local.enforce_boundary || var.allow_unbounded_deploy_policy
      error_message = <<-EOT
        H5: the chain state reports no IAM permissions boundary
        (output `iam_permissions_boundary_arn` is empty), so the runner's scoped
        deploy policy cannot enforce it — the anti-escalation denies would be
        omitted and a compromised runner could mint an admin role.

        Fix (preferred): apply the chain with `enable_iam_permissions_boundary = true`
        (the default) so every stack role is boundary-capped, then re-apply this root.
        If the chain predates this change, re-run the chain apply first — it adds the
        boundary to existing roles in place.

        Deploy-test escape hatch: set `allow_unbounded_deploy_policy = true` to proceed
        with the weaker policy. Never do this for a go-live chain.
      EOT
    }

    # The KMS statement is ABAC — it grants nothing unless the Project tag value is
    # real. An empty project name would silently produce a policy that denies every
    # KMS call (chain apply fails deep into Phase C, hard to diagnose). Catch it here.
    precondition {
      condition     = local.project != ""
      error_message = "H5: the chain state has no `project_name` output, so the scoped deploy policy's KMS statement (conditioned on aws:ResourceTag/Project) would match no key. Re-apply the chain root so the output exists, then re-run this root."
    }

    # A customer-managed IAM policy may not exceed 6,144 characters (whitespace
    # excluded). This document is deliberately near the useful limit, and
    # `deploy_extra_actions` / `deploy_extra_secret_arns` / `deploy_extra_s3_arns`
    # eat into the headroom. Fail at PLAN with a clear message instead of at apply
    # with AWS's `LimitExceeded: Maximum policy size exceeded`.
    precondition {
      condition     = local.policy_size < 6144
      error_message = "H5: the rendered runner deploy policy is ${local.policy_size} characters, over AWS's 6144-character limit for a managed policy. Trim `deploy_extra_actions`/`deploy_extra_secret_arns`/`deploy_extra_s3_arns`, or collapse enumerated actions to a service wildcard scoped by resource (the resource/tag scope is what enforces least privilege, not the action list)."
    }
  }
}

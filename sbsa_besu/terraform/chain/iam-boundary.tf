# =============================================================================
# iam-boundary.tf (ROOT) — IAM permissions boundary for every stack-created role
#                          (H5 residual closure)
# -----------------------------------------------------------------------------
# WHAT: a customer-managed IAM policy used as a PERMISSIONS BOUNDARY, attached to
#   every IAM role this stack creates (EKS cluster/node roles, the IRSA roles,
#   the flow-logs role). A boundary is not a grant — it is a CEILING: a role's
#   EFFECTIVE permissions are the INTERSECTION of its identity policy and its
#   boundary. Nothing here gives any role a permission it did not already have.
#
# WHY (the H5 finding): the in-VPC runner must be able to create IAM roles — it
#   runs `terraform apply` for the whole stack. Before this file, "can create a
#   role" meant "can create an ADMIN role and pass it to EC2/Lambda", i.e. anyone
#   with `ssm:StartSession` on the runner effectively had FULL ACCOUNT TAKEOVER
#   (whitebox pentest 2026-07-06). The fix is the standard AWS delegation pattern:
#     1. define a boundary that permits everything the stack's roles legitimately
#        do but NO IAM/Organizations/account mutation (this file), and
#     2. deny the runner `iam:CreateRole` / `iam:PutRolePermissionsBoundary`
#        unless the request carries exactly this boundary
#        (`terraform/runner/deploy-policy.tf`).
#   Together those mean: a compromised runner can still create roles, but every
#   role it can create is permanently incapable of IAM privilege escalation.
#
# WHY THE BOUNDARY IS BROAD: its ONLY job is to cap IAM escalation. Least
#   privilege per role is the job of each role's own identity policy (already
#   scoped in modules/iam, modules/eks, etc.). A boundary tight enough to also
#   enforce least privilege would break legitimate roles (the AWS Load Balancer
#   Controller policy alone spans ec2/elasticloadbalancing/acm/wafv2/shield/
#   cognito-idp) for no additional escalation protection. So: allow everything
#   EXCEPT iam:* / organizations:* / account:*, then add back the few IAM actions
#   real roles need (read-only + service-linked-role creation, which the LBC and
#   EKS policies both use).
#
# WHY NOT ON THE RUNNER'S OWN ROLE: the runner role legitimately needs IAM WRITE
#   (it creates the stack's roles). Attaching this boundary to it would make the
#   apply fail. The runner is instead constrained by its identity policy
#   (`terraform/runner/deploy-policy.tf`): resource-scoped IAM writes + this
#   boundary required on create + explicit self-protection denies. The runner
#   role is created by the SEPARATE runner root, applied from the laptop by an
#   admin — never by the runner itself.
#
# WHEN: created in the very first (Phase A, laptop) apply, before any role that
#   references it. Roles carry it from birth, so the runner's Phase C apply never
#   has to add a boundary to an existing role.
#
# HOW TO DO IT BY HAND: IAM console → Policies → Create policy → JSON (the
#   document below) → name `<name_prefix>-role-boundary`. Then, on every role the
#   stack owns: Roles → <role> → Permissions boundary → Set boundary → pick it.
#   CLI: `aws iam create-policy --policy-name <name_prefix>-role-boundary
#   --policy-document file://boundary.json` then `aws iam put-role-permissions-
#   boundary --role-name <role> --permissions-boundary <arn>`.
#
# FAILURE MODES
#   * An apply fails with `AccessDenied ... explicit deny in a permissions
#     boundary` → a role needs an action the boundary excludes. It will be an
#     iam:* action (everything else is allowed). Add it to
#     `local.boundary_allowed_iam_actions` below — do NOT disable the boundary.
#   * Adopting this on an ALREADY-APPLIED chain: the plan shows an in-place
#     update on each role (adding `permissions_boundary`). That is safe and
#     non-disruptive, but the principal running it needs
#     `iam:PutRolePermissionsBoundary`.
#   * Escape hatch: `enable_iam_permissions_boundary = false` removes the
#     boundary from every role. This RE-OPENS the H5 escalation path and must be
#     paired with keeping the runner off the scoped policy — deploy-test only.
#   * Bring-your-own: set `iam_permissions_boundary_arn` to an organisation-
#     managed boundary and this file creates nothing. That boundary MUST still
#     permit what the stack's roles do, or the cluster breaks.
# =============================================================================

locals {
  # Create our own boundary only when the feature is on AND the operator has not
  # supplied an organisation-managed one.
  create_iam_boundary = var.enable_iam_permissions_boundary && var.iam_permissions_boundary_arn == ""

  # The ARN every stack role gets. `null` (not "") is what aws_iam_role expects
  # for "no boundary" — an empty string is rejected by the AWS API.
  iam_permissions_boundary_arn = (
    var.iam_permissions_boundary_arn != "" ? var.iam_permissions_boundary_arn :
    (local.create_iam_boundary ? aws_iam_policy.role_boundary[0].arn : null)
  )

  # The IAM actions a boundary-capped role is still allowed to perform. Keep this
  # list minimal and NON-MUTATING except for service-linked roles:
  #   * Get*/List*/Simulate* — read-only introspection; several AWS-managed
  #     policies (and the EBS CSI driver) call iam:GetRole / iam:ListRoles.
  #   * CreateServiceLinkedRole — required by AmazonEKSClusterPolicy and by the
  #     AWS Load Balancer Controller policy. SLRs have AWS-authored trust and
  #     permission policies that a caller cannot choose, so they are not an
  #     escalation vector.
  # NOTE: iam:PassRole is deliberately ABSENT — a boundary-capped role that could
  # pass a non-capped role to a service would be an escalation path again.
  boundary_allowed_iam_actions = [
    "iam:GetRole",
    "iam:GetRolePolicy",
    "iam:GetInstanceProfile",
    "iam:GetOpenIDConnectProvider",
    "iam:GetPolicy",
    "iam:GetPolicyVersion",
    "iam:GetServiceLinkedRoleDeletionStatus",
    "iam:ListRoles",
    "iam:ListRolePolicies",
    "iam:ListAttachedRolePolicies",
    "iam:ListRoleTags",
    "iam:ListInstanceProfiles",
    "iam:ListOpenIDConnectProviders",
    "iam:ListPolicies",
    "iam:CreateServiceLinkedRole",
  ]
}

data "aws_iam_policy_document" "role_boundary" {
  count    = local.create_iam_boundary ? 1 : 0
  provider = aws.primary

  # CEILING #1 — everything except the three identity-control services. This is
  # what makes the boundary safe to attach to any stack role: it never subtracts
  # a permission the role needs to do its actual job (EKS, EC2, ELB, KMS, S3,
  # Secrets Manager, CloudWatch, SNS, ECR for node image pulls, …).
  statement {
    sid         = "AllowAllExceptIdentityControlPlane"
    effect      = "Allow"
    not_actions = ["iam:*", "organizations:*", "account:*"]
    resources   = ["*"]
  }

  # CEILING #2 — add back the narrow IAM surface real roles need. Everything else
  # under iam:* stays outside the ceiling, so a role created by a compromised
  # runner can never grant itself (or anything else) more IAM power.
  statement {
    sid       = "AllowReadOnlyIamAndServiceLinkedRoles"
    effect    = "Allow"
    actions   = local.boundary_allowed_iam_actions
    resources = ["*"]
  }
}

resource "aws_iam_policy" "role_boundary" {
  count    = local.create_iam_boundary ? 1 : 0
  provider = aws.primary

  name        = "${local.name_prefix}-role-boundary"
  description = "H5: permissions boundary for every role this stack creates — caps IAM/Organizations/account mutation so a compromised deploy runner cannot mint an admin role."
  policy      = data.aws_iam_policy_document.role_boundary[0].json

  tags = { Component = "iam", Purpose = "permissions-boundary" }
}

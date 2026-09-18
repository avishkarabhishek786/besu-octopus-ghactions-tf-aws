# =============================================================================
# terraform/runner/variables.tf
# -----------------------------------------------------------------------------
# Inputs are minimal: just where the CHAIN state lives (so this root can read the
# chain's outputs) + the deploy region + instance size. Everything else — VPC,
# subnet, cluster, node SG, the GitHub-token / deploy-config secret names, the
# repo URL — is read from the chain outputs via terraform_remote_state.
# =============================================================================

variable "region" {
  description = <<-EOT
    Deploy region for the runner EC2. MUST equal the chain's primary_region — the
    runner exists to reach the private EKS endpoint from inside the VPC, which is
    impossible from another region.

    No default: a runner that silently lands in a different region than the cluster
    fails with a confusing timeout rather than a clear error.
  EOT
  type        = string
}

variable "instance_type" {
  description = "Runner instance type. t3.small is ample (short-lived)."
  type        = string
  default     = "t3.small"
}

variable "runner_subnet_az_id" {
  description = <<-EOT
    Which ledger subnet the runner lives in, by AZ ID (the chain's
    `ledger_subnet_ids` output is keyed by AZ ID, #5). Empty = the first AZ in
    sorted order — deterministic, so a re-apply never moves the runner.

    It matters more than it used to: the egress allowlist source (CD-60) is an
    address IN this subnet, so changing the AZ means changing the ticket.
  EOT
  type        = string
  default     = ""
}

variable "runner_private_ip" {
  description = <<-EOT
    CD-60: pin the runner's private IP so the egress proxy can allowlist a /32.
    Empty (default) = use the hand-over's `egress_allowed_source` (minus its
    /32) when that file is present, otherwise let AWS pick. Set it explicitly
    only to override the hand-over, which you should not normally need.

    Must be inside the chosen ledger subnet (plan-time check in the module) and
    outside AWS's reserved first four / last one addresses.
  EOT
  type        = string
  default     = ""
}

# H5: BREAK-GLASS. Default false → the runner attaches the SCOPED deploy policy
# (deploy-policy.tf), not AdministratorAccess. Flip to true ONLY as a temporary
# unblock if the scoped policy is missing a permission the stack apply needs; then
# capture the denied action (CloudTrail) and add it to deploy-policy.tf so the
# scoped policy remains the permanent default. See deploy-policy.tf header.
variable "runner_scope" {
  description = <<-EOT
    CD-54 — how much of the stack this runner deploys, which decides how much IAM
    it needs. The minimum is a FUNCTION OF THE SPLIT, not an absolute.

      "full-stack"  (default) the runner can apply the WHOLE chain root, so it
                    needs the broad policy in deploy-policy.tf: account-wide
                    ec2/eks/elasticloadbalancing writes, scoped IAM role
                    creation, KMS key management. Keep this while the runner is
                    the thing that applies `chain`.

      "in-cluster"  Octopus's `besu-infra` project owns the AWS layer (CD-53), so
                    the runner is left with the in-cluster layer, the preflight
                    checks, the operational scripts and break-glass. Selects
                    deploy-policy-incluster.tf, which drops ALL IAM writes — and
                    with them the entire H5 escalation surface, since absence of
                    capability beats a deny.

    ⚠ SWITCHING TO "in-cluster" FAILS AT APPLY TIME, NOT PLAN TIME. That is how
    every IAM reduction fails: the plan looks perfect and the run dies twenty
    minutes in with AccessDenied, after money has been spent. Run
    scripts/validation/simulate-runner-policy.sh first — it is free and catches
    most gaps — and validate on a mock before go-live (H5 acceptance).
  EOT
  type        = string
  default     = "full-stack"

  validation {
    condition     = contains(["full-stack", "in-cluster"], var.runner_scope)
    error_message = "runner_scope must be \"full-stack\" or \"in-cluster\"."
  }
}

variable "use_admin_deploy_policy" {
  description = "BREAK-GLASS: attach AWS-managed AdministratorAccess to the runner instead of the scoped H5 deploy policy. Keep false in prod."
  type        = bool
  default     = false
}

# H5: the service allowlist that replaces the old PowerUser-shaped
# `NotAction ["iam:*","organizations:*","account:*"]`. DERIVED from the stack's
# actual resource inventory (terraform/ + modules/): acm-pca (ca_mode="aws"),
# cloudtrail, cloudwatch alarms, ec2/VPC, eks, elasticloadbalancing (the NLBs),
# logs, resource-groups, sns (alerting), the SSM parameter reads the EKS AMI
# lookup performs, sts:GetCallerIdentity, and the tagging API the Resource Group
# uses. DELIBERATELY ABSENT (each has its own resource-scoped statement in
# deploy-policy.tf): iam, kms, s3, secretsmanager.
#
# It is a VARIABLE, not a hardcoded list, so a missing permission is a tfvars
# change during a deploy rather than a code edit + re-review (see
# runner_deploy_extra_actions for the additive escape hatch).
variable "deploy_service_actions" {
  description = "H5: base service allowlist for the scoped runner deploy policy. Sensitive stores (iam/kms/s3/secretsmanager) are scoped separately and must NOT be added here."
  type        = list(string)
  default = [
    "acm-pca:*",              # PKI module when ca_mode = "aws"
    "autoscaling:Describe*",  # EKS managed node groups surface an ASG
    "cloudtrail:*",           # observability: the audit trail
    "cloudwatch:*",           # observability: metric alarms
    "ec2:*",                  # VPC, subnets, NAT, EIP, SGs, flow logs, LT, instances, endpoints
    "eks:*",                  # cluster, node group, addons, access entries
    "elasticloadbalancing:*", # SWIFT + app NLBs, target groups, listeners
    "logs:*",                 # log groups for the cluster + pods
    "resource-groups:*",      # the DeletionGroup-keyed resource group
    "sns:*",                  # Alertmanager → SNS → email
    "ssm:DescribeParameters",
    "ssm:GetParameter",
    "ssm:GetParameters",
    "ssm:GetParametersByPath",
    "sts:GetCallerIdentity",

    # ECR pull. MISSING until 2026-09-10 -- an omission from the move to ECR
    # (CT-3a) that would have failed verify-images.sh from the runner, which is
    # the one place the RUNBOOK insists it must run because a laptop passes
    # while the cluster still cannot pull. GetAuthorizationToken is
    # registry-level (resource always "*"); the pull actions stay unscoped
    # because the registry is in a central shared-services account (#25b) and
    # the other half of the grant is that account's repository policy.
    "ecr:GetAuthorizationToken",
    "ecr:BatchGetImage",
    "ecr:GetDownloadUrlForLayer",
    "ecr:BatchCheckLayerAvailability",
    "ecr:DescribeRepositories",
    "ecr:DescribeImages",
    "ecr:ListImages",
    "tag:GetResources",
    "tag:TagResources",
    "tag:UntagResources",
  ]
}

# Additive escape hatch. When an apply is denied an action, add it HERE in the
# runner tfvars and re-apply — no code change, and the anti-escalation Denies in
# deploy-policy.tf still override anything added (you cannot re-open escalation
# through this list).
variable "deploy_extra_actions" {
  description = "H5: extra actions to append to the scoped deploy policy (unblock a denied apply without editing module code). Denies still win."
  type        = list(string)
  default     = []
}

# Extra Secrets Manager ARNs the runner may touch, beyond this stack's `besu-*`
# and `<name_prefix>-*` namespaces (e.g. an org-managed secret the deploy reads).
variable "deploy_extra_secret_arns" {
  description = "H5: additional Secrets Manager ARN patterns the runner deploy policy may access."
  type        = list(string)
  default     = []
}

# Extra S3 ARNs beyond the Terraform state bucket and the stack's own buckets.
# Supply BOTH the bucket and the object ARN (`arn:aws:s3:::b` and `arn:aws:s3:::b/*`).
variable "deploy_extra_s3_arns" {
  description = "H5: additional S3 bucket/object ARNs the runner deploy policy may access."
  type        = list(string)
  default     = []
}

# H5 guardrail override. The scoped policy can only enforce "every role the runner
# creates is boundary-capped" if the CHAIN was applied with a permissions boundary.
# If it was not, the anti-escalation denies are omitted and the policy quietly
# degrades to PowerUser+scoped-stores. The precondition in deploy-policy.tf fails
# the plan in that case; this var is the deliberate, documented override.
variable "allow_unbounded_deploy_policy" {
  description = "H5: proceed even though the chain has no IAM permissions boundary (scoped policy cannot prevent privilege escalation). Deploy-test only — never for go-live."
  type        = bool
  default     = false
}

# --- Chain remote_state locator (where the chain root wrote its state) --------
variable "chain_state_bucket" {
  description = "S3 bucket holding the chain root's state."
  type        = string
}
variable "chain_state_key" {
  description = <<-EOT
    State key of the chain root, e.g. "besu/sit/chain.tfstate".

    NO DEFAULT, DELIBERATELY. It carried a stale inherited default
    ("besu/prod/main.tfstate") that matched neither this project's key convention nor
    any environment — so a forgotten value would silently read the WRONG state, or
    none, and the runner would build against another environment's cluster.
    The environment segment is required: see CLAUDE.md §2.
  EOT
  type        = string
}
variable "chain_state_region" {
  description = "Region of the chain state bucket. Often differs from the deploy region — state may live centrally."
  type        = string
}

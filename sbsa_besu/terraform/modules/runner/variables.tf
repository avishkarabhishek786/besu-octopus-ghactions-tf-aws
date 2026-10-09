# =============================================================================
# modules/runner/variables.tf
# -----------------------------------------------------------------------------
# Inputs for the In-VPC EC2 Runner — a small EC2 instance in a PRIVATE subnet,
# reachable only through SSM Session Manager (no SSH, no public IP). It exists
# to run `terraform apply` / `helm` / `kubectl` against the cluster's PRIVATE
# API endpoint, which a laptop outside the VPC cannot reach (CLAUDE.md §3).
# =============================================================================

variable "name_prefix" {
  description = "Prefix for runner resource names."
  type        = string
}

variable "vpc_id" {
  description = "VPC the runner lives in (the cluster VPC)."
  type        = string
}

variable "subnet_id" {
  description = "PRIVATE subnet ID to place the runner in. No NAT or egress required (D-21): SSM reaches it through the ssm/ssmmessages/ec2messages interface endpoints, and the toolchain arrives over the S3 gateway endpoint."
  type        = string
}

variable "private_ip" {
  description = <<-EOT
    CD-60: pin the runner's primary private IP. The bank's egress proxy
    allowlists by SOURCE, and a /32 is the narrowest thing we can ask for — but
    only if the address never changes. Stop/start already preserves a VPC
    instance's private IP; pinning makes destroy/recreate produce the same
    address too, so the allowlist entry (and the Tentacle registration behind
    it, CD-61) survives a rebuild.

    Must lie inside `subnet_id` and outside AWS's reserved addresses (the first
    four and the last one of the subnet). The subnet check is a plan-time
    precondition; the reserved-range check is left to the EC2 API, which
    refuses those addresses with a clear InvalidIPAddress error.

    null (default) = let AWS pick, which is fine until an egress allowlist
    depends on it.
  EOT
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "EKS cluster name — used for the EKS access entry and for `aws eks get-token` on the runner."
  type        = string
}

variable "cluster_primary_security_group_id" {
  description = "The EKS-managed cluster security group ID (eks module output node_security_group_id). Attached to the runner so it is INSIDE the group allowed to reach the private API endpoint on 443."
  type        = string
}

variable "region" {
  description = "Region the cluster is in (for kubeconfig/get-token on the runner)."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the runner. t3.small is ample."
  type        = string
  default     = "t3.small"
}

variable "deploy_policy_arn" {
  description = <<-EOT
    IAM policy ARN attached to the runner's instance role, granting the AWS
    permissions needed to run `terraform apply` for this stack.

    H5: REQUIRED — there is deliberately NO DEFAULT. This variable used to default
    to `arn:aws:iam::aws:policy/AdministratorAccess`, which is the exact finding H5
    reported: a private, SSM-reachable box that installs its toolchain over the
    network holding account-wide admin. The caller (terraform/runner) now always
    passes the scoped policy built in deploy-policy.tf, and AdministratorAccess is
    reachable only through the explicit `use_admin_deploy_policy` break-glass.
    Making this required means the admin default can never silently come back.
  EOT
  type        = string
}

variable "tags" {
  description = "Additional tags merged onto runner resources."
  type        = map(string)
  default     = {}
}

# --- Code + config delivery (D-21 / F16) -------------------------------------
variable "artifacts_bucket" {
  description = <<-EOT
    S3 bucket holding the runner's toolchain and source bundle, created by the
    chain root and populated by scripts/runner/push-runner-bundle.sh.

    D-21: the VPC has NO egress. The runner cannot `dnf install`, cannot curl
    dl.k8s.io / rpm.releases.hashicorp.com / awscli.amazonaws.com, and cannot
    clone GitHub — each of those HANGS until timeout instead of failing, and this
    instance is the only path to the private EKS API, so it blocks everything.
    The bundle is fetched over the S3 GATEWAY endpoint, which costs nothing and
    is already required for ECR image layers.
  EOT
  type        = string
}

variable "artifacts_bucket_arn" {
  description = "ARN of the artefact bucket. Used to scope the instance role's read access to exactly this bucket rather than to S3 broadly."
  type        = string
}

variable "deploy_config_secret_name" {
  description = "Secrets Manager secret NAME holding the gitignored env config bundle (base64 .tar.gz, F16). Fetched + extracted at boot; SOFT-fails if not yet pushed, so the operator can push it after the runner is up. Empty skips config delivery."
  type        = string
  default     = ""
}

# =============================================================================
# variables.tf — every instance-, bank- and person-specific value (CD-10).
# =============================================================================

variable "octopus_server_url" {
  description = "https://<instance>.octopus.app (or the bank's server)."
  type        = string
}

variable "space_name" {
  description = "The space Terraform manages objects in. It must already exist (creating a space needs system-administrator rights)."
  type        = string
  default     = "Default"
}

variable "project_group_name" {
  description = "Project group holding the three projects."
  type        = string
  default     = "Besu"
}

variable "environments" {
  description = "Octopus environment NAMES in promotion order (CD-41). Their lower-case forms are the slugs used in state keys, secret and role names, and the OIDC subject."
  type        = list(string)
  default     = ["SIT", "UAT", "PROD"]
}

variable "manage_environments" {
  description = "true: Terraform creates the environments. false: they already exist in the space (e.g. created by hand) and are looked up by name."
  type        = bool
  default     = true
}

variable "approval_environments" {
  description = "Environments whose besu-infra and besu-workloads deployments stop for a manual approval (CD-15, CD-41). besu-validators' gate runs in EVERY environment regardless (CD-5)."
  type        = list(string)
  default     = ["UAT", "PROD"]
}

variable "hosted_worker_pool_name" {
  description = "The Octopus Cloud dynamic worker pool for the AWS layer (public AWS APIs only)."
  type        = string
  default     = "Hosted Ubuntu"
}

variable "package_id" {
  description = "Package ID release.yml pushes to the built-in feed (CD-8)."
  type        = string
  default     = "sbsa-besu-platform"
}

variable "aws_region" {
  description = "The platform's AWS region."
  type        = string
}

variable "aws_role_arns" {
  description = "Environment slug -> deploy role ARN (octopus/aws-trust output deploy_role_arns)."
  type        = map(string)
}

variable "aws_session_duration_seconds" {
  description = "Must EQUAL the deploy role's maximum session duration (Octopus requirement)."
  type        = number
  default     = 3600
}

variable "name_prefix" {
  description = "The prefix octopus/aws-trust used for the deploy-config secrets (its project_name)."
  type        = string
  default     = "sbsa-besu"
}

variable "state_bucket" {
  description = "Terraform state bucket for the platform roots."
  type        = string
}

variable "state_region" {
  description = "Region of the state bucket."
  type        = string
}

variable "cluster_names" {
  description = "Environment NAME -> the EKS cluster the runner targets."
  type        = map(string)
}

variable "chain_extra_args" {
  description = "Environment NAME -> extra -var arguments for the chain root (e.g. node counts for a test run). Empty map for none."
  type        = map(string)
  default     = {}
}

variable "tools_image" {
  description = "The mirrored tools image BY DIGEST, <registry>/<prefix>/alpine/k8s@sha256:… — used by the pull canary and the DNS smoke."
  type        = string

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.tools_image))
    error_message = "tools_image must be pinned by digest (H38)."
  }
}

variable "ledger_namespace" {
  description = "Namespace the validators live in."
  type        = string
  default     = "besu-ledger"
}

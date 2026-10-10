# =============================================================================
# variables.tf — nothing bank- or person-specific is hardcoded (CD-10).
# =============================================================================

variable "project_name" {
  description = "Name prefix for roles and secrets."
  type        = string
  default     = "sbsa-besu"
}

variable "deletion_group" {
  description = "Teardown key. This root is long-lived — it outlives every deployment."
  type        = string
}

variable "owner" {
  description = "Team or email accountable."
  type        = string
}

variable "cost_center" {
  description = "Cost centre for chargeback."
  type        = string
}

variable "region" {
  description = "Region for the deploy-config secrets — the platform's region."
  type        = string
}

variable "octopus_server_url" {
  description = "The Octopus instance, https://<instance>.octopus.app. It is both the OIDC issuer and (as a bare host) the audience."
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+$", var.octopus_server_url))
    error_message = "octopus_server_url must be https://<host> with no path or trailing slash — it is the OIDC issuer verbatim."
  }
}

variable "space_slug" {
  description = "Slug of the Octopus space, as it appears in the OIDC subject (the Default space's slug is `default`)."
  type        = string
  default     = "default"
}

variable "environments" {
  description = "Environment SLUGS, as they appear in the OIDC subject and in role/secret names."
  type        = list(string)
  default     = ["sit", "uat", "prod"]
}

variable "aws_projects" {
  description = "Project SLUGS whose deployments need AWS credentials. besu-workloads and besu-validators run on the In-VPC EC2 Runner with its instance role, so only besu-infra by default."
  type        = list(string)
  default     = ["besu-infra"]
}

variable "deploy_policy_arns" {
  description = "Managed policies attached to every deploy role. Default is broad (CD-67): besu-infra creates EKS, IAM, KMS, endpoints and S3. Narrow it here."
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/AdministratorAccess"]
}

variable "session_duration_seconds" {
  description = "Maximum session. Octopus requires the account's session duration to MATCH the role's maximum; an EKS create alone takes ~15 min, so one hour is the floor."
  type        = number
  default     = 3600
}

variable "oidc_thumbprints" {
  description = "Thumbprints for the OIDC provider. AWS verifies most public issuers against its own trust store and ignores this, but some provider versions still require a value; leave empty unless the plan demands one."
  type        = list(string)
  default     = []
}

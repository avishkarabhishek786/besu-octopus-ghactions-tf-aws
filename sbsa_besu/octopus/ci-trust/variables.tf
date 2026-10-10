# =============================================================================
# variables.tf — nothing bank- or person-specific is hardcoded (CD-10).
# =============================================================================

variable "octopus_server_url" {
  description = "https://<instance>.octopus.app (or the bank's server)."
  type        = string
}

variable "space_name" {
  description = "The space the three Besu projects live in. It must already exist."
  type        = string
  default     = "Default"
}

variable "service_account_username" {
  description = "The CI service account. It has no password and no API key — GitHub signs in as it through OIDC."
  type        = string
  default     = "besu-ci"
}

variable "project_names" {
  description = "Projects CI may push packages for and create releases in. octopus/terraform creates them; they must exist before this root is applied."
  type        = list(string)
  default     = ["besu-infra", "besu-workloads", "besu-validators"]
}

variable "deploy_environments" {
  description = "Environment NAMES in which CI's releases may deploy. Creating a release deploys the lifecycle's first phase automatically (CD-41), so this is that phase — SIT — and NEVER UAT or PROD (CD-15, CD-41)."
  type        = list(string)
  default     = ["SIT"]

  validation {
    condition     = length([for e in var.deploy_environments : e if contains(["UAT", "PROD"], upper(e))]) == 0
    error_message = "CI must not be able to deploy UAT or PROD (CD-15, CD-41). Promotions beyond SIT are made by a person, in Octopus."
  }
}

variable "github_repository" {
  description = "<owner>/<name> of the repository whose workflow may sign in."
  type        = string

  validation {
    condition     = can(regex("^[^/*]+/[^/*]+$", var.github_repository))
    error_message = "github_repository must be <owner>/<name>, with no wildcard."
  }
}

variable "github_ids" {
  description = <<-EOT
    Numeric owner and repository IDs, for the `sub` format of repositories
    created after 2026-07-15: repo:<owner>@<owner-id>/<name>@<repo-id>:ref:<ref>
    (observed 2026-10-10, CD-66). From the API: GET /repos/<owner>/<name> ->
    .owner.id and .id. null for an older repository, whose `sub` has no IDs.
  EOT
  type = object({
    owner      = string
    repository = string
  })
  default = null
}

variable "allowed_refs" {
  description = "Git refs the release workflow may run from. Exact matches; one OIDC identity is created per ref."
  type        = list(string)
  default     = ["refs/heads/main"]
}

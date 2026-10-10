# =============================================================================
# variables.tf
# -----------------------------------------------------------------------------
# What the cloud team would decide when granting our CI push to the central
# registry (#25b, CD-27, R-5b): which repository, which refs, which prefix.
# Nothing GitHub- or bank-specific is hardcoded (CD-10).
# =============================================================================

# --- Identity & tagging -------------------------------------------------------
variable "project_name" {
  description = "Project identifier used in resource names and the Project tag."
  type        = string
  default     = "sbsa-besu"
}

variable "environment" {
  description = "Environment name (sit | uat | prod)."
  type        = string
}

variable "deletion_group" {
  description = "UNIQUE per deployment. Teardown tooling keys on this tag."
  type        = string
}

variable "owner" {
  description = "Team or email accountable for these resources."
  type        = string
}

variable "cost_center" {
  description = "Cost centre for chargeback."
  type        = string
}

variable "region" {
  description = "The REGISTRY's region. Must be the VPC's region: the ecr.dkr endpoint reaches only its own region, so images pushed elsewhere are unpullable from the VPC and no endpoint policy fixes it (CD-28)."
  type        = string
}

# --- The grant ----------------------------------------------------------------
variable "github_repository" {
  description = "owner/name of the repository whose workflows may push — the one holding .github/workflows/supply-chain.yml."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be owner/name."
  }
}

variable "allowed_refs" {
  description = <<-EOT
    Git refs whose workflow runs may assume the role, as they appear in the OIDC
    `sub` claim after `ref:`. The workflow runs on push to main and on manual
    dispatch from any branch the operator picks; listing the branches here is
    what stops a run from an arbitrary feature branch pushing to the registry.
  EOT
  type        = list(string)
  default     = ["refs/heads/main"]
}

variable "ecr_prefix" {
  description = "The repository namespace we own. mirror.sh writes <prefix>/<upstream path>; the role may push, and create repositories, only under it. Must equal the workflow's ECR_PREFIX variable and the chain root's registry_repo_prefixes values."
  type        = string
  default     = "mirror"
}

variable "allow_create_repositories" {
  description = "Grant ecr:CreateRepository under the prefix — the 'scoped role that can create them under our prefix' R-5b asks for. false models a cloud team that creates repositories on request."
  type        = bool
  default     = true
}

variable "extra_subjects" {
  description = "Additional exact OIDC `sub` values to trust — for the ID-suffixed format of repositories created after 2026-07-15. Paste the value the workflow's 'Show the OIDC subject' step printed; never a wildcard."
  type        = list(string)
  default     = []
}

variable "github_ids" {
  description = <<-EOT
    Numeric owner and repository IDs, for the `sub` format of repositories
    created after 2026-07-15: repo:<owner>@<owner-id>/<name>@<repo-id>:ref:<ref>
    (observed 2026-10-10). From the API: GET /repos/<owner>/<name> -> .owner.id
    and .id. null for an older repository, whose `sub` has no IDs.
  EOT
  type = object({
    owner      = string
    repository = string
  })
  default = null
}

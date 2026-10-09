# =============================================================================
# modules/cluster-contract — inputs
# -----------------------------------------------------------------------------
# Two kinds of input, and the distinction matters:
#
#   THEIR FACTS   arrive from eks-handover.auto.tfvars (contract/eks-handover.tf)
#                 and describe a cluster we do not own. Every one is a silent
#                 dependency until asserted.
#
#   OUR FACTS     are ours to decide and belong in environment tfvars: the
#                 Kubernetes range we have actually tested, the roles we expect
#                 our pods to assume, whether the F32 init container still needs
#                 root. The cloud team cannot tell us these and must not.
#
# Mixing the two is how "the cluster is fine" and "we have tested it" become the
# same sentence.
# =============================================================================

# --- THEIR FACTS (from the hand-over) ----------------------------------------

variable "cluster_name" { type = string }
variable "cluster_endpoint" { type = string }
variable "cluster_version" { type = string }
variable "cluster_region" { type = string }

variable "oidc_provider_arn" {
  type    = string
  default = ""
}
variable "oidc_issuer_url" {
  type    = string
  default = ""
}
variable "pod_identity" {
  type    = bool
  default = false
}

variable "namespace_ledger" { type = string }
variable "namespace_app" {
  type    = string
  default = ""
}
variable "psa_level" {
  type    = string
  default = "baseline"
}

variable "storage_class_name" { type = string }

variable "cluster_provides_lbc" {
  type    = bool
  default = false
}
variable "node_group_dedicated" {
  type    = bool
  default = false
}
variable "node_taint" {
  type    = string
  default = ""
}
variable "node_label" {
  type    = string
  default = ""
}
variable "node_role_arn" {
  type    = string
  default = ""
}
variable "network_policy_enforced" {
  type    = bool
  default = false
}
variable "runner_access_entry_created" {
  type    = bool
  default = false
}

variable "cluster_node_subnet_ids" {
  type    = map(string)
  default = {}
}
variable "cluster_lb_subnet_ids" {
  type    = map(string)
  default = {}
}

# --- OUR FACTS ----------------------------------------------------------------

variable "deploy_region" {
  description = "The region this root deploys into (var.primary_region). Asserted equal to cluster_region: subnet and cluster IDs do not travel between regions."
  type        = string
}

variable "cluster_version_min_tested" {
  description = "The oldest Kubernetes minor our charts and Besu are validated against."
  type        = string
  default     = "1.33"
}

variable "cluster_version_max_tested" {
  description = <<-EOT
    #36 / D-41 — the NEWEST Kubernetes minor we have validated. The CEILING is
    the point of this variable, and it is what makes the gate useful.

    Their upgrade breaks nothing at the moment it lands; it breaks on our NEXT
    apply, when a removed API version stops a chart reconciling — long after the
    upgrade, with nothing connecting the two events. A floor alone cannot catch
    that. Failing the plan when the live cluster is NEWER than this turns an
    upgrade nobody told us about into a plan-time citation of #36.

    Raise it only after running the compatibility pass. Raising it to make a
    plan succeed is the one change that defeats the gate entirely.
  EOT
  type        = string
  default     = "1.36"
}

variable "irsa_role_names" {
  description = <<-EOT
    #31 — our IRSA role NAMES (not ARNs), so their trust policies can be
    asserted. Empty skips the gate, which is reported in `gates_skipped`.

    What it catches: a trust policy that conditions only on the OIDC provider,
    with no `:sub` condition, is assumable by ANY pod in ANY namespace of a
    SHARED cluster. On a cluster we owned that was untidy; here it is a
    cross-tenant path to the validator keys, and nothing fails to announce it.
  EOT
  type        = list(string)
  default     = []
}

variable "node_role_ecr_auth_confirmed" {
  description = <<-EOT
    #38, second half — confirmation that the node role's own IDENTITY policy
    allows `ecr:GetAuthorizationToken`. No repository policy can grant it, and a
    policy scoped to their registry account will refuse ours.

    THIS IS AN ATTESTATION, NOT A MEASUREMENT. The role is in their account; we
    cannot simulate it. It has no default on purpose, so it must be set
    consciously — but setting it true does not make it so. The only real proof
    is scripts/preflight/verify-pull-canary.sh, which pulls as that role.
  EOT
  type        = bool
}

variable "validator_init_runs_as_root" {
  description = "F32 — the ownership-fix init container still runs as uid 0, which `restricted` refuses. Set false once it has been reworked non-root; then psa_level = restricted stops being a blocker (D-33)."
  type        = bool
  default     = true
}

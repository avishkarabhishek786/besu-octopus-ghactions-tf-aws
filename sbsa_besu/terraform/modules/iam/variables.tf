# =============================================================================
# modules/iam/variables.tf
# -----------------------------------------------------------------------------
# Inputs for the IAM module. This module creates the IRSA (IAM Roles for
# Service Accounts) roles that let specific Kubernetes pods assume specific AWS
# IAM roles via the cluster's OIDC provider — the least-privilege mechanism the
# quorum-kubernetes AWS guidance relies on (service account "quorum-node-
# secrets-sa" with a scoped Secrets Manager policy).
# =============================================================================

variable "name_prefix" {
  description = "Prefix for IAM resource names."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster's IAM OIDC provider (output by the eks module). IRSA trust policies reference this."
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the EKS cluster's OIDC provider (without https://). Used to scope the trust policy to specific service accounts."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace where the Besu service accounts live (e.g. \"besu\")."
  type        = string
  default     = "besu"
}

variable "secrets_service_account_name" {
  description = "Name of the Kubernetes service account that Besu pods use to read secrets. Repo convention is \"quorum-node-secrets-sa\"; keep it unless you also change the Helm values."
  type        = string
  default     = "quorum-node-secrets-sa"
}

variable "secrets_arn_prefix" {
  description = "ARN pattern restricting which Secrets Manager secrets the pods may access (e.g. arn:aws:secretsmanager:<region>:<account>:secret:besu-node-*). Enforces least privilege."
  type        = string
}

variable "genesis_service_account_name" {
  description = "Name of the Kubernetes service account the stage-3 genesis Job uses. It gets a SEPARATE role that can WRITE node keys (PutSecretValue) — distinct from the read-only pod role."
  type        = string
  default     = "besu-genesis-sa"
}

variable "node_key_cmk_arn" {
  description = "C12: ARN of the customer-managed KMS CMK the node-key secrets are encrypted with. When non-empty, the pod role gets kms:Decrypt and the genesis role gets kms:Decrypt+GenerateDataKey, scoped to this key. Empty = secrets use the AWS-managed key and no kms statement is added."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags merged onto module resources."
  type        = map(string)
  default     = {}
}

# H5: permissions boundary applied to every IAM role this module creates. A
# boundary is a CEILING, not a grant — it caps what the role can ever do (no
# iam:*/organizations:*/account: mutation) so a compromised deploy runner cannot
# create a role that escalates to account admin. Threaded from the root
# (terraform/iam-boundary.tf). null = no boundary (deploy-test escape hatch only).
variable "permissions_boundary" {
  description = "H5: ARN of the IAM permissions-boundary policy to attach to roles created by this module. null = none."
  type        = string
  default     = null
}

# =============================================================================
# modules/storage-csi/variables.tf
# -----------------------------------------------------------------------------
# Inputs for the storage + secrets CSI module:
#   * EBS CSI driver (as an EKS addon) with its own IRSA role
#   * A gp3 StorageClass with allowVolumeExpansion = true
#   * The Secrets Store CSI driver + AWS provider (via Helm), enabling pods to
#     mount AWS Secrets Manager secrets as files (the key-fetch mechanism)
# =============================================================================

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name (for the EBS CSI addon)."
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS OIDC provider ARN (for the EBS CSI driver's IRSA role)."
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS OIDC provider URL without https:// (for IRSA trust scoping)."
  type        = string
}

variable "reclaim_policy" {
  description = "Reclaim policy for the gp3 StorageClass. Production default 'Retain' keeps EBS volumes (and chain data) even if a PVC/PV is deleted in Kubernetes."
  type        = string
  default     = "Retain"

  validation {
    condition     = contains(["Retain", "Delete"], var.reclaim_policy)
    error_message = "reclaim_policy must be 'Retain' or 'Delete'."
  }
}

variable "deploy_in_cluster_resources" {
  description = <<-EOT
    Whether to create the IN-CLUSTER resources (the gp3 StorageClass and the
    Secrets Store CSI Helm release). These talk to the Kubernetes API, so they
    can only be applied from a host that has a PRIVATE network path to the EKS
    API endpoint (inside the VPC, a peered VPC, or via VPN/SSM).

    Set FALSE when applying from outside the VPC (e.g. a laptop) against a
    private-endpoint cluster — Terraform will create the AWS-layer parts (EBS
    CSI addon + IRSA roles, which are AWS API calls and work from anywhere) and
    SKIP the in-cluster parts to avoid an i/o timeout to the private endpoint.

    Set TRUE when applying from inside the VPC (the real deployment pattern; see
    CLAUDE.md stage 3), so the StorageClass and Secrets Store CSI driver get
    created. The AWS-layer EBS CSI addon is ALWAYS created regardless of this
    flag, because the in-cluster StorageClass depends on it and it is a pure AWS
    API call.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags merged onto AWS resources in this module."
  type        = map(string)
  default     = {}
}

# C11: tags the EBS CSI driver stamps on every DYNAMICALLY PROVISIONED volume
# (via StorageClass tagSpecification_N parameters). CSI volumes are created by
# the driver, not Terraform, so provider default_tags never reach them — without
# this, PVC-backed chain-data volumes carry no DeletionGroup tag and escape the
# tag-keyed teardown sweep (2026-07-02: 79 such orphans, ~2.5 TB, found+purged).
# Pass local.common_tags (must include DeletionGroup).
variable "volume_tags" {
  description = "Tags the EBS CSI driver applies to every volume it provisions (tagSpecification). Include DeletionGroup so teardown sweeps find PVC volumes."
  type        = map(string)
  default     = {}
}

# H10: pin the aws-ebs-csi-driver addon (resolve-then-pin). Empty = EKS
# default-for-cluster-version (prior behavior); a value pins it explicitly.
variable "ebs_csi_addon_version" {
  description = "H10: pinned aws-ebs-csi-driver addon version. Empty = EKS default-for-cluster-version. Pin for prod reproducibility."
  type        = string
  default     = ""
}

# H20: customer CMK for chain-data PVC at-rest encryption (StorageClass kmsKeyId).
# Empty = AWS-managed aws/ebs key. When set, the CMK policy must allow the EBS CSI
# driver's IRSA role to use it.
variable "data_cmk_arn" {
  description = "H20: customer CMK ARN for chain-data PVC encryption (gp3 StorageClass kmsKeyId). Empty = AWS-managed key."
  type        = string
  default     = ""
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

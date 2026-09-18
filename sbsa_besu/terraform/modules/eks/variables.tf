# =============================================================================
# modules/eks/variables.tf
# -----------------------------------------------------------------------------
# Inputs for the EKS module: the cluster, its OIDC provider (for IRSA), the
# managed node group, and core addons. Instantiated once per region.
# =============================================================================

variable "name_prefix" {
  description = "Prefix for EKS resource names."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name (must match the cluster_name passed to the network module so subnet discovery tags line up)."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS control plane Kubernetes version (e.g. \"1.31\")."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID from the network module."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs where worker nodes and the cluster ENIs live."
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "Whether the cluster API endpoint is publicly reachable. MUST be false for a fully-private network."
  type        = bool
  default     = false
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach a public API endpoint (only used when endpoint_public_access = true)."
  type        = list(string)
  default     = []
}

variable "node_count" {
  description = "Desired worker node count."
  type        = number
}

variable "node_min" {
  description = "Minimum worker node count (autoscaler floor)."
  type        = number
}

variable "node_max" {
  description = "Maximum worker node count (autoscaler ceiling)."
  type        = number
}

variable "instance_type" {
  description = "EC2 instance type for worker nodes."
  type        = string
}

variable "node_volume_size_gib" {
  description = "EBS gp3 volume size (GiB) for worker nodes."
  type        = number
}

variable "log_retention_days" {
  description = "Retention for EKS control plane logs in CloudWatch."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Additional tags merged onto module resources."
  type        = map(string)
  default     = {}
}

# H7: envelope-encrypt Kubernetes Secrets in etcd with a dedicated customer CMK.
# Without it, etcd Secrets are protected only by the AWS-managed EKS layer, not a
# key we control/audit. NOTE: enabling encryption on a cluster is a ONE-WAY change
# (it cannot be removed once set) — fine for fresh applies; irreversible in place.
variable "enable_secrets_encryption" {
  description = "H7: envelope-encrypt K8s Secrets in etcd with a dedicated CMK. Keep true for prod. One-way once enabled on a cluster."
  type        = bool
  default     = true
}

variable "secrets_kms_deletion_window_days" {
  description = "Deletion window (days, 7-30) for the EKS secrets-encryption CMK on destroy. Short for deploy-tests; longer for prod."
  type        = number
  default     = 7
}

# H10: pin the core EKS addons (resolve-then-pin, CLAUDE.md §6). Empty = EKS
# default-for-cluster-version (prior behavior); a value pins that addon so a
# cluster-version bump does not silently move it. Sequence addon upgrades as their
# own reviewed step, never bundled with a cluster_version bump.
variable "addon_versions" {
  description = "H10: pinned EKS core addon versions {vpc_cni, coredns, kube_proxy}. Empty string = EKS default-for-cluster-version. Pin explicitly for prod reproducibility."
  type = object({
    vpc_cni    = optional(string, "")
    coredns    = optional(string, "")
    kube_proxy = optional(string, "")
  })
  default = {}
}

# H6/H10: enable the VPC CNI NetworkPolicy agent (enableNetworkPolicy=true) so the
# besu-node NetworkPolicies enforce. Pair with networkPolicy.enabled in the chart.
variable "enable_network_policy" {
  description = "Enable the VPC CNI NetworkPolicy agent so besu-node NetworkPolicies enforce (H6). Default false; enable with the chart's networkPolicy.enabled."
  type        = bool
  default     = false
}

# H20: customer CMK for node root EBS at-rest encryption. Empty = AWS-managed aws/ebs
# key (current behavior). When set, the CMK policy MUST allow EBS + the node role.
variable "data_cmk_arn" {
  description = "H20: customer CMK ARN for node EBS at-rest encryption. Empty = AWS-managed key. The CMK policy must permit EBS + the node/autoscaling role."
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

# -----------------------------------------------------------------------------
# Private-registry trust (CT-3, air-gapped supply chain)
# -----------------------------------------------------------------------------
variable "ami_type" {
  description = <<-EOT
    Managed node group AMI family. Set EXPLICITLY rather than left to the API
    default because the user_data contract depends on it: AL2023 requires MIME
    multipart user data, and a plain shell script there means the node never
    finishes bootstrapping. AL2 is end-of-life and rejected on 1.33+.
  EOT
  type        = string
  default     = "AL2023_x86_64_STANDARD"

  validation {
    condition     = startswith(var.ami_type, "AL2023_")
    error_message = "Only AL2023 families are supported: the launch template emits MIME multipart user data, which AL2 does not accept."
  }
}

variable "extra_ca_cert_pem" {
  description = <<-EOT
    PEM of a private CA to install into the node OS trust store, so containerd
    can pull from a registry presenting a certificate from it. Not needed for
    ECR, which is publicly trusted. Empty
    leaves the AMI trust store untouched.

    Delivered inline in the launch template rather than fetched at boot from
    Secrets Manager, deliberately. A CA certificate is not secret, and a
    boot-time fetch would make image-pull trust depend on a network call made
    BEFORE trust is established — if it failed, the node would join and then
    fail every pull with a generic ImagePullBackOff naming nothing. Inline is
    deterministic: the node either has the trust or the launch template is
    visibly wrong. Rotating the CA rolls the nodes, which is the correct blast
    radius for changing what the fleet trusts.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.extra_ca_cert_pem == "" || can(regex("^-----BEGIN CERTIFICATE-----", trimspace(var.extra_ca_cert_pem)))
    error_message = "extra_ca_cert_pem must be PEM starting with -----BEGIN CERTIFICATE-----."
  }
}

# =============================================================================
# eks-handover.tf — the cloud team's CLUSTER, as consumed by this project.
# -----------------------------------------------------------------------------
# CT-5 / D-25. Third application of the hand-over rule, after the network
# (network-handover.auto.tfvars) and the egress (egress-handover.auto.tfvars):
# the cluster arrives as PLAIN VALUES in `eks-handover.auto.tfvars`, which
# Terraform loads automatically.
#
# NEVER via `terraform_remote_state`. The real cloud team will not grant state
# access, so building that dependency would work in every deploy-test and fail
# at go-live — the same reasoning that produced the network hand-over.
#
# During development the file is produced by the sibling project:
#   mimic_eks/scripts/emit-handover.sh
# In production it is assembled BY HAND from what the cloud team sends, which is
# the four command outputs in docs/CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md §4.
# Its shape is the contract.
#
# NOTHING downstream may read these variables directly — everything consumes
# module.cluster.* instead, so no workload can be deployed onto an unvalidated
# cluster. Same rule as the network contract.
#
# -----------------------------------------------------------------------------
# WHY THE SUBNET INPUTS ARE PREFIXED `cluster_`
# -----------------------------------------------------------------------------
# §12.5 says the subnet inputs MOVE from the network hand-over to this one,
# because under CT-5 they are facts about where the cluster placed us rather
# than about a VPC we lay out. They have not moved yet: the CT-5 banner in
# CLAUDE.md §3 is explicit that nothing is removed until shared-cluster requirements §4 is answered, so
# `lb_subnet_ids` and friends still exist in contract/handover.tf.
#
# An unprefixed name here would therefore be a DUPLICATE VARIABLE in any root
# that loads both files. The prefix makes the overlap visible instead of making
# the plan fail, and at cutover the network copies are deleted and these lose
# nothing. Do not "tidy" the prefix away before that happens.
# =============================================================================

# --- Identity -----------------------------------------------------------------

variable "cluster_name" {
  description = "#32 — the cluster we are a tenant of. Needed for kubeconfig and for every eks:Describe* call."
  type        = string
}

variable "cluster_endpoint" {
  description = "#32 — the API server endpoint. Asserted against the live cluster, because a stale hand-over points the runner at another cluster."
  type        = string
}

variable "cluster_ca_data" {
  description = "#32 — base64 CA bundle for the kubeconfig and the kubernetes/helm providers."
  type        = string
}

variable "cluster_version" {
  description = <<-EOT
    #36 — the Kubernetes minor the cluster is running, as the cloud team reported
    it. Asserted against the live value: if they upgraded without telling us
    (which #29 item 3 exists to prevent), this is the input that disagrees first.
  EOT
  type        = string
}

variable "cluster_region" {
  description = <<-EOT
    The region the cluster lives in. A FACT about the hand-over, not a
    preference — `primary_region` must equal it. Without the assertion a tfvars
    edit could aim the workloads at one region while the subnet and cluster IDs
    belong to another, which fails late and confusingly. Same gate as
    `network_region`, for the same reason.
  EOT
  type        = string
}

# --- Pod identity (#31) -------------------------------------------------------

variable "oidc_provider_arn" {
  description = <<-EOT
    #31 — the IAM OIDC provider ARN, when the cluster uses IRSA. Our roles trust
    it with a condition on `system:serviceaccount:<our-namespace>:<sa>`.
    Mutually exclusive with `pod_identity`; the contract module fails if neither
    or both are set, because the silent failure mode is a pod whose credentials
    fall back to instance metadata and which then runs as the CLOUD TEAM'S NODE
    ROLE — plausibly succeeding, with wider privilege, in their CloudTrail.
  EOT
  type        = string
  default     = ""
}

variable "oidc_issuer_url" {
  description = "#31 — the cluster's OIDC issuer URL. Asserted to match the live cluster's issuer; a mismatch means the provider belongs to a different cluster."
  type        = string
  default     = ""
}

variable "pod_identity" {
  description = <<-EOT
    #31 — true when the cluster uses EKS Pod Identity instead of IRSA. Two
    consequences: we need permission to create pod identity associations (or
    they create them from a list we send), and the VPC needs the **eks-auth**
    interface endpoint, which D-14 deliberately excluded on the assumption of
    IRSA. A missing endpoint in this VPC HANGS rather than errors, so
    verify-endpoints.sh takes `--pod-identity` from this value.
  EOT
  type        = bool
  default     = false
}

# --- Namespaces (#27) ---------------------------------------------------------

variable "namespace_ledger" {
  description = "#27 — the namespace allotted to the ledger. We never create it (D-23)."
  type        = string
}

variable "namespace_app" {
  description = "#27 — the application namespace. Empty when the application estate is not destined for this cluster (Q-8), in which case the listener and app workloads have no home here and that is a design change, not a tfvars change."
  type        = string
  default     = ""
}

variable "psa_level" {
  description = <<-EOT
    #27 / D-33 — the Pod Security Admission ENFORCE level on our namespaces:
    "privileged", "baseline" or "restricted".

    This is the one value most likely to be reported wrongly, and the contract
    module treats it as a gate rather than information. Two reasons:
      * our F32 ownership-fix init container runs as uid 0, which `restricted`
        refuses at admission — the pod never starts and the symptom is a
        StatefulSet with zero replicas;
      * PSA can also be enforced CLUSTER-WIDE through the API server's
        AdmissionConfiguration, which does not appear in a namespace's labels at
        all (question K). So a "baseline" answer here can still be wrong.
    The authoritative check is a bare-Pod server-side dry-run:
    scripts/preflight/verify-admission.sh (D-40). This value gates the plan; that
    script proves the cluster.
  EOT
  type        = string
  default     = "baseline"

  validation {
    condition     = contains(["privileged", "baseline", "restricted"], var.psa_level)
    error_message = "psa_level must be one of: privileged, baseline, restricted (the three Pod Security levels)."
  }
}

# --- Storage (#30) ------------------------------------------------------------

variable "storage_class_name" {
  description = "#30 — the StorageClass we may use for chain data and Postgres. No fallback exists: the chain needs persistent volumes."
  type        = string
}

variable "storage_class_kms_key_arn" {
  description = <<-EOT
    #30 — the key encrypting that class's volumes. Recorded rather than gated,
    because the decision it drives is a governance one: if the key is THEIRS,
    chain data is encrypted under a key we can neither audit nor hold, and a key
    policy change on their side stops the ledger. Empty means the account's EBS
    default key, which is the same problem with less visibility.
  EOT
  type        = string
  default     = ""
}

# --- Cluster-scoped add-ons (#30 / D-24) --------------------------------------
# Each gates an assertion and selects a fallback. We assert, never install.

variable "cluster_provides_lbc" {
  description = "#30 — the AWS Load Balancer Controller is installed and tenants may create TargetGroupBindings. THE ONLY ONE WITH NO FALLBACK: without it the SWIFT and application RPC endpoints cannot be exposed at all, so the contract module fails the plan rather than degrading."
  type        = bool
  default     = false
}

variable "cluster_provides_secrets_store_csi" {
  description = "#30 — the Secrets Store CSI driver and its AWS provider are installed. Fallback: fetch from Secrets Manager at pod start via the pod's own IAM role. Acceptable; the CSI path is preferred."
  type        = bool
  default     = false
}

variable "cluster_provides_prometheus_operator" {
  description = "#30 — the Prometheus Operator CRDs exist and either their Prometheus scrapes us or we may create our own object. Fallback: a plain Prometheus in-namespace."
  type        = bool
  default     = false
}

variable "cluster_provides_log_shipping" {
  description = "#30 — container logs are delivered to a CloudWatch log group we can read and alarm on. Fallback: a sidecar per pod. Acceptable, heavier."
  type        = bool
  default     = false
}

# --- Node placement (#28, #33, #38) -------------------------------------------

variable "node_group_dedicated" {
  description = <<-EOT
    #28 / D-26 — true when a node group is reserved for the ledger namespace
    with a taint only our pods tolerate.

    When FALSE the posture regression is real and the compensating control is
    `network_policy_enforced` (D-9, D-26). The contract module REFUSES the
    combination where both are false, because that is a shared-kernel,
    unenforced-policy deployment of a payment ledger's validators and no gate
    downstream would catch it.
  EOT
  type        = bool
  default     = false
}

variable "node_taint" {
  description = "#28 — the taint to tolerate, as \"key=value:Effect\". Empty when node_group_dedicated is false."
  type        = string
  default     = ""
}

variable "node_label" {
  description = "#28 — the nodeSelector label to target, as \"key=value\". Empty when node_group_dedicated is false."
  type        = string
  default     = ""
}

variable "cluster_node_subnet_ids" {
  description = "Where our pods land, keyed by AZ ID. Drives the F-1..F-6 flow checks (#34) and the #39 headroom reading. Prefixed — see the header."
  type        = map(string)
  default     = {}
}

variable "cluster_lb_subnet_ids" {
  description = "Where we may place the two internal NLBs, keyed by AZ ID. Prefixed — see the header."
  type        = map(string)
  default     = {}
}

variable "cluster_runner_subnet_id" {
  description = "Which subnet the In-VPC EC2 Runner should use (CT-1a). Prefixed — see the header."
  type        = string
  default     = ""
}

variable "node_sg_id" {
  description = "#33 — the node security group, which is THEIRS. Our NLBs target pod IPs, so health checks arrive here and it must admit 8545-8546 from our NLB security groups — or Security Groups for Pods must be enabled instead."
  type        = string
  default     = ""
}

variable "node_role_arn" {
  description = <<-EOT
    #38 — the node group's IAM role: the principal that actually pulls our
    images, via kubelet's ECR credential provider. Our repository policies must
    grant it pull.

    Two halves, and the second cannot be granted by a repository policy at all:
    that role also needs `ecr:GetAuthorizationToken` in its own IDENTITY policy.
    The managed AmazonEC2ContainerRegistryReadOnly policy includes it; one
    hardened to their own registry account will refuse ours. The contract module
    can assert the first half and not the second — see
    `node_role_ecr_auth_confirmed`.
  EOT
  type        = string
  default     = ""
}

# --- Enforcement and access (#35, #32) ---------------------------------------

variable "network_policy_enforced" {
  description = <<-EOT
    #35 — the CNI actually enforces NetworkPolicy (VPC CNI with
    ENABLE_NETWORK_POLICY=true, or Calico/Cilium).

    The API server accepts NetworkPolicy objects whether or not anything
    enforces them, so a default-deny that enforces nothing is indistinguishable
    from one that works. On shared nodes this is our primary tenant boundary
    (D-9 is load-bearing since CT-5), which is why a declared `false` here
    combined with `node_group_dedicated = false` fails the plan.

    A declared `true` is an attestation, not a measurement. The measurement is
    the two-pod deny-probe in scripts/validation/verify-deployed.sh (D-37).
  EOT
  type        = bool
  default     = false
}

variable "runner_access_entry_created" {
  description = "#32 — they created the EKS access entry for the In-VPC EC2 Runner's role, scoped to our namespaces. Nothing can be deployed without it; it is their action, so it is a declared fact we gate on rather than something we can create (D-34)."
  type        = bool
  default     = false
}

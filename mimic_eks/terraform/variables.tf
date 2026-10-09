# =============================================================================
# mimic_eks — variables
# -----------------------------------------------------------------------------
# Everything the CLOUD TEAM would decide when running a shared EKS cluster and
# allotting a tenant a namespace. We impersonate them; nothing here is a
# preference of ours.
#
# Decision references (D-N, CT-N, #N) point at
# sbsa_besu/docs/CLOUD_TEAM_REDESIGN_NOTES.md §12 and
# sbsa_besu/docs/CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md.
# =============================================================================

# --- Identity & tagging -------------------------------------------------------

variable "project_name" {
  type    = string
  default = "sbsa-besu"
}

variable "environment" {
  description = "Must match the mimic_vpc environment whose hand-over this consumes — the subnet IDs come from it."
  type        = string
}

variable "deletion_group" {
  description = "UNIQUE per deployment. Teardown tooling keys on this tag."
  type        = string
}

variable "owner" { type = string }
variable "cost_center" { type = string }

variable "region" {
  description = "Must equal the ledger VPC's region (network_region in the network hand-over)."
  type        = string
}

# =============================================================================
# THE FIDELITY PROFILE — read this before changing any default below.
# =============================================================================
# §12.13.4 and the B12 lesson: a preflight script or a Terraform gate that has
# only ever been seen to PASS is an assumption wearing a check's clothing. This
# project exists to make the platform's gates fire.
#
# So the DEFAULT PROFILE IS "hostile": a cluster that breaks every check the
# platform has. The first time you point `sbsa_besu` at this mimic, it should
# FAIL — in eleven places, each citing a requirement number. Seeing that is the
# deliverable. A mimic that defaults to compliant is a mimic nobody ever runs in
# the mode that has value.
#
#   hostile  — every gate trips. Use it to prove the gates work.
#   strict   — a well-run multi-tenant cluster. Use it to deploy the platform.
#
# Each knob below can be overridden individually (null = follow the profile), so
# you can break exactly ONE thing and confirm exactly one gate fires. That is
# how you tell a gate that works from a gate that happens to be downstream of
# another failure.
# =============================================================================

variable "profile" {
  description = "hostile (default — every platform gate trips) or strict (a compliant cluster). See the block comment above."
  type        = string
  default     = "hostile"

  validation {
    condition     = contains(["hostile", "strict"], var.profile)
    error_message = "profile must be 'hostile' (default; every gate trips) or 'strict' (compliant)."
  }
}

# --- Per-knob overrides. null = follow the profile. --------------------------

variable "psa_level" {
  description = "#27 / D-33. hostile: restricted, which refuses the F32 root init container at admission. strict: baseline."
  type        = string
  default     = null
}

variable "psa_cluster_wide" {
  description = <<-EOT
    Question K. When true the namespace carries NO pod-security label and the
    mimic records that enforcement is cluster-wide instead — reproducing the case
    where `kubectl get ns --show-labels` is MISLEADING and only a bare-Pod
    server-side dry-run finds the truth (D-40).

    The mimic cannot actually set the API server's AdmissionConfiguration on a
    managed control plane, so this flips the LABEL off and sets
    psa_level_effective for the hand-over. It reproduces the information gap,
    which is the thing verify-admission.sh exists to close; it does not reproduce
    the enforcement. Said plainly here so nobody reads a pass as proof.
  EOT
  type        = bool
  default     = null
}

variable "provide_lbc" {
  description = "#30. hostile: false — the one add-on with no fallback is absent. strict: true."
  type        = bool
  default     = null
}

variable "provide_secrets_store_csi" {
  description = "#30. hostile: false (fallback exists). strict: true."
  type        = bool
  default     = null
}

variable "provide_prometheus_operator" {
  description = "#30. hostile: false (fallback exists). strict: true."
  type        = bool
  default     = null
}

variable "provide_log_shipping" {
  description = "#30. hostile: false (fallback exists). strict: true."
  type        = bool
  default     = null
}

variable "enable_network_policy" {
  description = <<-EOT
    #35. hostile: false — the API server accepts NetworkPolicy objects and
    nothing enforces them, which is the failure that is indistinguishable from
    success. Combined with node_group_dedicated = false it also trips the
    platform's ISOLATION FLOOR gate (CG-9), which is the combination the design
    refuses outright. strict: true.
  EOT
  type        = bool
  default     = null
}

variable "node_group_dedicated" {
  description = "#28 / D-26. hostile: false — shared nodes, no taint. strict: true, with a taint and label."
  type        = bool
  default     = null
}

variable "node_count" {
  description = <<-EOT
    #28. hostile: 3 — FEWER NODES THAN VALIDATORS, so D-39's required
    podAntiAffinity leaves the fourth validator Pending. That is the designed,
    loud failure; the point of making it the default is to prove it is loud.
    strict: 4.
  EOT
  type        = number
  default     = null
}

variable "quota_cpu" {
  description = <<-EOT
    #27 / D-36. hostile: "6" — enough for THREE validators, not four. This is
    the most important fixture in the project: QBFT's quorum is 3 of 4, so the
    chain starts, produces blocks and reports healthy with ZERO fault tolerance,
    and the refusal is an event on the StatefulSet with no fourth pod to notice.
    strict: "8", the shared-cluster requirements §1 footprint.
  EOT
  type        = string
  default     = null
}

variable "quota_memory" {
  description = "#27. hostile: 18Gi (three validators' worth). strict: 24Gi per shared-cluster requirements §1."
  type        = string
  default     = null
}

variable "storage_binding_mode" {
  description = "#30. hostile: Immediate — the volume is pinned to an arbitrary AZ before scheduling, which can leave a validator permanently Pending with its data in the wrong zone. strict: WaitForFirstConsumer."
  type        = string
  default     = null
}

variable "storage_allow_expansion" {
  description = "#30. hostile: false — invisible until the chain fills the disk, by which time it is an incident. strict: true."
  type        = bool
  default     = null
}

variable "access_entry_cluster_wide" {
  description = <<-EOT
    #32 / D-37. hostile: true — the runner's access entry is CLUSTER-ADMIN
    rather than scoped to our namespaces. This is the silent direction of #32: a
    cluster-wide grant works exactly as well as a scoped one, so nothing ever
    reports it and only a check that asserts a NEGATIVE finds it. strict: false.
  EOT
  type        = bool
  default     = null
}

variable "grant_custom_resource_rbac" {
  description = "#32. hostile: false — `edit` enumerates built-in kinds, so our four custom resources are refused. Loud, but it blocks a deployment, which is why we want it found now. strict: true."
  type        = bool
  default     = null
}

variable "node_sg_allows_rpc" {
  description = "#33. hostile: false — no ingress for 8545-8546, so NLB health checks fail forever with Target.FailedHealthChecks and nothing names a security group. strict: true."
  type        = bool
  default     = null
}

variable "endpoint_public_access" {
  description = "#32 / CG-2. hostile: true — a public API endpoint, which behaves identically from inside the VPC and is therefore invisible without the gate. strict: false."
  type        = bool
  default     = null
}

variable "kubernetes_version" {
  description = "#36 / D-41. hostile: one minor ABOVE the platform's tested ceiling, to trip the version-ceiling gate. strict: the tested ceiling. Resolve against what the region actually offers — verify-region.sh prints it."
  type        = string
  default     = null
}

# --- Values that are the same in both profiles -------------------------------

variable "runner_role_arn" {
  description = "#32 — the In-VPC EC2 Runner's IAM role, which gets the access entry. From the platform's runner root."
  type        = string
  default     = ""
}

variable "namespace_ledger" {
  type    = string
  default = "besu-ledger"
}

variable "namespace_app" {
  type    = string
  default = "besu-app"
}

variable "instance_type" {
  type    = string
  default = "m6i.xlarge"
}

variable "quota_pods" {
  type    = string
  default = "40"
}

variable "quota_pvc" {
  type    = string
  default = "12"
}

variable "quota_storage" {
  type    = string
  default = "300Gi"
}

variable "node_taint_key" {
  type    = string
  default = "dedicated"
}

variable "node_taint_value" {
  type    = string
  default = "besu-ledger"
}

variable "node_volume_size_gib" {
  description = "Worker node root volume. The cloud team's choice, not ours — and under CT-5 we do not see it. 50 is ample for a fixture."
  type        = number
  default     = 50
}

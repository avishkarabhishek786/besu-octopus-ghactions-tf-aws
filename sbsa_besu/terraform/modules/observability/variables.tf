# =============================================================================
# modules/observability/variables.tf
# -----------------------------------------------------------------------------
# Stage 5 — observability:
#   AWS-layer: SNS topic+email subscription, Fluent Bit log group + IRSA,
#     Alertmanager IRSA (sns:Publish), CloudTrail (+S3), CloudWatch alarm(s).
#   In-cluster (gated): kube-prometheus-stack (Prometheus/Grafana/Alertmanager),
#     aws-for-fluent-bit (pod logs -> CloudWatch), and besu-monitoring (Besu
#     PodMonitor + alert rules + dashboard).
# Trimmed to fit the 2-node non-prod cluster alongside Besu.
# =============================================================================

variable "name_prefix" { type = string }
variable "region" { type = string }
variable "cluster_name" { type = string }
variable "oidc_provider_arn" { type = string }
variable "oidc_provider_url" { type = string }

variable "deploy_in_cluster_resources" {
  description = "Install the in-cluster monitoring/logging Helm releases (needs the private endpoint)."
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Email subscribed to the SNS alerts topic. Empty = create the topic but no subscription."
  type        = string
  default     = ""
}

variable "besu_namespace" {
  type    = string
  default = "besu"
}

variable "monitoring_namespace" {
  type    = string
  default = "monitoring"
}

variable "enable_cloudtrail" {
  description = "Create an account CloudTrail (+ S3 bucket) for API audit. One trail per account is free; extra data events cost."
  type        = bool
  default     = true
}

# H19: gate force_destroy on the audit bucket. true (deploy-test) allows a clean
# teardown; false (prod) makes `terraform destroy` refuse to wipe the forensic record.
variable "cloudtrail_force_destroy" {
  description = "H19: allow `terraform destroy` to delete a non-empty CloudTrail bucket. true for deploy-tests; FALSE for prod (protect the audit trail)."
  type        = bool
  default     = true
}

# H19: customer CMK for the CloudTrail bucket SSE + trail encryption. Empty = SSE-S3
# (AES256). A CMK must allow CloudTrail (cloudtrail.amazonaws.com) to use it.
variable "cloudtrail_kms_key_arn" {
  description = "H19: customer CMK ARN for CloudTrail bucket SSE-KMS + trail kms_key_id. Empty = SSE-S3 (AES256). CMK policy must permit CloudTrail."
  type        = string
  default     = ""
}

variable "node_key_cmk_arn" {
  description = "C12: ARN of the node-key CMK (informational). KMS Decrypt/GenerateDataKey on it are CloudTrail MANAGEMENT events, captured by the base trail — no data-event selector is used (retained input; see F31)."
  type        = string
  default     = ""
}

variable "enable_kms_data_events" {
  description = "C12: RETAINED no-op (F31). KMS crypto ops are CloudTrail MANAGEMENT events (AWS::KMS::Key is not a valid data-event resources.type), so the base trail already logs every Decrypt on the CMK — this flag no longer drives a selector."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "rpc_nlb_arn" {
  description = "RPC NLB ARN (from rpc-access) for the unhealthy-target CloudWatch alarm. Empty = skip that alarm."
  type        = string
  default     = ""
}

variable "rpc_target_group_arn" {
  description = "RPC NLB target group ARN — paired with rpc_nlb_arn for the UnHealthyHostCount alarm dimensions."
  type        = string
  default     = ""
}

variable "enable_nlb_alarm" {
  description = "Whether to create the RPC NLB UnHealthyHostCount alarm. Gated on a KNOWN input (enable_rpc_ingress) rather than the NLB ARN, which is apply-time only and can't drive count."
  type        = bool
  default     = false
}

variable "kube_prometheus_chart_version" {
  description = "Pinned kube-prometheus-stack chart version (verified current stable)."
  type        = string
  default     = "86.2.3"
}

variable "fluentbit_chart_version" {
  description = "Pinned aws-for-fluent-bit chart version."
  type        = string
  default     = "0.2.0"
}

variable "grafana_admin_password" {
  description = "Grafana admin password (non-prod test). Prod should source this from Secrets Manager."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  type    = map(string)
  default = {}
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

# PORTING item 4 — the upstream chart, and the images it carries, from the
# private registry. Both come from the root (local.chart_repository /
# local.chart_images); "" and {} keep the upstream https repository and the
# chart's own image defaults, which only work where there is egress.
variable "chart_repository" {
  description = "OCI repository holding the mirrored upstream charts (oci://<registry>/<path>). Empty = the chart's upstream https repository."
  type        = string
  default     = ""
}

variable "chart_images" {
  description = "Chart-carried images keyed as in mirror.manifest: registry, repository (path inside the registry) and tag. A missing key leaves that chart's image default."
  type = map(object({
    registry   = string
    repository = string
    tag        = string
  }))
  default = {}
}

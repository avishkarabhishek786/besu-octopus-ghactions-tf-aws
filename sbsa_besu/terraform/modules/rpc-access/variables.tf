# =============================================================================
# modules/rpc-access/variables.tf
# -----------------------------------------------------------------------------
# The SWIFT-facing RPC edge (stage 4):
#   AWS-layer (applies anywhere): an INTERNAL NLB (TLS passthrough) + target
#     group + listener + security group locked to the SIPN CIDRs, and an
#     optional PrivateLink endpoint service for the future app VPC.
#   In-cluster (gated): the AWS Load Balancer Controller (so a
#     TargetGroupBinding can register the RPC pods into the target group).
# mTLS is terminated at Besu itself (passthrough), so the NLB stays L4.
# =============================================================================

variable "name_prefix" {
  type = string
}

variable "enable_rpc_ingress" {
  description = "Create the NLB edge (NLB/TG/listener/SG). AWS-layer."
  type        = bool
  default     = true
}

variable "deploy_in_cluster_resources" {
  description = "Install the AWS Load Balancer Controller (in-cluster; needs the private endpoint)."
  type        = bool
  default     = false
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "VPC CIDR — referenced for health-check ingress to the NLB from within the VPC."
  type        = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "cluster_name" {
  type = string
}

variable "cluster_primary_security_group_id" {
  description = "EKS-managed cluster security group (pods' ENIs use it). We add an ingress rule allowing the NLB SG to reach the RPC port — the AWS LB Controller does NOT auto-manage this for a Terraform-owned NLB."
  type        = string
}

variable "region" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  type = string
}

variable "rpc_port" {
  type    = number
  default = 8545
}

variable "swift_sipn_allowed_cidrs" {
  description = "Source CIDRs permitted to reach the RPC NLB (SWIFT SIPN ranges; in non-prod set to the VPC CIDR so the In-VPC EC2 Runner can test)."
  type        = list(string)
  default     = []
}

variable "enable_privatelink" {
  description = "Expose the NLB as a PrivateLink endpoint service for the future app VPC."
  type        = bool
  default     = false
}

variable "lb_controller_chart_version" {
  description = "Pinned aws-load-balancer-controller Helm chart version (verified current stable)."
  type        = string
  default     = "3.4.0"
}

# --- Stage 8: app-rpc edge (separate NLB + HTTP/WS TGs + PrivateLink service) -
variable "enable_app_rpc_ingress" {
  description = "Create the separate app-rpc edge (NLB + HTTP/WS target groups + listeners + dedicated PrivateLink service) for the app pool."
  type        = bool
  default     = false
}

variable "app_rpc_http_port" {
  description = "App-rpc HTTP(S) JSON-RPC port (Besu server-TLS terminated)."
  type        = number
  default     = 8545
}

variable "app_rpc_ws_port" {
  description = "App-rpc WS(S) port (eth_subscribe)."
  type        = number
  default     = 8546
}

variable "app_rpc_ws_enabled" {
  description = "Create the WS target group/listener on the app-rpc edge."
  type        = bool
  default     = true
}

variable "app_rpc_allowed_cidrs" {
  description = "CIDRs allowed to reach the app-rpc NLB (the app VPC CIDR; traffic arrives via PrivateLink)."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}

# H13: enable ELB deletion protection on the SWIFT/app NLBs. false for deploy-tests
# (so teardown works); TRUE for prod (a deleted NLB gets a new DNS name → breaks SWIFT/app).
variable "enable_deletion_protection" {
  description = "H13: ELB deletion protection on the SWIFT/app NLBs. Keep false for deploy-tests; true for prod."
  type        = bool
  default     = false
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

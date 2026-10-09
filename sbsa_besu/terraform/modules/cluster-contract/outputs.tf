# =============================================================================
# modules/cluster-contract — outputs
# -----------------------------------------------------------------------------
# Everything downstream consumes THESE, never the hand-over variables directly,
# so no workload can be deployed onto an unvalidated cluster. Same rule as
# modules/network-contract: `depends_on` the gates, so reading any output forces
# every precondition to have passed first.
# =============================================================================

locals {
  _gates = [
    terraform_data.handover_coherence,
    terraform_data.identity,
    terraform_data.endpoint_access,
    terraform_data.version,
    terraform_data.pod_identity,
    terraform_data.irsa_scoping,
    terraform_data.registry_pull,
    terraform_data.addons,
    terraform_data.pod_security,
    terraform_data.isolation_floor,
    terraform_data.access,
    terraform_data.placement,
  ]
}

output "cluster_name" {
  description = "Validated cluster name."
  value       = var.cluster_name
  depends_on  = [local._gates]
}

output "cluster_endpoint" {
  description = "Validated API endpoint, read from the LIVE cluster rather than echoed from the hand-over — if the two disagreed, CG-1 already failed."
  value       = data.aws_eks_cluster.this.endpoint
  depends_on  = [local._gates]
}

output "cluster_ca_data" {
  description = "Validated CA bundle, from the live cluster."
  value       = data.aws_eks_cluster.this.certificate_authority[0].data
  depends_on  = [local._gates]
}

output "cluster_version" {
  description = "The live Kubernetes version, inside the tested range."
  value       = data.aws_eks_cluster.this.version
  depends_on  = [local._gates]
}

output "vpc_id" {
  description = "The VPC the cluster is in. Useful as a cross-check against the network hand-over's vpc_id."
  value       = data.aws_eks_cluster.this.vpc_config[0].vpc_id
  depends_on  = [local._gates]
}

output "oidc_issuer_url" {
  description = "The live OIDC issuer (empty string when the cluster uses Pod Identity)."
  value       = var.pod_identity ? "" : data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  depends_on  = [local._gates]
}

output "namespace_ledger" {
  value      = var.namespace_ledger
  depends_on = [local._gates]
}

output "namespace_app" {
  value      = var.namespace_app
  depends_on = [local._gates]
}

output "psa_level" {
  value      = var.psa_level
  depends_on = [local._gates]
}

output "storage_class_name" {
  value      = var.storage_class_name
  depends_on = [local._gates]
}

output "node_taint" {
  description = "Empty when #28 was refused, in which case nothing should set a toleration."
  value       = var.node_taint
  depends_on  = [local._gates]
}

output "node_label" {
  value      = var.node_label
  depends_on = [local._gates]
}

output "pod_identity" {
  description = "Drives verify-endpoints.sh --pod-identity: Pod Identity makes the eks-auth endpoint required, and a missing endpoint in this VPC hangs rather than errors (#31, D-14)."
  value       = var.pod_identity
  depends_on  = [local._gates]
}

# -----------------------------------------------------------------------------
# The honest output.
# -----------------------------------------------------------------------------
# A gate that could not run must not read as a gate that passed. Terraform has
# no way to emit a warning from a module, so the roots print this and the
# RUNBOOK says to read it. If this list is non-empty, the cluster is less
# verified than the absence of errors suggests.
output "gates_skipped" {
  description = "Gates that could not be evaluated from here, with the reason. NOT passes. Surface this in the root's output and act on it."
  value       = local.gates_skipped
}

output "gates_run" {
  description = "Count of gates that were evaluated, for the record in docs/test-run-log.md."
  value       = length(local._gates) - length(local.gates_skipped)
}

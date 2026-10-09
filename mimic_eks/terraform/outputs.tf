# =============================================================================
# outputs.tf — read by scripts/emit-handover.sh to render the cluster hand-over.
# -----------------------------------------------------------------------------
# These are the FACTS the cloud team would report, nothing more. Everything the
# platform needs comes from here; anything it needs that is not here is a gap in
# the hand-over contract, not something to look up by hand.
# =============================================================================

output "region" { value = var.region }
output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "cluster_ca_data" { value = module.eks.cluster_ca_certificate }
output "cluster_version" { value = local.k8s_version }

output "oidc_provider_arn" {
  description = "#31 — this mimic always uses IRSA. Set pod_identity in the hand-over by hand to exercise that branch; there is no Pod Identity profile yet."
  value       = module.eks.oidc_provider_arn
}
output "oidc_issuer_url" { value = module.eks.oidc_provider_url }

output "namespace_ledger" { value = var.namespace_ledger }
output "namespace_app" { value = var.namespace_app }

output "psa_level" {
  description = "#27 — what the namespace label SAYS. When psa_cluster_wide is set there is no label, and this is what the platform would be told rather than what is true (question K)."
  value       = local.psa_level
}

output "storage_class_name" { value = local.storage_class_name }
output "storage_class_kms_key_arn" {
  description = "#30 — empty: the mimic's class uses the account's EBS default key. The real answer decides whether chain data is encrypted under a key we can audit."
  value       = ""
}

output "provides_lbc" { value = local.provide_lbc }
output "provides_secrets_store_csi" { value = local.provide_csi }
output "provides_prometheus_operator" { value = local.provide_prom }
output "provides_log_shipping" { value = local.provide_logs }

output "node_group_dedicated" { value = local.dedicated }
output "node_taint" { value = local.dedicated ? "${var.node_taint_key}=${var.node_taint_value}:NoSchedule" : "" }
output "node_label" { value = local.dedicated ? "workload=${var.node_taint_value}" : "" }
output "node_count" { value = local.node_count }

output "node_subnet_ids" { value = local.node_subnet_ids }
output "lb_subnet_ids" { value = var.lb_subnet_ids }
output "node_sg_id" { value = module.eks.node_security_group_id }
output "node_role_arn" { value = module.eks.node_role_arn }

output "network_policy_enforced" { value = local.netpol }
output "runner_access_entry_created" { value = var.runner_role_arn != "" }

output "profile" {
  description = "Which fidelity profile produced this cluster. The hand-over carries it so a confusing platform failure can be traced to 'the mimic is hostile' in one step."
  value       = var.profile
}

output "deliberate_defects" {
  description = <<-EOT
    The defects this cluster carries ON PURPOSE, with the gate each should trip.
    Printed by emit-handover.sh and written into the hand-over as a comment, so
    nobody debugs a fixture for an hour. If the platform does NOT fail on every
    line here, the platform's gate is broken — that is the finding, not the mimic.
  EOT
  value = compact([
    local.public_endpoint ? "public API endpoint -> cluster-contract CG-2 (#32)" : "",
    local.k8s_version == "1.37" ? "k8s ${local.k8s_version} above the tested ceiling -> CG-3 (#36, D-41)" : "",
    !local.provide_lbc ? "no load-balancer controller -> CG-7 (#30), verify-cluster.sh" : "",
    !local.provide_csi ? "no Secrets Store CSI -> verify-cluster.sh WARN (#30, fallback exists)" : "",
    !local.provide_prom ? "no Prometheus Operator -> verify-cluster.sh WARN (#30, fallback exists)" : "",
    local.psa_level == "restricted" ? "namespace enforces restricted -> CG-8 (#27), verify-admission.sh bare-Pod dry-run" : "",
    local.psa_cluster_wide ? "NO pod-security label at all -> only verify-admission.sh can find the truth (question K)" : "",
    !local.dedicated && !local.netpol ? "no dedicated node group AND no NetworkPolicy enforcement -> CG-9 THE ISOLATION FLOOR (#28+#35)" : "",
    !local.netpol ? "NetworkPolicy accepted but not enforced -> verify-deployed.sh --probe-netpol (#35)" : "",
    local.node_count < 4 ? "${local.node_count} nodes for 4 validators -> the 4th stays Pending (D-39), verify-deployed.sh" : "",
    tonumber(local.quota_cpu) < 8 ? "quota requests.cpu=${local.quota_cpu} admits 3 of 4 validators -> verify-cluster.sh, then verify-deployed.sh count gate (#27, D-36)" : "",
    local.storage_binding == "Immediate" ? "StorageClass volumeBindingMode=Immediate -> verify-cluster.sh (#30)" : "",
    !local.storage_expand ? "allowVolumeExpansion=false -> verify-cluster.sh (#30)" : "",
    local.access_cluster_wide ? "runner access entry is CLUSTER ADMIN -> verify-cluster.sh NEGATIVE probes (#32, D-37)" : "",
    !local.crd_rbac ? "no Role for our 4 custom resource kinds -> verify-cluster.sh auth can-i (#32)" : "",
    !local.node_sg_allows_rpc ? "node SG has no 8545-8546 ingress -> verify-deployed.sh target health (#33)" : "",
  ])
}

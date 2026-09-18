# =============================================================================
# modules/besu/outputs.tf
# =============================================================================

output "node_releases" {
  description = "Map of all Besu node releases => role (validators, bootnodes, RPC)."
  value       = { for r, n in local.nodes : r => n.role }
}

output "rpc_service_names" {
  description = "In-cluster RPC ClusterIP service names (stage 4 fronts these with the NLB/PrivateLink)."
  value       = [for r in local.rpc_releases : "${r}-rpc"]
}

output "explorer_rpc_service_names" {
  description = "Stage 9: in-cluster explorer-rpc ClusterIP service names (besu-explorer-rpc-N-rpc). Blockscout points at the first one over HTTP/WS."
  value       = [for r in local.explorer_rpc_releases : "${r}-rpc"]
}

output "explorer_rpc_http_url" {
  description = "Stage 9: in-cluster HTTP RPC URL for Blockscout (first explorer-rpc node). Empty when no explorer-rpc nodes."
  value       = length(local.explorer_rpc_releases) > 0 ? "http://${local.explorer_rpc_releases[0]}-rpc.${var.namespace}.svc.${var.cluster_domain}:${var.rpc_http_port}" : ""
}

output "explorer_rpc_ws_url" {
  description = "Stage 9: in-cluster WS RPC URL for Blockscout (first explorer-rpc node). Empty when no explorer-rpc nodes."
  value       = length(local.explorer_rpc_releases) > 0 && var.explorer_rpc_ws_enabled ? "ws://${local.explorer_rpc_releases[0]}-rpc.${var.namespace}.svc.${var.cluster_domain}:${var.rpc_ws_port}" : ""
}

output "genesis_configmap_name" {
  description = "ConfigMap published by the genesis Job (genesis.json + node-pubkeys.json)."
  value       = "besu-genesis"
}

output "deployed" {
  description = "Whether the Besu Helm releases were created (deploy gate)."
  value       = var.deploy
}

output "service_name" {
  description = "ClusterIP nginx-proxy service for the Blockscout explorer (UI + API, single origin; port-forward target)."
  value       = var.deploy ? "blockscout-proxy" : ""
}

output "portforward_command" {
  description = "Open the private Blockscout explorer (UI + API) from the in-VPC runner (no public endpoint). The local port matches blockscout_access_host."
  value       = var.deploy ? "kubectl -n ${var.namespace} port-forward svc/blockscout-proxy ${split(":", var.access_host)[1]}:80   # then open ${var.access_protocol}://${var.access_host}" : ""
}

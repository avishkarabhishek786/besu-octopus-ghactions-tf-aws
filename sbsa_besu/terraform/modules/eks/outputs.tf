# =============================================================================
# modules/eks/outputs.tf
# -----------------------------------------------------------------------------
# Outputs consumed by modules/iam (OIDC), modules/storage-csi (cluster name +
# OIDC), the Helm/Kubernetes providers in main.tf, and the root outputs.
# =============================================================================

output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint (private)."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate (for kubeconfig / providers)."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "Security group ID of the control plane."
  value       = aws_security_group.cluster.id
}

output "node_security_group_id" {
  description = "Security group ID automatically created for the managed node group (where Besu pods' nodes live). Referenced by later SG rules for P2P/RPC."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_role_arn" {
  description = "IAM role ARN of the worker nodes."
  value       = aws_iam_role.node.arn
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider (for IRSA trust policies)."
  value       = aws_iam_openid_connect_provider.oidc.arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL without the https:// scheme (for IRSA trust policy conditions)."
  value       = replace(aws_iam_openid_connect_provider.oidc.url, "https://", "")
}

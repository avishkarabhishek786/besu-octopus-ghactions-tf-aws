# =============================================================================
# modules/storage-csi/outputs.tf
# =============================================================================

output "storage_class_name" {
  description = "Name of the gp3 StorageClass that Besu PVCs should reference. Null when in-cluster resources were not deployed (deploy_in_cluster_resources = false)."
  value       = var.deploy_in_cluster_resources ? kubernetes_storage_class.gp3[0].metadata[0].name : null
}

output "ebs_csi_role_arn" {
  description = "ARN of the EBS CSI driver IRSA role (AWS-layer; always created)."
  value       = aws_iam_role.ebs_csi.arn
}

output "secrets_store_csi_release" {
  description = "Helm release name of the Secrets Store CSI driver. Null when in-cluster resources were not deployed."
  value       = var.deploy_in_cluster_resources ? helm_release.secrets_store_csi_driver[0].name : null
}

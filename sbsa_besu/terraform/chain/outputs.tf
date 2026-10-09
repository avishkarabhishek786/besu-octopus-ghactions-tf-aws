# =============================================================================
# outputs.tf  (ROOT)
# -----------------------------------------------------------------------------
# Stage-1 outputs. These are the values an operator (or a later stage, or the
# future app layer) needs to interact with what stage 1 built. Later stages add
# outputs for the RPC endpoint, PrivateLink service name, chain ID, CA refs,
# and the SWIFT connection details.
# =============================================================================

output "region" {
  description = "The region this state manages (primary for stage 1)."
  value       = var.primary_region
}

output "deletion_group" {
  description = "The DeletionGroup tag value — pass this to the full-delete script to target this deployment."
  value       = var.deletion_group
}

output "project_name" {
  description = "Project name (for tagging). Consumed by the runner root (C1)."
  value       = var.project_name
}

output "resource_group_name" {
  description = "AWS Resource Group name for console visibility of all this deployment's resources."
  value       = module.resource_group.resource_group_name
}

output "vpc_id" {
  description = "Primary VPC ID."
  value       = module.network_contract.vpc_id
}

output "ledger_subnet_ids" {
  description = "Ledger subnets (where Besu pods run), keyed by AZ ID."
  value       = module.network_contract.ledger_subnet_ids
}

output "eks_cluster_name" {
  description = "EKS cluster name. Use with: aws eks update-kubeconfig --name <this> --region <region>."
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API endpoint (private)."
  value       = module.eks.cluster_endpoint
}

output "eks_node_security_group_id" {
  description = "EKS-managed node security group ID. The In-VPC EC2 Runner (terraform/runner root, C1) attaches to it to reach the private API on 443."
  value       = module.eks.node_security_group_id
}

output "name_prefix" {
  description = "Resource name prefix (project-region-role). Consumed by the runner root (C1) so its resource names match the chain's."
  value       = local.name_prefix
}

# H5: the runner root reads this to build its scoped deploy policy — it denies
# iam:CreateRole / iam:PutRolePermissionsBoundary unless the request carries EXACTLY
# this boundary, so a compromised runner can never mint an unconstrained role.
# Empty string (not null) when the boundary is disabled, so the runner root can
# detect "no boundary" without a type error; see terraform/runner/deploy-policy.tf.
output "iam_permissions_boundary_arn" {
  description = "H5: ARN of the permissions boundary attached to every stack-created IAM role. Empty when enable_iam_permissions_boundary = false."
  value       = local.iam_permissions_boundary_arn == null ? "" : local.iam_permissions_boundary_arn
}

output "besu_secrets_irsa_role_arn" {
  description = "IRSA role ARN for the Besu secrets service account. Annotate the 'quorum-node-secrets-sa' service account with this (done in the Helm values, later stage)."
  value       = module.iam.besu_secrets_role_arn
}

output "storage_class_name" {
  description = "Default gp3 StorageClass name for Besu PVCs. Null if in-cluster resources were skipped (deploy_in_cluster_resources = false, e.g. laptop apply)."
  value       = module.storage_csi.storage_class_name
}

output "kubeconfig_command" {
  description = "Convenience command to point kubectl at this cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.primary_region}"
}

# --- Stage 2: secrets + PKI ---------------------------------------------------

output "ca_mode" {
  description = "CA backend in effect: '' = self-managed (tls provider), 'aws' = AWS Private CA."
  value       = module.pki.ca_mode
}

output "acmpca_ca_arn" {
  description = "ARN of the AWS Private CA when ca_mode='aws'; null for the self-managed default."
  value       = module.pki.acmpca_ca_arn
}

output "validator_key_secret_names" {
  description = "Secrets Manager names for validator node keys (besu-node-validator-1..N). Stage-3 genesis tooling writes the secp256k1 values here (unless use_provided_validator_keys=true)."
  value       = module.secrets.validator_secret_names
}

output "bootnode_key_secret_names" {
  description = "Secrets Manager names for bootnode node keys (besu-node-bootnode-1..M)."
  value       = module.secrets.bootnode_secret_names
}

output "tls_secret_names" {
  description = "Secrets Manager names for the mTLS/RPC material (CA cert, keystore/truststore passwords, RPC JWT) consumed by stage 4."
  value = {
    ca_cert         = module.secrets.ca_cert_secret_name
    ca_private_key  = module.secrets.ca_private_key_secret_name
    keystore_passwd = module.secrets.tls_password_secret_names.keystore
    truststore_pass = module.secrets.tls_password_secret_names.truststore
    rpc_jwt         = module.secrets.rpc_jwt_secret_name
  }
}

output "secrets_store_csi_aws_provider_release" {
  description = "Helm release name of the Secrets Store CSI AWS provider, or null if in-cluster resources were skipped (laptop apply)."
  value       = module.secrets.aws_provider_release
}

# --- Stage 3: Besu workloads + runner -----------------------------------------

output "besu_image" {
  description = "Pinned Besu image deployed by the node chart."
  value       = local.besu_image
}

output "besu_node_releases" {
  description = "Map of Besu node Helm releases => role. Empty until deploy_in_cluster_resources=true (In-VPC EC2 Runner)."
  value       = module.besu.node_releases
}

output "besu_rpc_service_names" {
  description = "In-cluster RPC service names (stage 4 fronts these with the SWIFT NLB/PrivateLink)."
  value       = module.besu.rpc_service_names
}

# runner_ssm_command moved to the runner root (C1): terraform/runner outputs it.

output "runner_artifacts_bucket" {
  description = "S3 bucket holding the runner's toolchain + source bundle (D-21). Populate with scripts/runner/push-runner-bundle.sh after this apply and BEFORE applying terraform/runner."
  value       = aws_s3_bucket.runner_artifacts.bucket
}

output "runner_artifacts_bucket_arn" {
  description = "ARN of the runner artefact bucket — consumed by the runner root to scope the instance role's read access to exactly this bucket."
  value       = aws_s3_bucket.runner_artifacts.arn
}

output "runner_deploy_config_secret" {
  description = "Secrets Manager secret name holding the gitignored env config bundle (F16). Push it with scripts/runner/push-deploy-config.sh."
  value       = aws_secretsmanager_secret.runner_deploy_config.name
}


# --- Stage 4: RPC access / mTLS edge ------------------------------------------

output "rpc_nlb_dns_name" {
  description = "Internal NLB DNS name — the RPC endpoint host SWIFT targets over SIPN (null if the edge is disabled)."
  value       = module.rpc_access.rpc_nlb_dns_name
}

output "rpc_target_group_arn" {
  description = "NLB target group ARN the RPC pods are registered into (via besu-rpc-edge)."
  value       = module.rpc_access.rpc_target_group_arn
}

output "rpc_privatelink_service_name" {
  description = "PrivateLink endpoint service name for the future app VPC (null unless enable_app_privatelink=true)."
  value       = module.rpc_access.privatelink_service_name
}

# --- Stage 8: app-rpc edge (consumed by app/infra via terraform_remote_state) -
output "chain_id" {
  description = "Besu QBFT chain ID (the app's ethers provider/network)."
  value       = var.chain_id
}

output "app_rpc_port" {
  description = "App-rpc HTTPS JSON-RPC port."
  value       = var.app_rpc_http_port
}

output "app_rpc_ws_port" {
  description = "App-rpc WSS port (eth_subscribe)."
  value       = var.app_rpc_ws_port
}

output "app_rpc_scheme" {
  description = "URL scheme for the app-rpc edge (https/wss when TLS is on, else http/ws)."
  value       = var.app_rpc_tls_enabled ? "https" : "http"
}

output "app_rpc_privatelink_service_name" {
  description = "Dedicated app-rpc PrivateLink service name. The app VPC creates an interface endpoint to this. Null unless enable_app_rpc=true."
  value       = module.rpc_access.app_rpc_privatelink_service_name
}

output "app_rpc_nlb_dns_name" {
  description = "Internal app-rpc NLB DNS name (in-VPC; the app reaches it via its PrivateLink endpoint DNS). Null unless enable_app_rpc=true."
  value       = module.rpc_access.app_rpc_nlb_dns_name
}

output "app_rpc_url" {
  description = "Convenience app-rpc HTTPS URL via the chain-side NLB DNS (in-VPC). The app builds its real URL from its own interface-endpoint DNS + app_rpc_port. Null unless enable_app_rpc=true."
  value       = module.rpc_access.app_rpc_nlb_dns_name != null ? "${var.app_rpc_tls_enabled ? "https" : "http"}://${module.rpc_access.app_rpc_nlb_dns_name}:${var.app_rpc_http_port}" : null
}

# --- Stage 5: observability ---------------------------------------------------

output "alerts_sns_topic_arn" {
  description = "SNS topic for alerts (Alertmanager + CloudWatch alarms publish here; email subscribers confirm via the AWS email)."
  value       = module.observability.sns_topic_arn
}

output "pods_log_group" {
  description = "CloudWatch log group receiving pod logs via Fluent Bit."
  value       = module.observability.pods_log_group
}

output "cloudtrail_bucket" {
  description = "S3 bucket holding the CloudTrail audit log (null if disabled)."
  value       = module.observability.cloudtrail_bucket
}

# --- General deployment coordinates -------------------------------------------
output "vpc_cidr" {
  description = "Primary CIDR of the cloud team's VPC, straight from the hand-over. It used to echo var.primary_vpc_cidr, a variable this project no longer has any way to set correctly — the plan reported 10.0.0.0/16 for a VPC that is actually 10.60.0.0/20."
  value       = var.vpc_cidr_primary
}

output "primary_region" {
  description = "Region of this deployment."
  value       = var.primary_region
}

# --- Stage 9: Blockscout explorer (private; reached via the In-VPC EC2 Runner) ----
output "blockscout_portforward_command" {
  description = "Open the private Blockscout UI from the In-VPC EC2 Runner (no public endpoint). Empty unless the explorer is deployed."
  value       = module.blockscout.portforward_command
}

# =============================================================================
# modules/secrets/outputs.tf
# -----------------------------------------------------------------------------
# Names/ARNs that stage 3 (Besu Helm values + genesis tooling) and stage 4
# (mTLS) consume. Secret VALUES are never output.
# =============================================================================

output "validator_secret_names" {
  description = "Ordered list of validator node-key secret names (besu-node-validator-1..N). Stage-3 tooling writes the secp256k1 values into these."
  value       = local.validator_secret_names
}

output "bootnode_secret_names" {
  description = "Ordered list of bootnode node-key secret names (besu-node-bootnode-1..M)."
  value       = local.bootnode_secret_names
}

output "rpc_secret_names" {
  description = "Ordered list of RPC node-key secret names (besu-node-rpc-1..K)."
  value       = local.rpc_secret_names
}

output "ca_cert_secret_name" {
  description = "Secret name holding the public CA certificate (truststore content)."
  value       = aws_secretsmanager_secret.ca_cert.name
}

output "ca_private_key_secret_name" {
  description = "Secret name holding the CA private key (self-managed CA only; null for ca_mode='aws'). Outside the besu-node-* IRSA scope."
  value       = var.ca_mode == "aws" ? null : aws_secretsmanager_secret.ca_private_key[0].name
}

output "tls_password_secret_names" {
  description = "Keystore/truststore password secret names (consumed by stage-4 mTLS)."
  value = {
    keystore   = aws_secretsmanager_secret.keystore_password.name
    truststore = aws_secretsmanager_secret.truststore_password.name
  }
}

output "rpc_jwt_secret_name" {
  description = "Secret name holding the RPC JWT signing secret (consumed by stage-4 method scoping)."
  value       = aws_secretsmanager_secret.rpc_jwt.name
}

output "rpc_tls_secret_names" {
  description = "Stage-4 RPC mTLS material secret names (values written by issue-server-cert.sh)."
  value = {
    keystore        = aws_secretsmanager_secret.rpc_keystore.name
    truststore      = aws_secretsmanager_secret.rpc_truststore.name
    jwt_pubkey      = aws_secretsmanager_secret.rpc_jwt_pubkey.name
    jwt_signing_key = aws_secretsmanager_secret.rpc_jwt_signing_key.name
  }
}

output "app_rpc_secret_names" {
  description = "Stage-8 ordered app-rpc node-key secret names (besu-node-app-rpc-1..J). Genesis tooling writes the secp256k1 values."
  value       = local.app_rpc_secret_names
}

output "explorer_rpc_secret_names" {
  description = "Stage-9 ordered explorer-rpc node-key secret names (besu-node-explorer-rpc-1..E). Genesis tooling writes the secp256k1 values."
  value       = local.explorer_rpc_secret_names
}

output "app_rpc_tls_secret_names" {
  description = "Stage-8 app-rpc TLS+JWT material secret names. keystore/keystore_password/jwt_pubkey are pod-readable (besu-node-*); jwt_signing_key is the app's (outside besu-node-*, read by the app EC2)."
  value = {
    keystore          = aws_secretsmanager_secret.apprpc_keystore.name
    keystore_password = aws_secretsmanager_secret.apprpc_keystore_password.name
    jwt_pubkey        = aws_secretsmanager_secret.apprpc_jwt_pubkey.name
    jwt_signing_key   = aws_secretsmanager_secret.apprpc_jwt_signing_key.name
  }
}

output "aws_provider_release" {
  description = "Helm release name of the Secrets Store CSI AWS provider, or null when in-cluster resources were skipped (deploy_in_cluster_resources = false)."
  value       = var.deploy_in_cluster_resources ? helm_release.secrets_store_csi_provider_aws[0].name : null
}

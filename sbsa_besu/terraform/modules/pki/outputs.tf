# =============================================================================
# modules/pki/outputs.tf
# -----------------------------------------------------------------------------
# The CA material is consumed by modules/secrets (which stores it in Secrets
# Manager) and, later, by stage 4 leaf-cert issuance. We deliberately do NOT
# write to Secrets Manager from here so this module stays a pure "generate CA"
# concern.
# =============================================================================

output "ca_mode" {
  description = "Echoes the CA backend in effect ('' = self-managed, 'aws' = AWS Private CA)."
  value       = var.ca_mode
}

output "ca_cert_pem" {
  description = "PEM-encoded CA certificate (public). Self-managed: the tls self-signed cert. AWS PCA: the issued root certificate. This is the trust anchor distributed to mTLS peers."
  value       = var.ca_mode == "aws" ? aws_acmpca_certificate.root[0].certificate : tls_self_signed_cert.ca[0].cert_pem
}

output "ca_private_key_pem" {
  description = "PEM-encoded CA PRIVATE key. Populated ONLY for the self-managed CA; null for AWS PCA (the key never leaves the acm-pca HSM). Sensitive."
  value       = var.ca_mode == "aws" ? null : tls_private_key.ca[0].private_key_pem
  sensitive   = true
}

output "acmpca_ca_arn" {
  description = "ARN of the AWS Private CA when ca_mode = 'aws'; null otherwise. Stage 4 uses this to issue leaf certs via acm-pca."
  value       = var.ca_mode == "aws" ? aws_acmpca_certificate_authority.this[0].arn : null
}

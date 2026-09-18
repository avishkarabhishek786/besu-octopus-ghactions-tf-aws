# =============================================================================
# modules/pki/main.tf
# -----------------------------------------------------------------------------
# PURPOSE
#   Bootstraps the CERTIFICATE AUTHORITY that anchors the JSON-RPC mTLS plane.
#   Two mutually-exclusive backends, selected by var.ca_mode:
#
#   SELF-MANAGED  (ca_mode = "", the default and the non-prod/test path)
#     * An RSA-4096 CA private key (tls_private_key).
#     * A self-signed CA certificate (tls_self_signed_cert, is_ca = true) valid
#       for ca_validity_days, usable to sign server + client leaf certs.
#     The CA cert (public) and CA key (secret) are emitted as outputs; the
#     secrets module stores them in Secrets Manager. Near-zero cost.
#
#   AWS PRIVATE CA  (ca_mode = "aws")
#     * An acm-pca ROOT certificate authority, self-signed and ACTIVATED by
#       issuing its own root cert from its CSR. AWS holds the private key in an
#       HSM — it is never exported, so ca_private_key_pem is null in this mode.
#     ~USD 400/month: GATED behind count, so it is NEVER created in non-prod
#     (where ca_mode = "").
#
# WHY A CA AT ALL
#   SWIFT reaches JSON-RPC over SIPN as an mTLS client (settled decision: SWIFT
#   is an external RPC client, not a network member). mTLS needs a trust anchor
#   to (a) present a server identity SWIFT can verify and (b) verify client
#   certs SWIFT presents. This module creates that anchor. Leaf-cert issuance
#   (server cert + CSR-signing for clients) happens in stage 4 using this CA.
#
# WHY RSA-4096 FOR THE SELF-MANAGED CA
#   RSA is the most broadly interoperable choice for PKCS12/mTLS toolchains and
#   counterparties like SWIFT; 4096 bits suits a long-lived (10-year) root. Leaf
#   certs (stage 4) can use shorter-lived RSA-2048/ECDSA as appropriate.
# =============================================================================

data "aws_partition" "current" {}

# -----------------------------------------------------------------------------
# SELF-MANAGED CA  (created when ca_mode != "aws")
# -----------------------------------------------------------------------------
# tls_private_key generates the CA key in-memory; its PEM is sensitive and is
# only ever surfaced via the (sensitive) output the secrets module consumes.
resource "tls_private_key" "ca" {
  count = var.ca_mode == "aws" ? 0 : 1

  algorithm = "RSA"
  rsa_bits  = 4096
}

# Self-signed CA certificate. is_ca_certificate = true marks it usable to sign
# other certificates. The allowed_uses are the standard CA usages: signing
# certs and CRLs (revocation lists, used in stage 4 if/when we publish one).
resource "tls_self_signed_cert" "ca" {
  count = var.ca_mode == "aws" ? 0 : 1

  private_key_pem = tls_private_key.ca[0].private_key_pem

  subject {
    common_name  = var.ca_common_name
    organization = var.ca_organization
  }

  # 10-year default root. Hours = days * 24.
  validity_period_hours = var.ca_validity_days * 24

  is_ca_certificate   = true
  set_subject_key_id  = true
  early_renewal_hours = 0
  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]
}

# -----------------------------------------------------------------------------
# AWS PRIVATE CA  (created ONLY when ca_mode = "aws" — never in non-prod)
# -----------------------------------------------------------------------------
# A ROOT CA. A freshly-created acm-pca CA is in PENDING_CERTIFICATE state until
# you install its certificate; for a root that means issuing its OWN cert from
# its CSR (self-signed) and importing it back. The three resources below do
# exactly that. All are gated on ca_mode = "aws".
resource "aws_acmpca_certificate_authority" "this" {
  count = var.ca_mode == "aws" ? 1 : 0

  type = "ROOT"

  certificate_authority_configuration {
    key_algorithm     = "RSA_4096"
    signing_algorithm = "SHA512WITHRSA"
    subject {
      common_name  = var.ca_common_name
      organization = var.ca_organization
    }
  }

  # Non-prod never reaches this branch; in prod, set to false so terraform
  # destroy does not silently leave a CA behind. Operators may prefer 7+ here.
  permanent_deletion_time_in_days = 7

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-rpc-mtls-ca"
    Component = "pki"
  })
}

# Issue the root's self-signed certificate from its own CSR.
resource "aws_acmpca_certificate" "root" {
  count = var.ca_mode == "aws" ? 1 : 0

  certificate_authority_arn   = aws_acmpca_certificate_authority.this[0].arn
  certificate_signing_request = aws_acmpca_certificate_authority.this[0].certificate_signing_request
  signing_algorithm           = "SHA512WITHRSA"

  template_arn = "arn:${data.aws_partition.current.partition}:acm-pca:::template/RootCACertificate/V1"

  validity {
    type  = "YEARS"
    value = 10
  }
}

# Install the issued root cert back into the CA to ACTIVATE it.
resource "aws_acmpca_certificate_authority_certificate" "root" {
  count = var.ca_mode == "aws" ? 1 : 0

  certificate_authority_arn = aws_acmpca_certificate_authority.this[0].arn
  certificate               = aws_acmpca_certificate.root[0].certificate
  # A root CA has no chain above it, so certificate_chain is intentionally omitted.
}

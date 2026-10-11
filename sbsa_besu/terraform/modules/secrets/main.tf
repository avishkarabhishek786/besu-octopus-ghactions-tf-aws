# =============================================================================
# modules/secrets/main.tf
# -----------------------------------------------------------------------------
# PURPOSE
#   The single owner of AWS Secrets Manager content for this deployment, plus
#   the in-cluster Secrets Store CSI AWS provider that lets pods MOUNT those
#   secrets as files (authorised by the IRSA role from modules/iam).
#
# SECRET NAMING — THE IRSA SCOPING TRICK (important)
#   The IRSA policy (modules/iam) grants Besu pods GetSecretValue on
#   `besu-node-*` ONLY. So everything a POD must read is named `besu-node-*`:
#       besu-node-validator-N        node (signing) key       [value in stage 3]
#       besu-node-bootnode-N         bootnode key             [value in stage 3]
#       besu-node-tls-keystore-password    RPC server keystore password
#       besu-node-tls-truststore-password  RPC truststore password
#       besu-node-rpc-jwt            RPC JWT signing secret (method-scoping, st4)
#       besu-node-ca-cert            CA certificate (PUBLIC; truststore content)
#   The CA PRIVATE key is named OUTSIDE that scope so pods CANNOT read it:
#       besu-ca-private-key          (ops / leaf-cert issuance only)
#   This gives least privilege WITHOUT changing the stage-1 IRSA policy.
#
# WHY NODE KEY VALUES ARE NOT GENERATED HERE
#   Besu node keys are secp256k1. The Terraform tls provider only does RSA and
#   NIST ECDSA curves (P-224/256/384/521) — NOT secp256k1 — so it cannot produce
#   a valid Besu key. We therefore create the secret CONTAINERS here and let the
#   stage-3 genesis tooling (which generates the keys AND the matching QBFT
#   extraData together, so the validator set is always consistent) write the
#   values. The exception is use_provided_validator_keys = true, where the
#   caller supplies real keys and we store them directly.
#
# ENCRYPTION (C12)
#   By default secrets use the AWS-managed key (aws/secretsmanager) — already
#   FIPS 140-3 L3 hardware at rest, but under a key we don't control/audit.
#   When node_key_cmk_arn is set (enable_node_key_cmk=true), the node-key secrets
#   and the CA private key are encrypted with a CUSTOMER-managed CMK instead —
#   controlled key policy + per-decrypt CloudTrail audit. The pod/genesis IRSA
#   roles are given the matching scoped kms grant in modules/iam. This is the
#   "at-rest custody" (Option B) of the FIPS analysis; it does not change signing.
# =============================================================================

locals {
  validator_secret_names = [for i in range(1, var.validator_count + 1) : "besu-node-validator-${i}"]
  bootnode_secret_names  = [for i in range(1, var.bootnode_count + 1) : "besu-node-bootnode-${i}"]
  rpc_secret_names       = [for i in range(1, var.rpc_node_count + 1) : "besu-node-rpc-${i}"]
  # Stage 8: app-rpc pool node-key containers (besu-node-app-rpc-1..J). app-rpc
  # nodes are full Besu RPC nodes inside the chain cluster, so they need their
  # own secp256k1 identities (for node-local permissioning), like rpc nodes.
  app_rpc_secret_names = [for i in range(1, var.app_rpc_node_count + 1) : "besu-node-app-rpc-${i}"]
  # Stage 9: explorer-rpc pool node-key containers (besu-node-explorer-rpc-1..E).
  # The Blockscout read-only RPC pool — full Besu RPC nodes inside the cluster,
  # so they need their own secp256k1 identities like rpc/app-rpc nodes.
  explorer_rpc_secret_names = [for i in range(1, var.explorer_rpc_node_count + 1) : "besu-node-explorer-rpc-${i}"]

  # C12: null → Secrets Manager uses the AWS-managed aws/secretsmanager key;
  # a CMK ARN → the secret is encrypted under our customer-managed CMK (FIPS-L3,
  # under a key policy we control + a per-decrypt CloudTrail trail).
  node_key_kms_key_id = var.node_key_cmk_arn != "" ? var.node_key_cmk_arn : null
}

# -----------------------------------------------------------------------------
# TERRAFORM-GENERATED SECRETS (passwords + RPC JWT)
# special = false keeps them file/shell/keystore-friendly while length gives
# ample entropy.
# -----------------------------------------------------------------------------
resource "random_password" "keystore" {
  length  = 32
  special = false
}

resource "random_password" "truststore" {
  length  = 32
  special = false
}

resource "random_password" "rpc_jwt" {
  length  = 64
  special = false
}

# -----------------------------------------------------------------------------
# CA MATERIAL (from modules/pki)
# -----------------------------------------------------------------------------
# CA certificate (PUBLIC) — pod-readable, hence the besu-node-* name.
resource "aws_secretsmanager_secret" "ca_cert" {
  name                    = "besu-node-ca-cert"
  description             = "PEM CA certificate (public) anchoring the JSON-RPC mTLS trust chain. Pod-readable truststore content."
  recovery_window_in_days = var.recovery_window_days
  tags                    = merge(var.tags, { Component = "secrets" })
}

resource "aws_secretsmanager_secret_version" "ca_cert" {
  secret_id     = aws_secretsmanager_secret.ca_cert.id
  secret_string = var.ca_cert_pem
}

# CA PRIVATE key — NOT pod-readable. Named outside besu-node-* so the IRSA
# policy does not cover it. Created only for the self-managed CA; for
# ca_mode='aws' the key lives in acm-pca and is never exported.
# NOTE: count is gated on ca_mode (a KNOWN input), NOT on ca_private_key_pem —
# that PEM is a tls_private_key attribute resolved only at apply time, and a
# count cannot depend on an apply-time value.
resource "aws_secretsmanager_secret" "ca_private_key" {
  count = var.ca_mode == "aws" ? 0 : 1

  name                    = "besu-ca-private-key"
  description             = "PEM CA PRIVATE key (self-managed CA). Sensitive; intentionally OUTSIDE the besu-node-* IRSA scope so Besu pods cannot read it. Used by leaf-cert issuance (stage 4)."
  recovery_window_in_days = var.recovery_window_days
  kms_key_id              = local.node_key_kms_key_id # C12: also under the CMK (read via operator/account-root)
  tags                    = merge(var.tags, { Component = "secrets" })
}

resource "aws_secretsmanager_secret_version" "ca_private_key" {
  count = var.ca_mode == "aws" ? 0 : 1

  secret_id     = aws_secretsmanager_secret.ca_private_key[0].id
  secret_string = var.ca_private_key_pem
}

# -----------------------------------------------------------------------------
# KEYSTORE / TRUSTSTORE PASSWORDS + RPC JWT (pod-readable)
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "keystore_password" {
  name                    = "besu-node-tls-keystore-password"
  description             = "Password protecting the RPC server PKCS12 keystore (built in stage 4)."
  recovery_window_in_days = var.recovery_window_days
  tags                    = merge(var.tags, { Component = "secrets" })
}

resource "aws_secretsmanager_secret_version" "keystore_password" {
  secret_id     = aws_secretsmanager_secret.keystore_password.id
  secret_string = random_password.keystore.result
}

resource "aws_secretsmanager_secret" "truststore_password" {
  name                    = "besu-node-tls-truststore-password"
  description             = "Password protecting the RPC mTLS truststore (built in stage 4)."
  recovery_window_in_days = var.recovery_window_days
  tags                    = merge(var.tags, { Component = "secrets" })
}

resource "aws_secretsmanager_secret_version" "truststore_password" {
  secret_id     = aws_secretsmanager_secret.truststore_password.id
  secret_string = random_password.truststore.result
}

resource "aws_secretsmanager_secret" "rpc_jwt" {
  name                    = "besu-node-rpc-jwt"
  description             = "RPC JWT signing secret for per-user method scoping (rpc_auth_mode = tls-plus-method; consumed in stage 4)."
  recovery_window_in_days = var.recovery_window_days
  tags                    = merge(var.tags, { Component = "secrets" })
}

resource "aws_secretsmanager_secret_version" "rpc_jwt" {
  secret_id     = aws_secretsmanager_secret.rpc_jwt.id
  secret_string = random_password.rpc_jwt.result
}

# -----------------------------------------------------------------------------
# NODE KEY CONTAINERS (validators + bootnodes)
# -----------------------------------------------------------------------------
# Containers only. Values are written either from provided keys (below) or by
# the stage-3 genesis tooling. ignore_changes on the future version is not
# needed because we do NOT create a Terraform-managed version for generated
# keys — the tooling owns those versions, so there is no drift to suppress.
resource "aws_secretsmanager_secret" "validator" {
  for_each = toset(local.validator_secret_names)

  name                    = each.value
  description             = "Besu validator node (secp256k1) key. Value written by stage-3 genesis tooling unless use_provided_validator_keys=true."
  recovery_window_in_days = var.recovery_window_days
  kms_key_id              = local.node_key_kms_key_id # C12
  tags                    = merge(var.tags, { Component = "secrets" })
}

# Validator VALUES only when the caller provided real keys. Indexes the provided
# list in name order (validator-1 -> validator_private_keys[0], ...).
resource "aws_secretsmanager_secret_version" "validator" {
  for_each = var.use_provided_validator_keys ? {
    for idx, name in local.validator_secret_names : name => var.validator_private_keys[idx]
  } : {}

  secret_id     = aws_secretsmanager_secret.validator[each.key].id
  secret_string = each.value
}

resource "aws_secretsmanager_secret" "bootnode" {
  for_each = toset(local.bootnode_secret_names)

  name                    = each.value
  description             = "Besu bootnode node (secp256k1) key. Value written by stage-3 genesis tooling."
  recovery_window_in_days = var.recovery_window_days
  kms_key_id              = local.node_key_kms_key_id # C12
  tags                    = merge(var.tags, { Component = "secrets" })
}

resource "aws_secretsmanager_secret" "rpc" {
  for_each = toset(local.rpc_secret_names)

  name                    = each.value
  description             = "Besu RPC node (secp256k1) key. Value written by stage-3 genesis tooling. RPC nodes need an identity for node-local permissioning."
  recovery_window_in_days = var.recovery_window_days
  kms_key_id              = local.node_key_kms_key_id # C12
  tags                    = merge(var.tags, { Component = "secrets" })
}

# Stage 8: app-rpc pool node-key containers (value written by genesis tooling).
resource "aws_secretsmanager_secret" "app_rpc" {
  for_each = toset(local.app_rpc_secret_names)

  name                    = each.value
  description             = "Besu app-rpc node (secp256k1) key. Value written by stage-3 genesis tooling. app-rpc nodes are RPC nodes inside the chain cluster and need a node identity for node-local permissioning."
  recovery_window_in_days = var.recovery_window_days
  kms_key_id              = local.node_key_kms_key_id # C12
  tags                    = merge(var.tags, { Component = "secrets" })
}

# Stage 9: explorer-rpc pool node-key containers (value written by genesis tooling).
resource "aws_secretsmanager_secret" "explorer_rpc" {
  for_each = toset(local.explorer_rpc_secret_names)

  name                    = each.value
  description             = "Besu explorer-rpc node (secp256k1) key. Value written by stage-3 genesis tooling. explorer-rpc nodes are the Blockscout read-only RPC pool inside the chain cluster and need a node identity for node-local permissioning."
  recovery_window_in_days = var.recovery_window_days
  kms_key_id              = local.node_key_kms_key_id # C12
  tags                    = merge(var.tags, { Component = "secrets" })
}

# -----------------------------------------------------------------------------
# RPC mTLS MATERIAL (stage 4) — containers only; values written by
# scripts/pki/issue-server-cert.sh (run from the runner/ops), which signs a
# server cert with the CA and builds the PKCS12 keystore + truststore + JWT key.
# -----------------------------------------------------------------------------
# Pod-readable (besu-node-* => covered by the read-only IRSA pod role): the RPC
# server keystore, the client truststore, and the JWT verification public key.
resource "aws_secretsmanager_secret" "rpc_keystore" {
  name                    = "besu-node-rpc-keystore"
  description             = "Base64 PKCS12 keystore (RPC server cert+key, CA-signed) for Besu --rpc-http-tls-keystore-file. Written by issue-server-cert.sh."
  recovery_window_in_days = var.recovery_window_days
  tags                    = merge(var.tags, { Component = "secrets" })
}

resource "aws_secretsmanager_secret" "rpc_truststore" {
  name                    = "besu-node-rpc-truststore"
  description             = "Base64 PKCS12 truststore (the CA cert) for Besu --rpc-http-tls-truststore-file — verifies SWIFT client certs (mTLS)."
  recovery_window_in_days = var.recovery_window_days
  tags                    = merge(var.tags, { Component = "secrets" })
}

resource "aws_secretsmanager_secret" "rpc_jwt_pubkey" {
  name                    = "besu-node-rpc-jwt-pubkey"
  description             = "RSA PUBLIC key (PEM) for Besu --rpc-http-authentication-jwt-public-key-file. Besu verifies SWIFT JWTs (method scoping) with this."
  recovery_window_in_days = var.recovery_window_days
  tags                    = merge(var.tags, { Component = "secrets" })
}

# Ops-only (OUTSIDE besu-node-* => pods cannot read it): the JWT signing private
# key, used by scripts/access/make-join-pack.sh to mint method-scoped SWIFT JWTs.
resource "aws_secretsmanager_secret" "rpc_jwt_signing_key" {
  name                    = "besu-rpc-jwt-signing-key"
  description             = "RSA PRIVATE key (PEM) that signs SWIFT JWTs. Ops-only; intentionally outside the besu-node-* IRSA scope so Besu pods cannot read it."
  recovery_window_in_days = var.recovery_window_days
  tags                    = merge(var.tags, { Component = "secrets" })
}

# -----------------------------------------------------------------------------
# STAGE 8 — APP-RPC TLS + JWT MATERIAL (containers; values written at deploy)
# -----------------------------------------------------------------------------
# app-rpc serves server-TLS (no client-auth) + JWT. Pod-readable (besu-node-*):
# the server keystore + its password + the JWT verification PUBLIC key. The JWT
# SIGNING key is the APP's (used by the Next.js backend to mint tokens) and is
# named OUTSIDE besu-node-* so Besu pods cannot read it (the app EC2 role reads
# it; the deploy surfaces it into app/web/.env). No truststore — server-TLS only.
resource "random_password" "apprpc_keystore" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "apprpc_keystore_password" {
  name                    = "besu-node-apprpc-keystore-password"
  description             = "Password protecting the app-rpc server PKCS12 keystore (built by issue-server-cert.sh for the app-rpc pool)."
  recovery_window_in_days = var.recovery_window_days
  tags                    = merge(var.tags, { Component = "secrets" })
}

resource "aws_secretsmanager_secret_version" "apprpc_keystore_password" {
  secret_id     = aws_secretsmanager_secret.apprpc_keystore_password.id
  secret_string = random_password.apprpc_keystore.result
}

resource "aws_secretsmanager_secret" "apprpc_keystore" {
  name                    = "besu-node-apprpc-keystore"
  description             = "Base64 PKCS12 keystore (app-rpc server cert+key, CA-signed) for Besu --rpc-http-tls-keystore-file / --rpc-ws-ssl-keystore-file. Server-TLS only (no client auth). Written by issue-server-cert.sh."
  recovery_window_in_days = var.recovery_window_days
  tags                    = merge(var.tags, { Component = "secrets" })
}

resource "aws_secretsmanager_secret" "apprpc_jwt_pubkey" {
  name                    = "besu-node-apprpc-jwt-pubkey"
  description             = "RSA PUBLIC key (PEM) for Besu --rpc-http/ws-authentication-jwt-public-key-file on the app-rpc pool. Besu verifies the app's JWTs with this. Pod-readable."
  recovery_window_in_days = var.recovery_window_days
  tags                    = merge(var.tags, { Component = "secrets" })
}

resource "aws_secretsmanager_secret" "apprpc_jwt_signing_key" {
  name                    = "besu-apprpc-jwt-signing-key"
  description             = "RSA PRIVATE key (PEM) the APP uses to mint app-rpc JWTs. Outside the besu-node-* IRSA scope so Besu pods cannot read it; the app EC2 role reads it and the deploy writes it to app/web/.env. Throwaway/non-prod."
  recovery_window_in_days = var.recovery_window_days
  tags                    = merge(var.tags, { Component = "secrets" })
}

# -----------------------------------------------------------------------------
# SECRETS STORE CSI — AWS PROVIDER  (IN-CLUSTER, gated)
# -----------------------------------------------------------------------------
# The generic Secrets Store CSI driver is installed in stage 1 (storage-csi).
# This adds the AWS PROVIDER DaemonSet (ASCP) that teaches the driver to read
# AWS Secrets Manager. Together with a SecretProviderClass (see
# helm/secrets/secretproviderclass.example.yaml) and the IRSA-annotated service
# account (created by the Besu chart in stage 3), a pod gets its node key
# delivered as a file at runtime.
#
# v3 of this chart bundles the generic driver; we set
# secrets-store-csi-driver.install=false so it does NOT collide with the
# stage-1 driver release. Gated by deploy_in_cluster_resources (needs the
# private EKS endpoint). depends_on the driver is enforced at the root module
# level (module.secrets depends_on module.storage_csi).
locals {
  # PORTING item 4: Helm value path -> chart_images key. Rendered as one string
  # `set` per attribute, and only for keys present, so an absent key keeps the
  # chart's own default rather than nulling it.
  ascp_image_sets_paths = {
    "image" = "csi-provider-aws"
  }
  ascp_image_sets = merge([for path, key in local.ascp_image_sets_paths :
    { for attr, val in { repository = "${var.chart_images[key].registry}/${var.chart_images[key].repository}", tag = var.chart_images[key].tag } : "${path}.${attr}" => val }
    if contains(keys(var.chart_images), key)
  ]...)
}

resource "helm_release" "secrets_store_csi_provider_aws" {
  count = var.deploy_in_cluster_resources ? 1 : 0

  name             = "secrets-provider-aws"
  repository       = var.chart_repository != "" ? var.chart_repository : "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart            = "secrets-store-csi-driver-provider-aws"
  version          = var.aws_provider_chart_version
  namespace        = "kube-system"
  create_namespace = false

  dynamic "set" {
    for_each = local.ascp_image_sets
    content {
      name  = set.key
      value = set.value
      type  = "string"
    }
  }

  # Do NOT let this chart install the generic driver — stage 1 owns it.
  set {
    name  = "secrets-store-csi-driver.install"
    value = "false"
  }
}

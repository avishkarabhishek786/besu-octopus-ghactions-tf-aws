# =============================================================================
# modules/iam/main.tf
# -----------------------------------------------------------------------------
# PURPOSE
#   Creates the IRSA (IAM Roles for Service Accounts) role that the Besu node
#   pods assume to read their keys from AWS Secrets Manager — the cloud-native
#   secrets pattern the quorum-kubernetes AWS guidance uses (cloudNativeServices
#   = true). Instead of storing node private keys as Kubernetes Secrets, keys
#   live in Secrets Manager and pods fetch them at runtime via the Secrets Store
#   CSI driver, authorised by THIS role.
#
# WHY IRSA (and not node instance-profile permissions)
#   If we granted Secrets Manager access to the EC2 node instance profile, EVERY
#   pod on that node — including any future app workload — could read the
#   validator keys. IRSA scopes the permission to ONE Kubernetes service account
#   in ONE namespace, so only pods that explicitly use the
#   "quorum-node-secrets-sa" service account can assume the role. This is the
#   least-privilege boundary that protects the most sensitive asset (keys).
#
# HOW IRSA WORKS (mechanics)
#   1. The EKS cluster has an OIDC identity provider (created in the eks module).
#   2. A pod using a service account annotated with this role's ARN receives a
#      projected OIDC token.
#   3. The AWS SDK in the pod exchanges that token (via sts:AssumeRoleWithWeb-
#      Identity) for temporary credentials of THIS role.
#   4. The trust policy below permits that exchange ONLY when the token's
#      "sub" claim equals system:serviceaccount:<namespace>:<sa-name>, locking
#      the role to exactly that service account.
# =============================================================================

# -----------------------------------------------------------------------------
# Trust policy: who may assume this role.
# The two conditions are the security crux:
#   :sub  must equal the specific service account (namespace + name)
#   :aud  must be sts.amazonaws.com (the audience EKS projects)
# Both are matched against the cluster's OWN OIDC provider, so a token from any
# other cluster cannot assume this role.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "secrets_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.secrets_service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "besu_secrets" {
  name                 = "${var.name_prefix}-besu-secrets-irsa"
  assume_role_policy   = data.aws_iam_policy_document.secrets_assume.json
  permissions_boundary = var.permissions_boundary # H5: cap — no IAM/org/account mutation

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-besu-secrets-irsa"
    Component = "iam"
  })
}

# -----------------------------------------------------------------------------
# Permission policy: WHAT the role may do.
# Scoped to secrets matching var.secrets_arn_prefix (e.g. besu-node-*), so even
# if a pod assumed the role it could only touch Besu node secrets, nothing else
# in the account. Actions mirror what the quorum-kubernetes policy grants for
# managing/reading node secrets, restricted to read+write of the namespaced
# secrets only.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "secrets_access" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [var.secrets_arn_prefix]
  }

  # C12: when the node-key secrets are CMK-encrypted, the CSI driver's
  # GetSecretValue transparently calls kms:Decrypt under the pod's IRSA identity.
  # Scoped to the single node-key CMK — read-only (Decrypt), no key management.
  dynamic "statement" {
    for_each = var.node_key_cmk_arn != "" ? [var.node_key_cmk_arn] : []
    content {
      sid       = "DecryptNodeKeyCMK"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:DescribeKey"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_policy" "besu_secrets" {
  name   = "${var.name_prefix}-besu-secrets-policy"
  policy = data.aws_iam_policy_document.secrets_access.json

  tags = merge(var.tags, { Component = "iam" })
}

resource "aws_iam_role_policy_attachment" "besu_secrets" {
  role       = aws_iam_role.besu_secrets.name
  policy_arn = aws_iam_policy.besu_secrets.arn
}

# =============================================================================
# GENESIS WRITER ROLE (stage 3)
# -----------------------------------------------------------------------------
# The stage-3 genesis Job generates the secp256k1 validator/bootnode keys (via
# `besu operator generate-blockchain-config`) and must WRITE them into the
# Secrets Manager containers created in stage 2. The pod role above is
# deliberately read-only, so the Job gets a SEPARATE, write-capable role scoped
# to the SAME besu-node-* prefix — and trusted only by the genesis service
# account, so ordinary Besu pods can never assume it.
# =============================================================================
data "aws_iam_policy_document" "genesis_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.genesis_service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "besu_genesis" {
  name                 = "${var.name_prefix}-besu-genesis-irsa"
  assume_role_policy   = data.aws_iam_policy_document.genesis_assume.json
  permissions_boundary = var.permissions_boundary # H5: cap — no IAM/org/account mutation

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-besu-genesis-irsa"
    Component = "iam"
  })
}

# Write (and read) the node-key secrets. PutSecretValue stores the generated
# keys; Get/Describe let the Job skip nodes whose key already exists (idempotent
# re-runs). Scoped to the same besu-node-* prefix as the pod role.
data "aws_iam_policy_document" "genesis_access" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:PutSecretValue",
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [var.secrets_arn_prefix]
  }

  # C12: the genesis Job WRITES CMK-encrypted node-key secrets — PutSecretValue
  # against a CMK-encrypted secret needs kms:GenerateDataKey; the idempotent
  # skip-existing GetSecretValue needs kms:Decrypt. Scoped to the node-key CMK.
  dynamic "statement" {
    for_each = var.node_key_cmk_arn != "" ? [var.node_key_cmk_arn] : []
    content {
      sid       = "EncryptDecryptNodeKeyCMK"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_policy" "besu_genesis" {
  name   = "${var.name_prefix}-besu-genesis-policy"
  policy = data.aws_iam_policy_document.genesis_access.json
  tags   = merge(var.tags, { Component = "iam" })
}

resource "aws_iam_role_policy_attachment" "besu_genesis" {
  role       = aws_iam_role.besu_genesis.name
  policy_arn = aws_iam_policy.besu_genesis.arn
}

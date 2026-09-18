# =============================================================================
# kms.tf (ROOT) — customer-managed CMK for Besu validator/node key custody (C12)
# -----------------------------------------------------------------------------
# WHAT: a customer-managed KMS key (CMK) that encrypts the validator / bootnode /
#   node-identity key secrets (and the self-managed CA private key) at rest, in
#   place of the AWS-managed `aws/secretsmanager` key. AWS KMS is FIPS 140-3
#   Level 3 validated hardware (CMVP #4884), so this delivers the "at-rest custody
#   under FIPS-L3 hardware, under a key WE control + audit" reading of the
#   requirement (auditor doc §9 / Option B). It does NOT change how Besu signs
#   (the node key is still read into pod memory to sign — the strict "sign inside
#   hardware" reading is CloudHSM-only, Option A, out of scope here).
#
# WHY THIS FILE / ORDER (avoids a Terraform dependency cycle):
#   aws_kms_key.node_keys        — created with the DEFAULT key policy (account
#                                  root full access); no reference to the IAM
#                                  roles, so it has no dependency on module.iam.
#   module.iam                   — receives this key's ARN and adds a SCOPED
#                                  kms:Decrypt (pods) / kms:Decrypt+GenerateDataKey
#                                  (genesis) statement → depends on the key.
#   aws_kms_key_policy.node_keys — the REAL key policy, naming the two IRSA roles
#                                  explicitly → depends on module.iam's outputs.
#   The chain key → iam → key_policy is linear (no cycle). Because aws_kms_key
#   sets no `policy` argument, the separate key_policy resource owns the policy
#   with no perpetual drift.
#
# GATE: everything here is created only when enable_node_key_cmk = true. When
#   false, node-key secrets keep using aws/secretsmanager and IAM adds no kms
#   statement (local.node_key_cmk_arn = "").
# =============================================================================

data "aws_partition" "current" {
  provider = aws.primary
}

locals {
  node_key_cmk_enabled = var.enable_node_key_cmk
  node_key_cmk_arn     = local.node_key_cmk_enabled ? aws_kms_key.node_keys[0].arn : ""
  account_root_arn     = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
}

# The CMK. No `policy` argument → AWS applies the default key policy (account root
# full access), which is enough to bootstrap and prevents lockout; the real policy
# is set by aws_kms_key_policy.node_keys below (after the IAM roles exist).
resource "aws_kms_key" "node_keys" {
  count    = local.node_key_cmk_enabled ? 1 : 0
  provider = aws.primary

  description             = "${local.name_prefix} — Besu validator/bootnode/node-identity key custody (C12, FIPS 140-3 L3 at-rest, CMVP #4884)."
  enable_key_rotation     = true # annual automatic rotation of the backing material (defined key-rotation control)
  rotation_period_in_days = 365
  deletion_window_in_days = var.kms_deletion_window_days

  tags = { Component = "kms", Purpose = "besu-node-key-custody" }
}

resource "aws_kms_alias" "node_keys" {
  count    = local.node_key_cmk_enabled ? 1 : 0
  provider = aws.primary

  # Prefixed with name_prefix so parallel deploy-tests in one account/region don't
  # collide on the alias (alias names are unique per account/region).
  name          = "alias/${local.name_prefix}-besu-node-keys"
  target_key_id = aws_kms_key.node_keys[0].key_id
}

# The REAL key policy: root admin (never lock out + lets IAM delegate) + an
# EXPLICIT, least-privilege grant to exactly the pod (read) and genesis
# (read+write) IRSA roles. Auditors read this to see precisely who may decrypt.
data "aws_iam_policy_document" "node_keys_cmk" {
  count = local.node_key_cmk_enabled ? 1 : 0

  statement {
    sid       = "RootAdmin"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.account_root_arn]
    }
  }

  # Besu pods (read-only): decrypt the node key the CSI driver mounts.
  statement {
    sid       = "BesuPodDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [module.iam.besu_secrets_role_arn]
    }
  }

  # Genesis Job (write): GenerateDataKey to PutSecretValue the generated keys,
  # Decrypt to read for the idempotent skip-existing check.
  statement {
    sid       = "BesuGenesisEncryptDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [module.iam.besu_genesis_role_arn]
    }
  }
}

resource "aws_kms_key_policy" "node_keys" {
  count    = local.node_key_cmk_enabled ? 1 : 0
  provider = aws.primary

  key_id = aws_kms_key.node_keys[0].id
  policy = data.aws_iam_policy_document.node_keys_cmk[0].json
}

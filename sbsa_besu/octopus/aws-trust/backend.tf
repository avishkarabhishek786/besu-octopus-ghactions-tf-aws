# =============================================================================
# backend.tf — ONE state per account, not per environment: the OIDC provider is
# account-wide, and the per-environment roles live beside it.
#
#   terraform init -backend-config="bucket=<state-bucket>" \
#     -backend-config="key=besu/octopus/aws-trust.tfstate" \
#     -backend-config="region=<state-region>" -backend-config="use_lockfile=true"
# =============================================================================

terraform {
  backend "s3" {}
}

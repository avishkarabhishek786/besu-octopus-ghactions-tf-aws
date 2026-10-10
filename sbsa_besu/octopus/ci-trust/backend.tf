# =============================================================================
# backend.tf — one state per Octopus instance + space.
#
#   terraform init -backend-config="bucket=<state-bucket>" \
#     -backend-config="key=besu/octopus/ci-trust.tfstate" \
#     -backend-config="region=<state-region>" -backend-config="use_lockfile=true"
# =============================================================================

terraform {
  backend "s3" {}
}

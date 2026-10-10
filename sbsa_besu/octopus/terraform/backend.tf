# =============================================================================
# backend.tf — one state per Octopus SPACE (environments live inside it).
#
#   terraform init -backend-config="bucket=<state-bucket>" \
#     -backend-config="key=besu/octopus/space.tfstate" \
#     -backend-config="region=<state-region>" -backend-config="use_lockfile=true"
# =============================================================================

terraform {
  backend "s3" {}
}

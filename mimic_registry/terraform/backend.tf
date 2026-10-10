# =============================================================================
# backend.tf
# -----------------------------------------------------------------------------
# Its own key, which nothing else touches: `besu/<env>/registry.tfstate`. The
# platform never reads it — in production this grant is the cloud team's and
# arrives as two values (a role ARN and a registry host), not as state.
#
#   terraform init \
#     -backend-config="bucket=<state-bucket>" \
#     -backend-config="key=besu/<env>/registry.tfstate" \
#     -backend-config="region=<state-region>" \
#     -backend-config="use_lockfile=true"
# =============================================================================

terraform {
  backend "s3" {}
}

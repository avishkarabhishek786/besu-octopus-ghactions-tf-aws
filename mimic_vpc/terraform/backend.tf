# =============================================================================
# backend.tf
# -----------------------------------------------------------------------------
# State lives under its own key prefix, `besu/network/`, which NOTHING else
# touches. The platform project (`sbsa_besu`) uses `besu/platform/*` and must
# never be granted read access to this prefix — the real cloud team will not
# share state, so allowing it here would let the platform develop a dependency
# that cannot exist in production (CLAUDE.md §4).
#
# Supply the bucket/region at init time so no environment detail is committed:
#
#   terraform init \
#     -backend-config="bucket=<state-bucket>" \
#     -backend-config="key=besu/<env>/network.tfstate" \   # <env> = sit | uat | prod
#     -backend-config="region=<state-region>"
# =============================================================================

terraform {
  backend "s3" {}
}

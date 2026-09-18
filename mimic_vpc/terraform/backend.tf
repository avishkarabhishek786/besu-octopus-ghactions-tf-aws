# =============================================================================
# backend.tf
# -----------------------------------------------------------------------------
# State lives in its own key, `besu/<env>/network.tfstate`, which NOTHING else
# touches. The platform project (`sbsa_besu`) uses
# `besu/<env>/{shared,runner,chain,app}.tfstate` and must never be granted read
# access to this key — the real cloud team will not
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

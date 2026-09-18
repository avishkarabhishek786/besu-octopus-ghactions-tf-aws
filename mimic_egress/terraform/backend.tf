# =============================================================================
# backend.tf
# -----------------------------------------------------------------------------
# State lives under the cloud-team prefix `besu/network/`, in its own key, which
# NOTHING else touches. `mimic_vpc` uses `besu/<env>/network.tfstate`; this
# project uses `besu/<env>/egress.tfstate`. The platform (`sbsa_besu`) must never
# read either — the real cloud team will not share state, so allowing it here
# would let the platform build a dependency that cannot exist in production
# (CLAUDE.md §0 #5).
#
# Supply the bucket/region at init time so no environment detail is committed:
#
#   terraform init \
#     -backend-config="bucket=<state-bucket>" \
#     -backend-config="key=besu/<env>/egress.tfstate" \   # <env> = sit | uat | prod
#     -backend-config="region=<state-region>" \
#     -backend-config="use_lockfile=true"
# =============================================================================

terraform {
  backend "s3" {}
}

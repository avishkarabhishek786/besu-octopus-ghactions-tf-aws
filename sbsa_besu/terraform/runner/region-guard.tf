# =============================================================================
# terraform/runner/region-guard.tf — the runner must live in the CHAIN's region
# -----------------------------------------------------------------------------
# `region` is the deploy region (= the chain's primary_region), NOT the
# state-bucket region (chain_state_region). The variable has no default and its
# description says it MUST match, but nothing enforced that. A mismatch would launch
# the runner against a VPC/subnet that does not exist in that region and scope
# the H5 deploy policy's region-bound ARNs to the wrong region. Fail at PLAN with
# a clear message instead. (Ported from besu-aws fix/golive-region-apprpc-allowlist.)
# =============================================================================
resource "terraform_data" "region_guard" {
  lifecycle {
    precondition {
      condition     = try(local.chain.primary_region, var.region) == var.region
      error_message = "Runner `region` (${var.region}) does not match the chain's primary_region (${try(local.chain.primary_region, "?")}). Pass the chain's DEPLOY region, not the state-bucket region (that one goes in chain_state_region)."
    }
  }
}

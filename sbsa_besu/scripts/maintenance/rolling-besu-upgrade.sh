#!/usr/bin/env bash
# =============================================================================
# scripts/maintenance/rolling-besu-upgrade.sh
# -----------------------------------------------------------------------------
# BACK-COMPAT WRAPPER (H1). The rolling logic now lives in the generalized
# rolling-besu-apply.sh (accepts arbitrary Helm --set overrides and is
# OnDelete-aware). This wrapper preserves the original image-bump interface:
#
#   NEW_BESU_IMAGE=hyperledger/besu:26.7.0 \
#     scripts/maintenance/rolling-besu-upgrade.sh
#   # optional passthrough: NAMESPACE, CHART_DIR, SETTLE_SECONDS,
#   #   CATCHUP_TOLERANCE, INCLUDE_NON_VALIDATORS=true
#
# It rolls the new Besu image across the QBFT validators ONE AT A TIME, verifying
# quorum + catch-up between each step (never more than one validator down). See
# rolling-besu-apply.sh for the mechanics (OnDelete pod delete + quorum gates).
#
# AFTER a successful run: validator releases are frozen in Terraform
# (ignore_changes=[values]), so the next `terraform apply` will NOT revert the
# image. Still record the new version in the env tfvars (besu_version) so the
# genesis/non-validator paths agree.
# NOTE (25.x -> 26.x): add --Xbft-legacy-protocol-encoding for wire-compat during
#       the mixed-version window (CLAUDE.md §6) — pass it via SET_ARGS on the
#       apply script (see H11) once wired into the chart.
# =============================================================================
set -euo pipefail

: "${NEW_BESU_IMAGE:?set NEW_BESU_IMAGE=hyperledger/besu:<version> (PINNED tag, never 'latest')}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SET_ARGS="besuImage=${NEW_BESU_IMAGE}"
exec "${SCRIPT_DIR}/rolling-besu-apply.sh" "$@"

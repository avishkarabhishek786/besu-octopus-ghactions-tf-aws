#!/usr/bin/env bash
# =============================================================================
# scripts/maintenance/rolling-besu-rollback.sh   (H11)
# -----------------------------------------------------------------------------
# Roll the QBFT validators BACK to a PRIOR Besu image, ONE AT A TIME, with the
# same quorum + catch-up gate as the forward roll. Use this when a forward
# rolling upgrade (rolling-besu-apply.sh / rolling-besu-upgrade.sh) went bad and
# left a mixed-version validator set, or a new image misbehaves — a Besu image
# roll is reversible (unlike an EKS control-plane version bump, which CANNOT be
# downgraded; see the guide §10 rollback runbook).
#
# It is a thin, clearly-named wrapper over rolling-besu-apply.sh (same OnDelete
# mechanics + quorum gate), pinned to the PREVIOUS image.
#
# Usage (from the in-VPC runner, repo root):
#   PREV_BESU_IMAGE=hyperledger/besu:26.6.1 \
#     scripts/maintenance/rolling-besu-rollback.sh
#   # crossing 25<->26 during the rollback? add:
#   LEGACY_PROTOCOL_ENCODING=true PREV_BESU_IMAGE=hyperledger/besu:25.x \
#     scripts/maintenance/rolling-besu-rollback.sh
#   # optional passthrough: NAMESPACE, CHART_DIR, SETTLE_SECONDS,
#   #   CATCHUP_TOLERANCE, INCLUDE_NON_VALIDATORS=true
#
# AFTER a rollback: record the reverted image in the env tfvars (besu_version) so
# the forward version is not accidentally re-applied. Validators are frozen in
# Terraform (ignore_changes=[values]), so a plain apply will not re-push the image.
# =============================================================================
set -euo pipefail

: "${PREV_BESU_IMAGE:?set PREV_BESU_IMAGE=hyperledger/besu:<prior-version> (the PINNED image to roll back to)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] INFO  ROLLBACK: rolling validators back to ${PREV_BESU_IMAGE} (one at a time, quorum-gated)"
export SET_ARGS="besuImage=${PREV_BESU_IMAGE}"
exec "${SCRIPT_DIR}/rolling-besu-apply.sh" "$@"

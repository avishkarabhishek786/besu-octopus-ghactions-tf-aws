#!/usr/bin/env bash
# =============================================================================
# octopus/steps/validators-rolling.sh   — besu-validators, after the manual gate
# -----------------------------------------------------------------------------
# The ONLY deploy mechanism for validators (CD-5, H1): this wrapper hands over to
# scripts/maintenance/rolling-besu-apply.sh, which changes ONE validator at a
# time and gates on the chain still producing. It never runs a Helm step itself.
#
# When no validator releases exist in the namespace (the first Octopus run,
# CD-67 — the chain's in-cluster layer is not deployed yet), it says so and
# stops: the manual-intervention gate and the runner worker path are what that
# run proves. It does NOT treat "nothing to roll" as a pass of the rolling
# procedure itself.
#
# Environment:  BESU_CLUSTER  AWS_REGION  BESU_LEDGER_NAMESPACE
#               SET_ARGS      the Helm overrides to roll (rolling-besu-apply.sh)
# =============================================================================
set -euo pipefail

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${BESU_CLUSTER:?}" "${AWS_REGION:?}" "${BESU_LEDGER_NAMESPACE:?}"
export KUBECONFIG="${KUBECONFIG:-$(mktemp)}"
[[ -d /usr/local/besu-tools/bin ]] && export PATH="/usr/local/besu-tools/bin:$PATH"

aws eks update-kubeconfig --region "$AWS_REGION" --name "$BESU_CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null

n="$(helm list -n "$BESU_LEDGER_NAMESPACE" -q 2>/dev/null | grep -c '^validator-' || true)"
if [[ "$n" -eq 0 ]]; then
  echo "No validator releases in $BESU_LEDGER_NAMESPACE — nothing to roll."
  echo "Proven by this deployment: the manual-intervention gate and the runner worker path."
  echo "NOT proven: the rolling procedure itself (it needs validators)."
  exit 0
fi

: "${SET_ARGS:?SET_ARGS is required when validators exist — the overrides to roll, one validator at a time}"
cd "$PKG"
NAMESPACE="$BESU_LEDGER_NAMESPACE" SET_ARGS="$SET_ARGS" bash scripts/maintenance/rolling-besu-apply.sh

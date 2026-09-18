#!/usr/bin/env bash
# =============================================================================
# scripts/maintenance/rolling-besu-apply.sh
# -----------------------------------------------------------------------------
# Apply an ARBITRARY set of Helm value overrides across the QBFT validators ONE
# AT A TIME, verifying the chain stays at quorum and the changed node catches
# back up between each step. NEVER touches more than one validator at once. This
# is the single supported path for ANY validator-affecting change (image bump,
# resource resize, arg change, ...) — see H1 in docs/production-hardening-backlog.md.
#
# WHY ONE AT A TIME (do not skip): QBFT needs N=3F+1 validators with a quorum of
# 2F+1 online to produce blocks. With 4 validators, quorum = 3 — so exactly ONE
# validator may be down at a time. Restarting 2+ together drops below quorum and
# HALTS the chain. A blanket `terraform apply` CANNOT do this anymore (validators
# are a frozen helm_release with ignore_changes=[values], and the chart pins them
# to updateStrategy=OnDelete), so this script is the ONLY way to roll them.
#
# ONDELETE MECHANICS (H1): validators use updateStrategy=OnDelete, so a
# `helm upgrade` updates the StatefulSet TEMPLATE but does NOT restart the pod.
# This script therefore, per validator: (1) helm upgrade the single release with
# the overrides, (2) DELETE the pod so it is recreated on the new template, then
# (3) wait Ready and GATE on the chain still advancing on the OTHER validators and
# the changed validator catching up to head. Aborts hard if either gate fails.
#
# RUN FROM the in-VPC runner (private EKS endpoint), at the repo root, after
#   `aws eks update-kubeconfig --name <cluster> --region <region>`.
#
# Usage:
#   # bump the Besu image (equivalent to rolling-besu-upgrade.sh):
#   SET_ARGS="besuImage=hyperledger/besu:26.7.0" \
#     scripts/maintenance/rolling-besu-apply.sh
#   # multiple overrides (space-separated key=value, Helm --set dotted paths):
#   SET_ARGS="besuImage=hyperledger/besu:26.7.0 resources.limits.memory=6Gi" \
#     scripts/maintenance/rolling-besu-apply.sh
#   # optional: NAMESPACE, CHART_DIR, SETTLE_SECONDS, CATCHUP_TOLERANCE,
#   #           INCLUDE_NON_VALIDATORS=true, POD_READY_TIMEOUT
#
# AFTER a successful image roll: the validator releases are frozen in Terraform
# (ignore_changes=[values]), so Terraform will NOT revert the image on the next
# apply. Still bump `besu_version` in the env tfvars for documentation + so the
# genesis/non-validator paths agree.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

: "${SET_ARGS:?set SET_ARGS=\"key=value [key=value ...]\" (Helm --set overrides, e.g. besuImage=hyperledger/besu:26.7.0)}"
NAMESPACE="${NAMESPACE:-besu}"
CHART_DIR="${CHART_DIR:-helm/charts/besu-node}"
SETTLE_SECONDS="${SETTLE_SECONDS:-15}"        # ~2-3 block periods to confirm the chain advanced
CATCHUP_TOLERANCE="${CATCHUP_TOLERANCE:-5}"   # how many blocks behind head the changed node may be
INCLUDE_NON_VALIDATORS="${INCLUDE_NON_VALIDATORS:-false}"
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-300s}"

need kubectl
need helm
[ -d "$CHART_DIR" ] || die "chart dir not found: $CHART_DIR (run from the repo root on the runner)"

# Build the helm --set argument array from SET_ARGS (space-separated key=value).
SET_FLAGS=()
for kv in $SET_ARGS; do
  case "$kv" in
    *=*) SET_FLAGS+=(--set "$kv") ;;
    *)   die "SET_ARGS entry '$kv' is not key=value" ;;
  esac
done
# H11: QBFT 25.x<->26.x wire-compat during a mixed-version roll. Set
# LEGACY_PROTOCOL_ENCODING=true when the from/to versions cross 25<->26; clear it
# (re-run without it) once EVERY node is on 26.x.
if [ "${LEGACY_PROTOCOL_ENCODING:-false}" = "true" ]; then
  SET_FLAGS+=(--set bft.legacyProtocolEncoding=true)
  log "H11: appending bft.legacyProtocolEncoding=true (25<->26 mixed-version window)"
fi
log "overrides: ${SET_FLAGS[*]}"

# Max block number seen in a release's recent logs (0 if none). Besu logs
# "Imported block #N" / "Produced empty block #N".
latest_block() {
  local n
  n=$(kubectl -n "$NAMESPACE" logs "${1}-0" -c besu --tail=200 2>/dev/null \
        | grep -oE 'block #[0-9]+' | grep -oE '[0-9]+$' | sort -n | tail -1 || true)
  echo "${n:-0}"
}

# True if the chain is still producing, observed via a reference validator that
# is NOT being changed (proves the surviving validators hold quorum).
chain_advancing() {
  local ref="$1" b0 b1
  b0=$(latest_block "$ref")
  sleep "$SETTLE_SECONDS"
  b1=$(latest_block "$ref")
  log "chain height via ${ref}: ${b0} -> ${b1}"
  [ "$b1" -gt "$b0" ]
}

# OnDelete roll of ONE pod: delete it (so it is recreated on the new template),
# wait for the object to reappear, then wait Ready.
recreate_and_wait() {
  local base="$1" pod="${1}-0" i=0
  kubectl -n "$NAMESPACE" delete pod "$pod" --wait=true >/dev/null \
    || die "failed to delete ${pod} (OnDelete roll)"
  # The StatefulSet controller recreates the pod; wait for the object to exist.
  until kubectl -n "$NAMESPACE" get pod "$pod" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -gt 30 ] && die "${pod} was not recreated after delete"; sleep 2
  done
  kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$pod" --timeout="$POD_READY_TIMEOUT" >/dev/null \
    || die "${pod} did not become Ready within ${POD_READY_TIMEOUT} on the new template"
}

# Discover validator releases (besu.role=validator), deterministically ordered.
mapfile -t VALIDATORS < <(kubectl -n "$NAMESPACE" get statefulset -l besu.role=validator \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort)
[ "${#VALIDATORS[@]}" -ge 4 ] || die "found ${#VALIDATORS[@]} validators (need >=4 to roll without losing QBFT quorum)"
log "validators (${#VALIDATORS[@]}): ${VALIDATORS[*]}"

# --- Preflight: every validator Ready + the chain is advancing ---------------
for v in "${VALIDATORS[@]}"; do
  kubectl -n "$NAMESPACE" rollout status "statefulset/$v" --timeout=120s >/dev/null \
    || die "PREFLIGHT: $v is not Ready — fix the chain before rolling"
done
chain_advancing "${VALIDATORS[1]}" || die "PREFLIGHT: chain not advancing — abort (already below quorum?)"
ok "preflight OK — all validators Ready, chain producing at quorum"

# H16: derive the target besu image (if the overrides set one) for idempotent RESUME —
# so re-running after a mid-roll abort skips validators already on the new image
# instead of bouncing them again.
TARGET_IMAGE=""
for kv in $SET_ARGS; do case "$kv" in besuImage=*) TARGET_IMAGE="${kv#besuImage=}" ;; esac; done

# --- Roll validators ONE AT A TIME -------------------------------------------
for v in "${VALIDATORS[@]}"; do
  # reference validator for the advancing check = any OTHER validator
  ref="${VALIDATORS[0]}"; [ "$ref" = "$v" ] && ref="${VALIDATORS[1]}"

  # H16: idempotent resume — skip a validator ONLY if it is already on the target image AND Ready.
  # A validator on the target TAG but NOT Ready (e.g. CrashLoopBackOff after picking up the new
  # image) must NOT be skipped: skipping it and rolling the NEXT validator drops a second node →
  # transient sub-quorum. When it's on-target-but-not-Ready we fall through to re-apply + the
  # recreate_and_wait gate, which fails LOUD if it can't reach Ready.
  if [ -n "$TARGET_IMAGE" ]; then
    cur="$(kubectl -n "$NAMESPACE" get pod "${v}-0" -o jsonpath='{.spec.containers[?(@.name=="besu")].image}' 2>/dev/null || true)"
    rdy="$(kubectl -n "$NAMESPACE" get pod "${v}-0" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [ "$cur" = "$TARGET_IMAGE" ] && [ "$rdy" = "True" ]; then ok "${v} already on ${TARGET_IMAGE} and Ready — skip (resume)"; continue; fi
    [ "$cur" = "$TARGET_IMAGE" ] && log "${v} on ${TARGET_IMAGE} but NOT Ready (ready=${rdy:-unknown}) — re-applying + verifying instead of skipping"
  fi

  log "==== applying overrides to ${v}  (the other $(( ${#VALIDATORS[@]} - 1 )) keep producing) ===="
  # helm upgrade updates the StatefulSet template; with OnDelete the pod does NOT
  # restart yet. --wait returns once the (still-old) pod is ready (helm skips the
  # updatedReplicas check for OnDelete StatefulSets).
  helm upgrade "$v" "$CHART_DIR" -n "$NAMESPACE" --reuse-values \
    "${SET_FLAGS[@]}" --wait --timeout 5m \
    || die "helm upgrade of ${v} failed — chain still at quorum (others untouched); investigate before continuing"
  # OnDelete (H1): trigger the one-pod restart explicitly so exactly THIS validator rolls.
  recreate_and_wait "$v"
  ok "${v} pod Ready on the new template"

  # GATE 1: the chain kept producing while ${v} bounced (quorum held on the rest).
  chain_advancing "$ref" \
    || die "ABORT: chain STALLED after bouncing ${v} — do NOT touch another validator; investigate quorum/peers"
  # GATE 2: the changed validator re-synced to head. H16: POLL for up to
  # CATCHUP_TIMEOUT before aborting — reading the height once right after restart
  # hits startup noise (low/zero) and would spuriously abort, leaving a half-rolled
  # fleet with no resume. Re-read head each iteration since the chain keeps advancing.
  caught=false; waited=0; mine=0; head=0
  while [ "$waited" -lt "${CATCHUP_TIMEOUT:-180}" ]; do
    head=$(latest_block "$ref"); mine=$(latest_block "$v")
    if [ "$mine" -ge "$(( head - CATCHUP_TOLERANCE ))" ]; then caught=true; break; fi
    log "${v} catching up: ${mine} vs head ${head} (waited ${waited}s)"
    sleep "${CATCHUP_POLL:-10}"; waited=$(( waited + ${CATCHUP_POLL:-10} ))
  done
  [ "$caught" = true ] \
    || die "ABORT: ${v} has not caught up (${mine} vs head ${head}) after ${waited}s — do NOT continue until it has (re-run to RESUME; this validator will be retried, earlier ones skipped)"
  ok "${v} rolled, caught up (${mine} vs head ${head}), chain at quorum — safe to proceed"
done
ok "ALL ${#VALIDATORS[@]} validators rolled, one at a time, quorum preserved throughout"

# --- Optionally roll the non-consensus nodes ---------------------------------
# Bootnodes / SWIFT-rpc / app-rpc / explorer-rpc do NOT vote, so they can be
# rolled without quorum risk. They use updateStrategy=RollingUpdate, so a helm
# upgrade restarts them normally (no manual pod delete needed).
if [ "$INCLUDE_NON_VALIDATORS" = "true" ]; then
  mapfile -t OTHERS < <(kubectl -n "$NAMESPACE" get statefulset -l 'besu.role,besu.role!=validator' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort)
  for o in "${OTHERS[@]}"; do
    log "==== applying overrides to non-validator ${o} ===="
    helm upgrade "$o" "$CHART_DIR" -n "$NAMESPACE" --reuse-values \
      "${SET_FLAGS[@]}" --wait --timeout 5m || die "upgrade of ${o} failed"
    kubectl -n "$NAMESPACE" rollout status "statefulset/$o" --timeout=300s >/dev/null || die "${o} not Ready"
    ok "${o} rolled"
  done
fi

cat <<DONE

------------------------------------------------------------------------------
 Rolling Besu apply COMPLETE
 overrides: ${SET_FLAGS[*]}
 NOTE: validator releases are frozen in Terraform (ignore_changes=[values]), so
       the next 'terraform apply' will NOT revert these overrides. For an image
       bump, still record the new version in the env tfvars (besu_version) so the
       genesis/non-validator paths agree.
 NOTE (Besu 25.x -> 26.x): also pass the wire-compat override during the mixed
       window (see the maintenance runbook / CLAUDE.md §6).
------------------------------------------------------------------------------
DONE

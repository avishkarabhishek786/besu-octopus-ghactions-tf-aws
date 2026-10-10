#!/usr/bin/env bash
# =============================================================================
# scripts/maintenance/migrate-allowlist-ownership.sh
# -----------------------------------------------------------------------------
# ONE-TIME cluster migration: hand the LIVE account allowlist ConfigMap
# (besu-account-allowlist) from Helm to the genesis Job.
#
# Before this change the besu-genesis chart RENDERED the live allowlist. H2 froze
# that release (ignore_changes=[values]), so any later upgrade of it (chart version
# bump, manual `helm upgrade`) re-rendered the ConfigMap from the ORIGINAL genesis
# seed and silently dropped every runtime onboarding / restored revoked senders.
# The chart now renders only an inert `<name>-seed` and the Job creates the live
# ConfigMap create-if-absent (helm/charts/besu-genesis/templates/job.yaml).
#
# On a chain created BEFORE that change, the live ConfigMap is still in the
# genesis release's manifest. The new chart no longer contains it, so the first
# genesis upgrade would make Helm DELETE it; the Job would then re-create it from
# the seed, which is the same data loss. This script prevents that by annotating
# the live ConfigMap `helm.sh/resource-policy: keep` (Helm checks this on the LIVE
# object and skips the delete) and labelling it as Job-owned. Its contents are
# NOT touched.
#
#   * FRESH chains need nothing — the Job created the ConfigMap, Helm never owned it.
#   * IDEMPOTENT — a no-op if already migrated; never changes the allowlist data.
#   * DRY-RUN by default — prints what it would do; pass --apply to execute.
#   * Run it BEFORE any upgrade of the besu-genesis release (e.g. a chart version
#     bump), from the in-VPC runner (private EKS endpoint), after
#     `aws eks update-kubeconfig --name <cluster> --region <deploy region>`.
#
# Usage (from the repo root):
#   scripts/maintenance/migrate-allowlist-ownership.sh            # dry-run
#   scripts/maintenance/migrate-allowlist-ownership.sh --apply    # annotate + label
#   # optional: NAMESPACE (default besu), CONFIGMAP (default besu-account-allowlist)
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

NAMESPACE="${NAMESPACE:-besu}"
CONFIGMAP="${CONFIGMAP:-besu-account-allowlist}"
APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true

need kubectl
need jq

CM_JSON="$(kubectl -n "$NAMESPACE" get configmap "$CONFIGMAP" -o json 2>/dev/null || true)"
if [ -z "$CM_JSON" ]; then
  ok "ConfigMap $NAMESPACE/$CONFIGMAP not found — account permissioning is off (or not yet deployed). Nothing to migrate."
  exit 0
fi

policy="$(jq -r '.metadata.annotations["helm.sh/resource-policy"] // ""' <<<"$CM_JSON")"
owner="$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<<"$CM_JSON")"
release="$(jq -r '.metadata.annotations["meta.helm.sh/release-name"] // ""' <<<"$CM_JSON")"
count="$(jq -r '.data["permissions_accounts.toml"] // ""' <<<"$CM_JSON" | grep -oiE '0x[0-9a-fA-F]{40}' | wc -l | tr -d ' ')"

log "current: managed-by='${owner}' helm-release='${release:-none}' resource-policy='${policy:-none}' accounts=${count}"

if [ "$policy" = "keep" ] && [ "$owner" = "besu-genesis-job" ]; then
  ok "already migrated — Helm will not delete or re-render $CONFIGMAP. No-op."
  exit 0
fi

if [ "$APPLY" != true ]; then
  log "DRY-RUN — would run:"
  log "  kubectl -n $NAMESPACE annotate configmap $CONFIGMAP helm.sh/resource-policy=keep --overwrite"
  log "  kubectl -n $NAMESPACE label    configmap $CONFIGMAP app.kubernetes.io/managed-by=besu-genesis-job --overwrite"
  log "Re-run with --apply to perform it. The allowlist DATA is not changed."
  exit 0
fi

kubectl -n "$NAMESPACE" annotate configmap "$CONFIGMAP" helm.sh/resource-policy=keep --overwrite >/dev/null
kubectl -n "$NAMESPACE" label configmap "$CONFIGMAP" app.kubernetes.io/managed-by=besu-genesis-job --overwrite >/dev/null

# Verify: annotation landed and the data is byte-identical to before.
AFTER="$(kubectl -n "$NAMESPACE" get configmap "$CONFIGMAP" -o json)"
[ "$(jq -r '.metadata.annotations["helm.sh/resource-policy"] // ""' <<<"$AFTER")" = "keep" ] \
  || die "annotation did not land on $CONFIGMAP"
[ "$(jq -c '.data' <<<"$AFTER")" = "$(jq -c '.data' <<<"$CM_JSON")" ] \
  || die "allowlist DATA changed during migration — investigate (scripts/permissioning/list-accounts.sh)"

ok "migrated: $CONFIGMAP is now Job-owned and protected from Helm deletion (${count} account(s) unchanged)."
log "A later besu-genesis upgrade will log 'Skipping delete' for it and the Job will keep it as-is."

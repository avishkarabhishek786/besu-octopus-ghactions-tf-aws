#!/usr/bin/env bash
# =============================================================================
# scripts/permissioning/list-accounts.sh
# -----------------------------------------------------------------------------
# Show the file-based account allowlist (backlog C6): the ConfigMap source of
# truth, and — with --live — each enforcing pod's mounted view (to spot a node
# that hasn't re-read after a change).
#
#   scripts/permissioning/list-accounts.sh
#   scripts/permissioning/list-accounts.sh --live
#
# RUN FROM the in-VPC runner (private EKS endpoint). See _perm-lib.sh header.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_perm-lib.sh"

cm_require
log "allowlist source of truth (ConfigMap ${CONFIGMAP}):"
cm_addrs | sed 's/^/    /'; echo

if [ "${1:-}" = "--live" ]; then
  # H3 fix: read the file Besu ACTUALLY enforces — the writable /data copy that
  # build-config makes from the ConfigMap at boot (and that perm_* persists to on a
  # hot reconcile). The old default (/config/perm-accounts/...) is only mounted on the
  # build-config INIT container, never in the main besu container, so it always read
  # <unreadable> and hid drift. Override with MOUNT= only if you know why.
  MOUNT="${MOUNT:-/data/permissions_accounts.toml}"
  mapfile -t pods < <(kubectl -n "$NAMESPACE" get pods \
    -l 'app.kubernetes.io/name=besu-node,besu.role in (validator,rpc,app-rpc,explorer-rpc)' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort)
  log "live per-pod enforced view (${MOUNT}):"
  for p in "${pods[@]}"; do
    v=$(kubectl -n "$NAMESPACE" exec "$p" -c besu -- cat "$MOUNT" 2>/dev/null \
          | grep -oiE '0x[0-9a-fA-F]{40}' | tr '\n' ' ' || true)
    printf '    %-28s %s\n' "$p" "${v:-<unreadable>}"
  done
fi

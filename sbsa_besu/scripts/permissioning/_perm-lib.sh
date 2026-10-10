#!/usr/bin/env bash
# =============================================================================
# scripts/permissioning/_perm-lib.sh — shared helpers for FILE-BASED account
# permissioning (backlog C6). Sourced by add/remove/list/reload-permissions.sh.
# -----------------------------------------------------------------------------
# MODEL B (decided 2026-07-05): the account allowlist is a single ConfigMap
# (besu-account-allowlist, key permissions_accounts.toml) that every enforcing
# besu-node mounts read-only and points --permissions-accounts-config-file at.
# These helpers mutate that ConfigMap (the durable source of truth) and then
# PROPAGATE the change to the running pods.
#
# PROPAGATION (PROPAGATE env, default "restart"):
#   restart — rolling restart of every enforcing StatefulSet so each pod re-reads
#             the ConfigMap on boot. Validators go ONE AT A TIME with a quorum-
#             advancing gate (QBFT: only one validator may be down). Always works;
#             needs no RPC. This is the safe default. A read-back (verify_via_file)
#             then confirms every validator's /data allowlist matches the ConfigMap.
#   hot     — RECONCILE each validator's in-memory allowlist to the (already-patched)
#             ConfigMap via perm_add/removeAccountsFromAllowlist on the internal ops
#             listener (opsRpc.enabled=true → PERM, ClusterIP-only), then READ BACK
#             perm_getAccountsAllowlist and FAIL LOUDLY on any mismatch; plus a
#             rolling restart of the RPC pools (they carry no PERM listener). No
#             validator bounce; requires the ops listener.
#             ⚠️ H3 fix (2026-07-06): the OLD hot path called
#             perm_reloadPermissionsFromFile, which re-reads /data/permissions_accounts.toml
#             — the FROZEN boot-copy build-config makes from the ConfigMap. The main
#             besu container does NOT mount the ConfigMap, so a patch never reached
#             that file at runtime → the reload was a SILENT NO-OP: a REVOCATION
#             reported "Success" while the compromised sender kept transacting.
#   none    — mutate the ConfigMap only; print how to propagate later
#             (reload-permissions.sh).
#
# ⚠️ OWNERSHIP: the LIVE ConfigMap is created ONCE (create-if-absent) by the genesis
# Job from the Helm-rendered <name>-seed (permissioning_admin_account +
# initial_account_allowlist). Helm never owns it, so after genesis the LIVE ConfigMap
# is the truth: a tfvars allowlist edit is inert, and neither `terraform apply` nor a
# besu-genesis upgrade reverts a patch made here. Only allowRegenesis=true resets it.
# Chains created before this split: scripts/maintenance/migrate-allowlist-ownership.sh.
#
# RUN FROM the In-VPC EC2 Runner (private EKS endpoint), repo root, after
#   `aws eks update-kubeconfig --name <cluster> --region <region>`.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

need kubectl
need jq

NAMESPACE="${NAMESPACE:-besu}"
CONFIGMAP="${CONFIGMAP:-besu-account-allowlist}"
CM_KEY="permissions_accounts.toml"
PROPAGATE="${PROPAGATE:-restart}"
OPS_PORT="${OPS_PORT:-8545}"       # validator internal ops listener (perm_* lives here)
SETTLE_SECONDS="${SETTLE_SECONDS:-15}" # ~2-3 block periods to confirm the chain advanced
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"

# --- address validation ------------------------------------------------------
# Besu account allowlist entries are 20-byte hex addresses (0x + 40 hex).
valid_addr() { printf '%s' "$1" | grep -qiE '^0x[0-9a-fA-F]{40}$'; }

# --- ConfigMap read/write ----------------------------------------------------
# cm_addrs: current allowlist addresses, one per line (empty if the CM/key absent).
cm_addrs() {
  kubectl -n "$NAMESPACE" get configmap "$CONFIGMAP" \
    -o "jsonpath={.data.${CM_KEY//./\\.}}" 2>/dev/null \
    | grep -oiE '0x[0-9a-fA-F]{40}' || true
}

# cm_require: fail clearly if the ConfigMap does not exist (account mode is off).
cm_require() {
  kubectl -n "$NAMESPACE" get configmap "$CONFIGMAP" >/dev/null 2>&1 || die \
    "ConfigMap '$CONFIGMAP' not found in namespace '$NAMESPACE'. Account permissioning is not enabled — set account_permissioning_mode=\"local\" (with a seeded allowlist) and apply, then re-run."
}

# cm_write <addr...> : rewrite the allowlist to EXACTLY the given (deduped) set,
# via a merge-patch of the data key (preserves the ConfigMap's metadata/labels).
cm_write() {
  local addrs body toml first=1
  addrs=$(printf '%s\n' "$@" | awk 'NF' | sort -u)
  [ -n "$addrs" ] || die "refusing to write an EMPTY allowlist — that denies every sender (chain accepts no tx). Use remove-account.sh only down to the last needed sender, or disable account permissioning via tfvars."
  toml='accounts-allowlist=['
  while IFS= read -r a; do
    [ "$first" -eq 1 ] || toml="$toml,"
    toml="$toml\"$a\""; first=0
  done <<<"$addrs"
  toml="$toml]"
  body=$(jq -n --arg c "$toml" "{data:{\"$CM_KEY\":\$c}}")
  kubectl -n "$NAMESPACE" patch configmap "$CONFIGMAP" --type merge -p "$body" >/dev/null
  ok "ConfigMap $CONFIGMAP updated:"
  printf '%s\n' "$addrs" | sed 's/^/    /'
}

# --- pod / statefulset discovery --------------------------------------------
# Enforcing nodes = every node that accepts/proposes transactions: validators +
# every RPC pool. (Bootnodes don't accept client tx, but they mount the same list
# harmlessly; we restart only tx-accepting roles.)
sts_by_role() { # $1=role selector expr for -l
  kubectl -n "$NAMESPACE" get statefulset -l "$1" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort
}

# H3: authoritative validator discovery by NAME pattern (besu-validator-N), INDEPENDENT of the
# besu.role label — so label drift cannot silently shrink the set we reconcile/verify.
sts_by_name() { # $1 = extended-regex name pattern
  kubectl -n "$NAMESPACE" get statefulset \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E "$1" | sort || true
}

# require_full_validator_set: print the validator StatefulSets (one per line) ONLY if the set is
# COMPLETE; otherwise die. Closes a fail-open revocation: if role-label discovery under-counts (a
# mislabeled/renamed validator drops out of the selector), a "Success" reconcile would leave the
# undiscovered validator still honouring a revoked account. Guards: (1) >=4 by label (QBFT quorum),
# (2) no validator exists by name that the label missed. MUST be called via command substitution
# (`x="$(require_full_validator_set)"`), NOT process substitution — its `die` has to abort the
# caller, and a `<(...)` subshell exit would be swallowed.
require_full_validator_set() {
  local -a by_label by_name
  mapfile -t by_label < <(sts_by_role 'besu.role=validator')
  mapfile -t by_name < <(sts_by_name 'besu-validator-[0-9]+$')
  [ "${#by_label[@]}" -ge 4 ] || die "found ${#by_label[@]} validators by role label (need >=4 for QBFT quorum) — refusing to enforce a PARTIAL allowlist. Check validator labels/health."
  [ "${#by_name[@]}" -le "${#by_label[@]}" ] || die "validator label drift: ${#by_name[@]} StatefulSets match besu-validator-* but only ${#by_label[@]} carry besu.role=validator — a validator would NOT be reconciled (fail-open revocation). Fix the labels, then re-run."
  printf '%s\n' "${by_label[@]}"
}

# --- chain-advancing gate (QBFT quorum), same signal as rolling-besu-upgrade --
latest_block() {
  local n
  n=$(kubectl -n "$NAMESPACE" logs "${1}-0" -c besu --tail=200 2>/dev/null \
        | grep -oE 'block #[0-9]+' | grep -oE '[0-9]+$' | sort -n | tail -1 || true)
  echo "${n:-0}"
}
chain_advancing() {
  local ref="$1" b0 b1
  b0=$(latest_block "$ref"); sleep "$SETTLE_SECONDS"; b1=$(latest_block "$ref")
  log "chain height via ${ref}: ${b0} -> ${b1}"
  [ "$b1" -gt "$b0" ]
}

# --- propagation: restart ----------------------------------------------------
restart_rpc_pools() {
  local pools o
  mapfile -t pools < <(sts_by_role 'app.kubernetes.io/name=besu-node,besu.role in (rpc,app-rpc,explorer-rpc)')
  if [ "${#pools[@]}" -eq 0 ]; then log "no RPC-pool StatefulSets found — skipping"; return 0; fi
  for o in "${pools[@]}"; do
    log "restart RPC pool ${o} (re-reads the allowlist on boot)"
    kubectl -n "$NAMESPACE" rollout restart "statefulset/$o" >/dev/null
    kubectl -n "$NAMESPACE" rollout status "statefulset/$o" --timeout="$ROLLOUT_TIMEOUT" >/dev/null \
      || die "${o} did not become Ready after restart"
    ok "${o} restarted"
  done
}

restart_validators() { # ONE AT A TIME with a quorum-advancing gate
  local vals_str v ref
  local -a vals
  vals_str="$(require_full_validator_set)" || exit 1 # H3: full-set guard (>=4 + no label drift)
  mapfile -t vals <<<"$vals_str"
  chain_advancing "${vals[1]}" || die "PREFLIGHT: chain not advancing — abort (already below quorum?)"
  for v in "${vals[@]}"; do
    ref="${vals[0]}"; [ "$ref" = "$v" ] && ref="${vals[1]}"
    log "==== restart validator ${v} (the other $(( ${#vals[@]} - 1 )) keep producing) ===="
    kubectl -n "$NAMESPACE" rollout restart "statefulset/$v" >/dev/null
    kubectl -n "$NAMESPACE" rollout status "statefulset/$v" --timeout="$ROLLOUT_TIMEOUT" >/dev/null \
      || die "${v} did not become Ready after restart"
    chain_advancing "$ref" \
      || die "ABORT: chain STALLED after bouncing ${v} — do NOT touch another validator; investigate quorum/peers"
    ok "${v} restarted, chain still at quorum — safe to continue"
  done
}

# --- desired set + JSON helpers ----------------------------------------------
# desired allowlist (lowercased, sorted-unique), from the just-patched ConfigMap.
desired_addrs() { cm_addrs | tr 'A-F' 'a-f' | awk 'NF' | sort -u; }
# JSON array of quoted addresses from args, e.g. ["0x..","0x.."] (empty -> []).
_addr_json_array() { printf '%s\n' "$@" | awk 'NF' | jq -R . | jq -s -c .; }

# --- propagation: hot reconcile (validators via the internal ops listener) ---
# H3: reconcile each validator's IN-MEMORY allowlist to the desired ConfigMap set
# with perm_add/removeAccountsFromAllowlist (mutate memory AND persist to the
# writable /data file), then read back perm_getAccountsAllowlist and verify.

# perm_rpc <validator-sts> <method> <params-json> -> raw JSON response (or "").
# Polls the local port for readiness (no fixed sleep — also addresses H32).
perm_rpc() {
  local v="$1" method="$2" params="$3" lport pf rc i
  lport=$(( 18545 + RANDOM % 2000 ))
  kubectl -n "$NAMESPACE" port-forward "statefulset/$v" "${lport}:${OPS_PORT}" >/dev/null 2>&1 &
  pf=$!
  for i in $(seq 1 20); do
    (exec 3<>"/dev/tcp/127.0.0.1/${lport}") 2>/dev/null && { exec 3>&- 3<&- 2>/dev/null || true; break; }
    sleep 0.5
  done
  rc=$(curl -s -m 10 -X POST -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":${params},\"id\":1}" \
        "http://127.0.0.1:${lport}" 2>/dev/null || true)
  kill "$pf" >/dev/null 2>&1 || true
  printf '%s' "$rc"
}

# get_enforced <validator> -> IN-MEMORY allowlist, lowercased addrs, one per line.
get_enforced() {
  perm_rpc "$1" perm_getAccountsAllowlist '[]' \
    | jq -r '.result[]?' 2>/dev/null | grep -oiE '0x[0-9a-fA-F]{40}' | tr 'A-F' 'a-f' || true
}

hot_reconcile_validator() { # $1=validator sts — reconcile in-memory allowlist -> desired
  local v="$1" want enforced resp final
  local -a add_list remove_list
  want=$(desired_addrs)
  enforced=$(get_enforced "$v")
  mapfile -t add_list    < <(comm -23 <(printf '%s\n' "$want" | awk 'NF' | sort -u) <(printf '%s\n' "$enforced" | awk 'NF' | sort -u))
  mapfile -t remove_list < <(comm -13 <(printf '%s\n' "$want" | awk 'NF' | sort -u) <(printf '%s\n' "$enforced" | awk 'NF' | sort -u))

  if [ "${#add_list[@]}" -gt 0 ]; then
    resp=$(perm_rpc "$v" perm_addAccountsToAllowlist "[$(_addr_json_array "${add_list[@]}")]")
    case "$resp" in
      *'"result":"Success"'*) ok "${v}: added ${#add_list[@]} account(s) → Success" ;;
      *) err "${v}: perm_addAccountsToAllowlist failed (opsRpc.enabled=true with PERM?): ${resp:-<none>}"; return 1 ;;
    esac
  fi
  if [ "${#remove_list[@]}" -gt 0 ]; then
    resp=$(perm_rpc "$v" perm_removeAccountsFromAllowlist "[$(_addr_json_array "${remove_list[@]}")]")
    case "$resp" in
      *'"result":"Success"'*) ok "${v}: removed ${#remove_list[@]} account(s) → Success" ;;
      *) err "${v}: perm_removeAccountsFromAllowlist failed: ${resp:-<none>}"; return 1 ;;
    esac
  fi
  # READ BACK + verify the enforced set now equals the desired set.
  final=$(get_enforced "$v" | awk 'NF' | sort -u)
  if [ "$final" != "$want" ]; then
    err "${v}: VERIFY FAILED — enforced allowlist != desired"
    err "  enforced: $(printf '%s' "$final" | tr '\n' ' ')"
    err "  desired : $(printf '%s' "$want" | tr '\n' ' ')"
    return 1
  fi
  ok "${v}: enforced allowlist VERIFIED ($(printf '%s\n' "$want" | awk 'NF' | wc -l | tr -d ' ') account(s))"
}

hot_reconcile_validators() {
  need curl
  local vals_str v fail=0
  local -a vals
  # H3: require the COMPLETE validator set (>=4 + no label drift) BEFORE reconciling — a partial set
  # would let a revocation report "Success" while an undiscovered validator keeps honouring the account.
  vals_str="$(require_full_validator_set)" || exit 1
  mapfile -t vals <<<"$vals_str"
  for v in "${vals[@]}"; do hot_reconcile_validator "$v" || fail=1; done
  [ "$fail" -eq 0 ] || die "one or more validators failed hot reconcile/verify — the allowlist is NOT uniformly enforced. Investigate, or fall back to PROPAGATE=restart."
}

# --- read-back verification for the restart path -----------------------------
# After a restart, read the enforced /data file on each validator and confirm it
# matches the desired ConfigMap set (H3: prove the change actually took effect).
verify_via_file() {
  local want vals_str v got fail=0
  local -a vals
  want=$(desired_addrs)
  vals_str="$(require_full_validator_set)" || exit 1 # H3: verify the FULL set, not a subset
  mapfile -t vals <<<"$vals_str"
  for v in "${vals[@]}"; do
    got=$(kubectl -n "$NAMESPACE" exec "${v}-0" -c besu -- cat /data/permissions_accounts.toml 2>/dev/null \
            | grep -oiE '0x[0-9a-fA-F]{40}' | tr 'A-F' 'a-f' | awk 'NF' | sort -u || true)
    if [ "$got" != "$want" ]; then
      err "${v}: VERIFY FAILED (restart) — /data allowlist != desired ConfigMap"; fail=1
    else
      ok "${v}: /data allowlist VERIFIED"
    fi
  done
  [ "$fail" -eq 0 ] || die "post-restart verification failed on one or more validators — allowlist NOT uniformly enforced"
}

# --- propagation entrypoint --------------------------------------------------
propagate() {
  case "$PROPAGATE" in
    restart) log "PROPAGATE=restart — rolling restart of enforcing nodes"; restart_validators; restart_rpc_pools; verify_via_file ;;
    hot)     log "PROPAGATE=hot — reconcile validators via perm_* (+verify) + restart RPC pools"; hot_reconcile_validators; restart_rpc_pools ;;
    none)    log "PROPAGATE=none — ConfigMap updated ONLY. Propagate with: PROPAGATE=restart scripts/permissioning/reload-permissions.sh" ;;
    *)       die "unknown PROPAGATE='$PROPAGATE' (use restart | hot | none)" ;;
  esac
}

# Reminder printed after a ConfigMap mutation.
persist_reminder() {
  cat <<EOF
[$(_ts)] NOTE  The LIVE ConfigMap is the source of truth (Job-owned, not Helm): neither
              \`terraform apply\` nor a genesis upgrade reverts this, and tfvars
              allowlist edits do not reach it. Record the change, and mirror it into
              initial_account_allowlist only as the seed for a FUTURE rebuild.
EOF
}

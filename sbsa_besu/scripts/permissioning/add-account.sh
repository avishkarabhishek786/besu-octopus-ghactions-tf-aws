#!/usr/bin/env bash
# =============================================================================
# scripts/permissioning/add-account.sh
# -----------------------------------------------------------------------------
# Add one or more account (tx-sender) addresses to the FILE-BASED account
# allowlist WITHOUT re-genesis (backlog C6). Patches the besu-account-allowlist
# ConfigMap (source of truth), then propagates to the enforcing nodes.
#
#   scripts/permissioning/add-account.sh 0xabc... [0xdef... ...]
#   PROPAGATE=hot   scripts/permissioning/add-account.sh 0xabc...   # reload, no bounce (ops listener)
#   PROPAGATE=none  scripts/permissioning/add-account.sh 0xabc...   # ConfigMap only; propagate later
#
# ⚠️ A newly-allowed sender that must ORIGINATE tx on the zero-gas chain also
# needs a balance (F20). On a running chain (no re-genesis) fund it with a tx
# from an already-allowed, funded account. Only genesis-time seeds are auto-funded.
#
# RUN FROM the In-VPC EC2 Runner (private EKS endpoint). See _perm-lib.sh header.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_perm-lib.sh"

[ "$#" -ge 1 ] || die "usage: add-account.sh <0xaddress> [<0xaddress> ...]"
for a in "$@"; do valid_addr "$a" || die "not a valid 20-byte hex address: $a"; done

cm_require
mapfile -t current < <(cm_addrs)
log "current allowlist has ${#current[@]} account(s)"

# Union of current + requested (cm_write dedups + sorts).
declare -a want=("${current[@]}" "$@")
cm_write "${want[@]}"
propagate
persist_reminder
ok "add-account complete (${#} requested; allowlist now $(cm_addrs | wc -l | tr -d ' ') account(s))"

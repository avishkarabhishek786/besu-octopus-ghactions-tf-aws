#!/usr/bin/env bash
# =============================================================================
# scripts/permissioning/remove-account.sh
# -----------------------------------------------------------------------------
# Revoke one or more account (tx-sender) addresses from the FILE-BASED account
# allowlist (backlog C6). Patches the besu-account-allowlist ConfigMap, then
# propagates. Refuses to empty the list (an empty allowlist denies every sender).
#
#   scripts/permissioning/remove-account.sh 0xabc... [0xdef... ...]
#
# RUN FROM the in-VPC runner (private EKS endpoint). See _perm-lib.sh header.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_perm-lib.sh"

[ "$#" -ge 1 ] || die "usage: remove-account.sh <0xaddress> [<0xaddress> ...]"
for a in "$@"; do valid_addr "$a" || die "not a valid 20-byte hex address: $a"; done

cm_require
mapfile -t current < <(cm_addrs)
[ "${#current[@]}" -gt 0 ] || die "allowlist is already empty — nothing to remove"

# Lowercase the removal set for case-insensitive matching.
declare -A drop=()
for a in "$@"; do drop["$(printf '%s' "$a" | tr 'A-F' 'a-f')"]=1; done
declare -a keep=()
for a in "${current[@]}"; do
  [ -n "${drop[$(printf '%s' "$a" | tr 'A-F' 'a-f')]:-}" ] || keep+=("$a")
done
[ "${#keep[@]}" -gt 0 ] || die "that would remove EVERY account — refused (an empty allowlist denies all senders). Disable account permissioning via tfvars instead."

log "removing $(( ${#current[@]} - ${#keep[@]} )) account(s); ${#keep[@]} remain"
cm_write "${keep[@]}"
propagate
persist_reminder
ok "remove-account complete (allowlist now ${#keep[@]} account(s))"

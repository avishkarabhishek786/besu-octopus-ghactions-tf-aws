#!/usr/bin/env bash
# =============================================================================
# scripts/maintenance/migrate-h1-validator-split.sh
# -----------------------------------------------------------------------------
# ONE-TIME Terraform STATE migration for H1 (validator helm_release split).
#
# H1 moved the validators out of `helm_release.node` (one for_each over ALL nodes)
# into their own `helm_release.validator` resource (with ignore_changes + OnDelete).
# On a FRESH chain this needs nothing — the first apply just creates the validators
# at their new addresses. But on an ALREADY-APPLIED chain whose state still holds
#   module.besu.helm_release.node["besu-validator-N"]
# a plain `terraform apply` would DESTROY those and CREATE
#   module.besu.helm_release.validator["besu-validator-N"]
# i.e. helm-uninstall + reinstall EVERY validator in one apply → all bounce
# together → QBFT quorum lost → the chain HALTS.
#
# This script re-homes each validator release in STATE FIRST, so the subsequent
# apply sees them as unchanged (moved, not recreated). It is:
#   * STATE-ONLY — `terraform state list` / `state mv`; it makes NO cluster calls,
#     so it can run from the laptop or the In-VPC EC2 Runner (wherever the backend
#     state is initialized).
#   * IDEMPOTENT — a no-op when there are no legacy validator addresses (fresh
#     state or already migrated). Non-validator releases (bootnode/rpc/app-rpc/
#     explorer-rpc) are NEVER touched — they legitimately stay in helm_release.node.
#   * DRY-RUN by default — prints the exact moves; pass --apply to execute them.
#
# Usage (from the repo root):
#   scripts/maintenance/migrate-h1-validator-split.sh            # dry-run
#   scripts/maintenance/migrate-h1-validator-split.sh --apply    # perform the moves
#   # optional: TF_ROOT (default "terraform"), MODULE (default "module.besu")
#
# Terraform MUST be initialized in TF_ROOT (backend configured) first. After a
# successful --apply, run `terraform -chdir=$TF_ROOT plan` — the validators must
# show NO changes (proving they were re-homed, not slated for recreate).
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

TF_ROOT="${TF_ROOT:-terraform}"
MODULE="${MODULE:-module.besu}"
APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true

need terraform
[ -d "$TF_ROOT" ] || die "TF_ROOT '$TF_ROOT' not found — run from the repo root (or set TF_ROOT)"
terraform -chdir="$TF_ROOT" version >/dev/null 2>&1 \
  || die "terraform not usable in '$TF_ROOT' — run 'terraform -chdir=$TF_ROOT init' first"

# Read the state inventory once (read-only, no lock).
STATE="$(terraform -chdir="$TF_ROOT" state list 2>/dev/null || true)"
[ -n "$STATE" ] || die "empty state list for '$TF_ROOT' — is the backend initialized and non-empty?"

# Match ONLY module.besu.helm_release.node["besu-validator-<digits>"] via literal
# prefix/suffix checks (avoids regex/glob metacharacter pitfalls with the [ " ] chars).
PREFIX="${MODULE}.helm_release.node[\"besu-validator-"
SUFFIX="\"]"

declare -a MOVES=()
skipped=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # must start with PREFIX and end with SUFFIX...
  [ "${line#"$PREFIX"}" != "$line" ] || continue
  [ "${line%"$SUFFIX"}" != "$line" ] || continue
  # ...and the middle must be a pure integer (so besu-validator-1 matches but a
  # hypothetical besu-validator-1-foo would not).
  mid="${line#"$PREFIX"}"; mid="${mid%"$SUFFIX"}"
  case "$mid" in '' | *[!0-9]*) continue ;; esac

  dst="${MODULE}.helm_release.validator[\"besu-validator-${mid}\"]"
  if grep -qxF "$dst" <<<"$STATE"; then
    log "SKIP besu-validator-${mid}: target already in state ($dst) — already migrated"
    skipped=$((skipped + 1)); continue
  fi
  MOVES+=("${line}|${dst}")
done <<<"$STATE"

if [ "${#MOVES[@]}" -eq 0 ]; then
  if [ "$skipped" -gt 0 ]; then
    ok "nothing to do — ${skipped} validator release(s) already migrated. Safe to apply."
  else
    ok "no legacy validator releases in state (${MODULE}.helm_release.node[\"besu-validator-*\"]). Fresh/already-split state — safe to apply, no migration needed."
  fi
  exit 0
fi

log "H1 state migration — ${#MOVES[@]} validator release(s) to re-home (node -> validator):"
for m in "${MOVES[@]}"; do
  printf '    %s\n      -> %s\n' "${m%%|*}" "${m##*|}"
done

if [ "$APPLY" != true ]; then
  echo
  log "DRY-RUN (no changes made). Re-run with --apply to perform the ${#MOVES[@]} move(s)."
  log "Then: terraform -chdir=${TF_ROOT} plan  (validators must show NO changes)."
  exit 0
fi

log "applying ${#MOVES[@]} state move(s) ..."
for m in "${MOVES[@]}"; do
  src="${m%%|*}"; dst="${m##*|}"
  terraform -chdir="$TF_ROOT" state mv "$src" "$dst" >/dev/null \
    || die "state mv FAILED for ${src} — state may be partially migrated. Inspect 'terraform -chdir=${TF_ROOT} state list' and .tfstate backups before proceeding."
  ok "moved ${src} -> ${dst}"
done
ok "migrated ${#MOVES[@]} validator release(s)."
log "NEXT: terraform -chdir=${TF_ROOT} plan — the validators must show NO changes (re-homed, not recreated). Only then apply."

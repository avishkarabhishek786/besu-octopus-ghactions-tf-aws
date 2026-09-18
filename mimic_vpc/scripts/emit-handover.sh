#!/usr/bin/env bash
# =============================================================================
# emit-handover.sh — render the hand-over contract for the platform project.
# -----------------------------------------------------------------------------
# Reads this project's Terraform outputs and writes a tfvars fragment that
# `sbsa_besu` drops in unmodified.
#
# WHY A FILE RATHER THAN terraform_remote_state:
#   The real cloud team will not grant Terraform state access. They will send a
#   list of IDs. Reproducing that exact hand-off is the entire point of this
#   project — a remote_state dependency would work in deploy-tests and fail at
#   go-live. See CLAUDE.md §4.
#
# Usage:  scripts/emit-handover.sh [output-path]
# =============================================================================
set -euo pipefail

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
OUT="${1:-$TF_DIR/../network-handover.auto.tfvars}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required."
cd "$TF_DIR"
terraform output -json >/dev/null 2>&1 || die "no Terraform outputs — apply first."

log "rendering hand-over contract -> $OUT"

# ATOMIC WRITE (build finding B19). `cat > "$OUT" <<...` truncates the target
# BEFORE any $(terraform output) inside the heredoc runs, so a single failed
# read used to leave a 0-byte hand-over behind, skip the copy into the platform,
# and leave the platform holding whatever STALE file it had — which is a
# hand-over that looks valid and points at a VPC that no longer exists. Render
# into a temp file, prove it is a real hand-over, then move it into place.
TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
# Fail loudly if any output read fails: `set -e` does not propagate out of a
# heredoc's command substitutions, so check every value explicitly.
s() { local v; v="$(terraform output -raw "$1" 2>/dev/null)" || die "terraform output -raw $1 failed — state unreadable? (credentials expired / wrong backend?)"; [ -n "$v" ] || die "output $1 is empty"; printf '%s' "$v"; }
o() { local v; v="$(terraform output -json 2>/dev/null | jq -er ".$1.value | tojson")" || die "terraform output $1 (json) failed"; printf '%s' "$v"; }

cat > "$TMP" <<TFVARS
# =============================================================================
# network-handover.auto.tfvars   — GENERATED, DO NOT EDIT BY HAND
# -----------------------------------------------------------------------------
# Emitted by mimic_vpc/scripts/emit-handover.sh at $TS
#
# In production this file is assembled BY HAND from the values the cloud team
# sends you. Its shape is the contract; regenerate it rather than editing it.
#
# Every consumer assertion lives in sbsa_besu's modules/network-contract, which
# creates nothing and validates all of this against the live AWS API before any
# cluster is built.
# =============================================================================

vpc_id             = "$(s vpc_id)"
vpc_cidr_primary   = "$(s vpc_cidr_primary)"
vpc_cidr_secondary = "$(s vpc_cidr_secondary)"
dhcp_options_id    = "$(s dhcp_options_id)"
# The region the network lives in. The platform asserts its own
# primary_region equals this — a cluster must never be built in a
# different region from its VPC.
network_region     = "$(s region)"

# AZ IDs, not names (#5).
az_ids = $(o az_ids)

# Subnet maps keyed by AZ ID.
ledger_subnet_ids   = $(o ledger_subnet_ids)
app_subnet_ids      = $(o app_subnet_ids)
lb_subnet_ids       = $(o lb_subnet_ids)
endpoint_subnet_ids = $(o endpoint_subnet_ids)
data_subnet_ids     = $(o data_subnet_ids)

# Route tables — needed to associate gateway endpoints when we own that (#10).
ledger_route_table_ids   = $(o ledger_route_table_ids)
app_route_table_ids      = $(o app_route_table_ids)
lb_route_table_ids       = $(o lb_route_table_ids)
endpoint_route_table_ids = $(o endpoint_route_table_ids)

# NACLs: the cloud team owns the resources, the platform manages the RULES (#13).
ledger_nacl_ids = $(o ledger_nacl_ids)

# Ownership answers the platform branches on.
gateway_endpoints_exist     = $(s gateway_endpoints_created_here)
central_interface_endpoints = $(s central_interface_endpoints)

# Informational: for security-group and NACL rule authoring.
subnet_cidrs_by_role = $(o subnet_cidrs_by_role)
TFVARS

# Prove the render before it replaces anything: non-empty, carries a VPC ID, and
# names the region we think we are in.
[ -s "$TMP" ] || die "rendered hand-over is EMPTY — refusing to replace $OUT"
grep -Eq '^vpc_id += +"vpc-' "$TMP" || die "rendered hand-over has no vpc_id — refusing to replace $OUT"
grep -Eq '^network_region += +"[a-z]+-[a-z]+-[0-9]"' "$TMP" || die "rendered hand-over has no network_region — refusing to replace $OUT"
mv -f "$TMP" "$OUT" && chmod 0644 "$OUT"   # mktemp made it 0600; the hand-over is not a secret
trap - EXIT
log "rendered $(wc -c < "$OUT") bytes; vpc=$(grep -E '^vpc_id' "$OUT" | cut -d'"' -f2) region=$(grep -E '^network_region' "$OUT" | cut -d'"' -f2)"

# -----------------------------------------------------------------------------
# Wire the platform's roots, if it is checked out beside this project.
# -----------------------------------------------------------------------------
# Every network-consuming root (shared, chain, app) reads ONE hand-over file via
# a symlink, so the three can never drift apart. The symlinks are not in git:
# *.auto.tfvars is gitignored, which matches them by name. Recreating them here
# means a fresh clone plus one run of this script is fully wired, with no manual
# step that someone can forget and then spend an afternoon debugging.
# -----------------------------------------------------------------------------
PLATFORM_TF="$(cd "$TF_DIR/../../sbsa_besu/terraform" 2>/dev/null && pwd || true)"

if [[ -n "$PLATFORM_TF" && -d "$PLATFORM_TF" ]]; then
  TARGET="$PLATFORM_TF/network-handover.auto.tfvars"
  [[ "$OUT" -ef "$TARGET" ]] || cp "$OUT" "$TARGET"
  log "hand-over placed at $TARGET"

  for root in shared chain app; do
    [[ -d "$PLATFORM_TF/$root" ]] || continue
    ln -sfn ../network-handover.auto.tfvars "$PLATFORM_TF/$root/network-handover.auto.tfvars"
    log "  linked -> $root/"
  done
else
  log "SUCCESS. Copy to the platform project:"
  log "  cp $OUT <path>/sbsa_besu/terraform/network-handover.auto.tfvars"
  log "  then symlink it into each root: shared/ chain/ app/"
  exit 0
fi

log "SUCCESS."

#!/usr/bin/env bash
# =============================================================================
# emit-handover.sh — render the egress hand-over for the platform.
# -----------------------------------------------------------------------------
# Writes `egress-handover.auto.tfvars`: the CLIENT CONFIGURATION the bank's
# ticket reply would contain (R-10) and nothing else — a hostname, a port, a
# routed prefix, the allowlisted source, the permitted destinations. The
# platform (`sbsa_besu`) drops it in beside `network-handover.auto.tfvars`.
#
# In production this file is typed BY HAND from the cloud team's reply. Its
# shape is the contract; regenerate it rather than editing it.
#
# Usage:  scripts/emit-handover.sh [output-path]
#         (default: ../egress-handover.auto.tfvars, then copy it to
#          sbsa_besu/terraform/)
# =============================================================================
set -euo pipefail

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
OUT="${1:-$TF_DIR/../egress-handover.auto.tfvars}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required."
cd "$TF_DIR"
terraform output -json >/dev/null 2>&1 || die "no Terraform outputs — apply first."

log "rendering egress hand-over -> $OUT"

# ATOMIC WRITE (build finding B19, same shape as mimic_vpc): render into a temp
# file with every output read checked, prove it, then move it into place — a
# heredoc redirect truncates the target before its substitutions run, so a
# failed read would otherwise leave a 0-byte file and a stale copy downstream.
TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
s() { local v; v="$(terraform output -raw "$1" 2>/dev/null)" || die "terraform output -raw $1 failed — state unreadable? (credentials expired / wrong backend?)"; [ -n "$v" ] || die "output $1 is empty"; printf '%s' "$v"; }
o() { local v; v="$(terraform output -json 2>/dev/null | jq -er ".$1.value | tojson")" || die "terraform output $1 (json) failed"; printf '%s' "$v"; }

cat > "$TMP" <<TFVARS
# =============================================================================
# egress-handover.auto.tfvars   — GENERATED, DO NOT EDIT BY HAND
# -----------------------------------------------------------------------------
# Emitted by mimic_egress/scripts/emit-handover.sh at $TS
#
# In production this file is assembled BY HAND from the cloud team's reply to
# the R-10 egress ticket. Its shape is the contract; regenerate it rather than
# editing it. Only CLIENT CONFIGURATION appears here — nothing about how the
# egress service is built.
#
# Decision references: sbsa_besu/docs/CICD_DESIGN_NOTES.md CD-56..CD-60.
# =============================================================================

# The proxy, as the Tentacle addresses it (polling-proxy ONLY — never a
# host-wide HTTP(S)_PROXY, CD-57).
egress_proxy_host = "$(s egress_proxy_host)"
egress_proxy_port = $(s egress_proxy_port)

# The prefix the LEDGER route tables now route to the egress service. No H6
# NetworkPolicy allow-rule may name it (CD-60).
egress_vpc_cidr = "$(s egress_vpc_cidr)"

# The single allowlisted SOURCE. The runner MUST launch with this address — the
# runner root uses it as the default for runner_private_ip (CD-60).
egress_allowed_source = "$(s egress_allowed_source)"

# The permitted destinations, CONNECT to 443 only (CD-59). Informational.
egress_allowed_destinations = $(o egress_allowed_destinations)
TFVARS

[ -s "$TMP" ] || die "rendered hand-over is EMPTY — refusing to replace $OUT"
grep -Eq '^egress_proxy_host += +"[^"]+"' "$TMP" || die "rendered hand-over has no egress_proxy_host — refusing to replace $OUT"
grep -Eq '^egress_allowed_source += +"[0-9.]+/32"' "$TMP" || die "rendered hand-over has no /32 egress_allowed_source — refusing to replace $OUT"
mv -f "$TMP" "$OUT" && chmod 0644 "$OUT"
trap - EXIT
log "rendered $(wc -c < "$OUT") bytes; proxy=$(grep -E '^egress_proxy_host' "$OUT" | cut -d'"' -f2) source=$(grep -E '^egress_allowed_source' "$OUT" | cut -d'"' -f2)"

# -----------------------------------------------------------------------------
# Wire the platform's runner root, if the platform is checked out beside us —
# the same convenience mimic_vpc's emit-handover.sh provides for the network
# file. The symlink is gitignored (*.auto.tfvars), so recreate it every time.
# -----------------------------------------------------------------------------
PLATFORM_TF="$(cd "$TF_DIR/../../sbsa_besu/terraform" 2>/dev/null && pwd || true)"
if [[ -n "$PLATFORM_TF" && -d "$PLATFORM_TF" ]]; then
  TARGET="$PLATFORM_TF/egress-handover.auto.tfvars"
  [[ "$OUT" -ef "$TARGET" ]] || cp "$OUT" "$TARGET"
  log "hand-over placed at $TARGET"
  if [[ -d "$PLATFORM_TF/runner" ]]; then
    ln -sfn ../egress-handover.auto.tfvars "$PLATFORM_TF/runner/egress-handover.auto.tfvars"
    log "  linked -> runner/"
  fi
  log "next: push it to the runner with sbsa_besu/scripts/runner/push-deploy-config.sh (it rides in the deploy-config bundle)."
else
  log "SUCCESS. Copy to the platform project:"
  log "  cp $OUT <path>/sbsa_besu/terraform/egress-handover.auto.tfvars"
  log "  then: ln -s ../egress-handover.auto.tfvars <path>/sbsa_besu/terraform/runner/"
fi
log "SUCCESS."

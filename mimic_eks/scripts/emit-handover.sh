#!/usr/bin/env bash
# =============================================================================
# emit-handover.sh — render the CLUSTER hand-over for the platform.
# -----------------------------------------------------------------------------
# Writes `eks-handover.auto.tfvars`: the facts the cloud team would report about
# the shared cluster and the namespace they allotted us, and nothing else. The
# platform (`sbsa_besu`) drops it in beside network-handover.auto.tfvars.
#
# In production this file is typed BY HAND from the four command outputs in
# sbsa_besu/docs/CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md §4. Its shape is the
# contract (sbsa_besu/terraform/contract/eks-handover.tf); regenerate it rather
# than editing it.
#
# IT ALSO WRITES THE DELIBERATE-DEFECT LIST AS A COMMENT.
#   The default profile is "hostile" and the platform is SUPPOSED to fail
#   against it. Without that list in the file, an operator spends an hour
#   debugging a fixture. With it, the first line of the hand-over says which
#   gate should fire and why.
#
# Usage:  scripts/emit-handover.sh [output-path]
#         (default: ../eks-handover.auto.tfvars, then copied to sbsa_besu/terraform/)
# =============================================================================
set -euo pipefail

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
OUT="${1:-$TF_DIR/../eks-handover.auto.tfvars}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required."
cd "$TF_DIR"
terraform output -json >/dev/null 2>&1 || die "no Terraform outputs — apply first."

# ATOMIC WRITE (build finding B19, same shape as the other two mimics): render
# into a temp file with every output read CHECKED, prove it, then move it into
# place. A heredoc redirect truncates the target before its substitutions run,
# so a failed read would leave a 0-byte file and a stale copy downstream.
TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
s() { local v; v="$(terraform output -raw "$1" 2>/dev/null)" || die "terraform output -raw $1 failed — state unreadable? (credentials expired / wrong backend?)"; [ -n "$v" ] || die "output $1 is empty"; printf '%s' "$v"; }
b() { local v; v="$(terraform output -raw "$1" 2>/dev/null)" || die "terraform output -raw $1 failed"; printf '%s' "$v"; }   # booleans may be "false"
o() { local v; v="$(terraform output -json 2>/dev/null | jq -er ".$1.value | tojson")" || die "terraform output $1 (json) failed"; printf '%s' "$v"; }

PROFILE="$(s profile)"
log "rendering cluster hand-over (profile=$PROFILE) -> $OUT"

{
  cat <<TFVARS
# =============================================================================
# eks-handover.auto.tfvars   — GENERATED, DO NOT EDIT BY HAND
# -----------------------------------------------------------------------------
# Emitted by mimic_eks/scripts/emit-handover.sh at $TS
# Fidelity profile: $PROFILE
#
# In production this file is assembled BY HAND from the four command outputs in
# docs/CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md §4. Its shape is the contract —
# terraform/contract/eks-handover.tf. Regenerate rather than edit.
#
# Decision references: docs/CLOUD_TEAM_REDESIGN_NOTES.md §12 (D-23..D-43).
# =============================================================================
TFVARS

  if [[ "$PROFILE" == "hostile" ]]; then
    cat <<'WARNHDR'
#
# ##########################################################################
# ## THIS CLUSTER IS DELIBERATELY BROKEN. THE PLATFORM SHOULD FAIL.       ##
# ##########################################################################
#
# Profile "hostile" exists because a gate that has only ever been seen to pass
# is an assumption wearing a check's clothing (B12, §12.13.4). The defects
# below are intentional, with the gate each should trip. If the platform does
# NOT fail on one of them, THAT is the finding — do not fix the fixture.
#
# Deliberate defects:
WARNHDR
    terraform output -json 2>/dev/null | jq -r '.deliberate_defects.value[] | "#   - " + .'
    echo "#"
    echo "# For a deployable cluster: -var profile=strict"
    echo "#"
  fi

  cat <<TFVARS

# --- identity ----------------------------------------------------------------
cluster_name     = "$(s cluster_name)"
cluster_endpoint = "$(s cluster_endpoint)"
cluster_ca_data  = "$(s cluster_ca_data)"
cluster_version  = "$(s cluster_version)"
cluster_region   = "$(s region)"

# --- pod identity (#31) ------------------------------------------------------
# This mimic always uses IRSA. To exercise the Pod Identity branch, set
# pod_identity = true and clear oidc_provider_arn BY HAND — and remember it
# makes the eks-auth VPC endpoint required (verify-endpoints.sh --pod-identity).
oidc_provider_arn = "$(s oidc_provider_arn)"
oidc_issuer_url   = "$(s oidc_issuer_url)"
pod_identity      = false

# --- namespaces (#27) --------------------------------------------------------
namespace_ledger = "$(s namespace_ledger)"
namespace_app    = "$(s namespace_app)"
psa_level        = "$(s psa_level)"

# --- storage (#30) -----------------------------------------------------------
storage_class_name        = "$(s storage_class_name)"
storage_class_kms_key_arn = "$(b storage_class_kms_key_arn)"

# --- cluster-scoped add-ons (#30 / D-24) -------------------------------------
cluster_provides_lbc                 = $(b provides_lbc)
cluster_provides_secrets_store_csi   = $(b provides_secrets_store_csi)
cluster_provides_prometheus_operator = $(b provides_prometheus_operator)
cluster_provides_log_shipping        = $(b provides_log_shipping)

# --- node placement (#28, #33, #38) ------------------------------------------
node_group_dedicated = $(b node_group_dedicated)
node_taint           = "$(b node_taint)"
node_label           = "$(b node_label)"
node_sg_id           = "$(s node_sg_id)"
node_role_arn        = "$(s node_role_arn)"

cluster_node_subnet_ids = $(o node_subnet_ids)
cluster_lb_subnet_ids   = $(o lb_subnet_ids)

# --- enforcement and access (#35, #32) ---------------------------------------
network_policy_enforced     = $(b network_policy_enforced)
runner_access_entry_created = $(b runner_access_entry_created)
TFVARS
} > "$TMP"

[ -s "$TMP" ] || die "rendered hand-over is EMPTY — refusing to replace $OUT"
grep -Eq '^cluster_name += +"[^"]+"' "$TMP" || die "rendered hand-over has no cluster_name — refusing to replace $OUT"
grep -Eq '^node_role_arn += +"arn:aws' "$TMP" || die "rendered hand-over has no node role ARN (#38 needs it) — refusing to replace $OUT"
mv -f "$TMP" "$OUT" && chmod 0644 "$OUT"
trap - EXIT
log "rendered $(wc -c < "$OUT") bytes"

# -----------------------------------------------------------------------------
# Place it beside the platform's other hand-overs, if the platform is checked
# out as a sibling — the same convenience the other two mimics provide.
# -----------------------------------------------------------------------------
PLATFORM_TF="$(cd "$TF_DIR/../../sbsa_besu/terraform" 2>/dev/null && pwd || true)"
if [[ -n "$PLATFORM_TF" && -d "$PLATFORM_TF" ]]; then
  TARGET="$PLATFORM_TF/eks-handover.auto.tfvars"
  [[ "$OUT" -ef "$TARGET" ]] || cp "$OUT" "$TARGET"
  log "hand-over placed at $TARGET"
  log ""
  log "NOTE: contract/eks-handover.tf is NOT symlinked into the roots yet — the"
  log "      network hand-over still declares lb_subnet_ids and friends, so an"
  log "      unprefixed duplicate would fail the plan (see that file's header)."
  log "      Until cutover, pass these to modules/cluster-contract directly."
else
  log "SUCCESS. Copy to the platform project:"
  log "  cp $OUT <path>/sbsa_besu/terraform/eks-handover.auto.tfvars"
fi
log "next: apply the namespace the cloud team would have created —"
log "  scripts/apply-tenancy.sh     (FROM THE RUNNER: the API endpoint is private in strict)"
log "SUCCESS."

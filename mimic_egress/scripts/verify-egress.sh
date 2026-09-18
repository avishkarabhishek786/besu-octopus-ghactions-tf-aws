#!/usr/bin/env bash
# =============================================================================
# verify-egress.sh — prove the egress service behaves like the allowlist says.
# -----------------------------------------------------------------------------
# Runs the platform's own probe script ON THE RUNNER over SSM (it is the only
# permitted source, so nothing else can run the allow-path probes), then runs
# the deny-from-another-source probe from the proxy host itself.
#
# The probe script lives in sbsa_besu (scripts/preflight/verify-egress-proxy.sh)
# because it is the platform's DAY-ONE check against the BANK's proxy too — this
# wrapper just feeds it the mimic's values and a fingerprint baseline taken from
# the laptop (no proxy), so probe 7 can detect TLS interception (CD-58).
# Probe 8 (deny-from-another-source) runs on the proxy host DIRECT to Squid, not
# through the VIP — see the B23 note at the probe.
#
# Usage:  scripts/verify-egress.sh [--runner <instance-id>] [--sbsa-besu <dir>]
#   defaults: runner id from sbsa_besu/terraform/runner outputs;
#             sbsa_besu dir = ../sbsa_besu
# =============================================================================
set -euo pipefail

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v jq >/dev/null || die "jq is required."
command -v openssl >/dev/null || die "openssl is required."
command -v aws >/dev/null || die "aws CLI is required."

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$HERE/terraform"
SBSA="$(cd "$HERE/../sbsa_besu" 2>/dev/null && pwd || true)"
RUNNER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --runner)    RUNNER="$2"; shift ;;
    --sbsa-besu) SBSA="$(cd "$2" && pwd)"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

cd "$TF_DIR"
terraform output -json >/dev/null 2>&1 || die "no Terraform outputs in mimic_egress — apply first."
REGION="$(terraform output -raw region)"
PROXY_HOST="$(terraform output -raw egress_proxy_host)"
PROXY_PORT="$(terraform output -raw egress_proxy_port)"
PROXY_INSTANCE="$(terraform output -raw proxy_instance_id)"
INSTANCE="$(terraform output -json egress_allowed_destinations | jq -r '.[0]' | sed 's/\.octopus\.app$//')"
[ -n "$INSTANCE" ] || die "could not derive the Octopus instance from egress_allowed_destinations."

if [ -z "$RUNNER" ]; then
  [ -n "$SBSA" ] || die "sbsa_besu directory not found; pass --sbsa-besu <dir> or --runner <instance-id>."
  RUNNER="$(terraform -chdir="$SBSA/terraform/runner" output -raw runner_instance_id 2>/dev/null || true)"
  [ -n "$RUNNER" ] || die "runner_instance_id not in sbsa_besu/terraform/runner outputs — apply the runner root, or pass --runner."
fi

A=(aws --region "$REGION")

# -----------------------------------------------------------------------------
# Baseline: the polling endpoint's certificate as seen WITHOUT any proxy. Probe 7
# on the runner must see the identical fingerprint through the proxy; a
# difference means the tunnel was terminated and re-signed (CD-58).
# -----------------------------------------------------------------------------
head_ "baseline (laptop, no proxy): polling.${INSTANCE}.octopus.app certificate"
BASELINE="$(openssl s_client -connect "polling.${INSTANCE}.octopus.app:443" -servername "polling.${INSTANCE}.octopus.app" </dev/null 2>/dev/null \
  | openssl x509 -fingerprint -sha256 -noout 2>/dev/null | sed 's/^.*=//' || true)"
[ -n "$BASELINE" ] || die "could not fetch the polling endpoint's certificate from the laptop. Is '${INSTANCE}' a real Octopus Cloud instance?"
log "sha256 fingerprint: $BASELINE"

# -----------------------------------------------------------------------------
# Run a command on an instance over SSM and stream back its output.
# -----------------------------------------------------------------------------
ssm_run() { # <instance-id> <label> <command...>
  local id="$1" label="$2"; shift 2
  local cmd_json cid status
  cmd_json="$(jq -cn --arg c "$*" '{commands: [$c]}')"
  cid="$("${A[@]}" ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
        --comment "$label" --parameters "$cmd_json" --query Command.CommandId --output text)"
  for _ in $(seq 1 60); do
    status="$("${A[@]}" ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query Status --output text 2>/dev/null || echo Pending)"
    case "$status" in Success|Failed|Cancelled|TimedOut) break ;; esac
    sleep 3
  done
  "${A[@]}" ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query StandardOutputContent --output text
  "${A[@]}" ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query StandardErrorContent --output text >&2
  [ "$status" = "Success" ]
}

# -----------------------------------------------------------------------------
# Probes 1-7: from the runner (the allowed source).
# -----------------------------------------------------------------------------
head_ "probes 1-7 on the runner ${RUNNER} (the allowlisted source)"
PROBE=/opt/besu-deploy/sbsa_besu/scripts/preflight/verify-egress-proxy.sh
RC=0
ssm_run "$RUNNER" "mimic_egress verify 1-7" \
  "EGRESS_PROXY_HOST='${PROXY_HOST}' EGRESS_PROXY_PORT='${PROXY_PORT}' OCTOPUS_INSTANCE='${INSTANCE}' EXPECTED_POLLING_CERT_SHA256='${BASELINE}' bash ${PROBE}" \
  || RC=1

# -----------------------------------------------------------------------------
# Probe 8: from a NON-allowed source — the proxy host itself, DIRECT to Squid.
# It deliberately does NOT go through the VIP (B23): an NLB target cannot connect
# to itself through its own NLB when client-IP preservation is on — the packet
# arrives with source == destination == its own address and is dropped, so the
# CONNECT times out (000) and the probe would fail for a reason that has nothing
# to do with the ACL. Probes 2/3 already prove the VIP preserves the client IP
# (Squid saw the runner's /32, not the NLB, and allowed it); what is left to
# prove is that a different source address is refused, and Squid sees the same
# source ACL whether the request arrives via the VIP or directly.
# -----------------------------------------------------------------------------
head_ "probe 8 from the proxy host ${PROXY_INSTANCE} (NOT an allowed source; direct to Squid — B23)"
ssm_run "$PROXY_INSTANCE" "mimic_egress verify 8" \
  "me=\$(hostname -I | awk '{print \$1}'); con=\$(curl -sS -m 15 -x http://\$me:${PROXY_PORT} -o /dev/null -w '%{http_connect}' https://${INSTANCE}.octopus.app/api 2>/dev/null || true); if [ \"\$con\" = 403 ]; then echo \"  PASS  8  another source (\$me) is refused (CONNECT 403) — source ACL holds\"; else echo \"  FAIL  8  expected CONNECT 403 from non-allowed source \$me, got connect=\${con:-000}\"; exit 1; fi" \
  || RC=1

echo
if [ $RC -eq 0 ]; then log "ALL PROBES PASSED — the egress service behaves as the allowlist says."; else die "one or more probes FAILED — see above."; fi

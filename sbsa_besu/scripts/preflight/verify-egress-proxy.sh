#!/usr/bin/env bash
# =============================================================================
# verify-egress-proxy.sh — can this host reach Octopus Cloud through the bank's
# egress proxy, and ONLY Octopus Cloud, and WITHOUT the tunnel being opened?
# -----------------------------------------------------------------------------
# RUNS ON THE RUNNER (it is the allowlisted source). Read-only. Needs only curl
# and openssl, both in the AL2023 base AMI. Costs nothing. Run it:
#   * on DAY ONE against the bank's proxy, before any Tentacle registration
#   * from install-tentacle.sh, which refuses to register if this fails
#   * from mimic_egress/scripts/verify-egress.sh in a deploy-test
#
# WHAT EACH PROBE PROVES (CICD_DESIGN_NOTES CD-56..CD-60, §7.3)
#   1  the proxy hostname resolves here          -> corporate DNS / PHZ reaches this VPC
#   2  CONNECT to <instance>.octopus.app:443     -> the allow path, end to end
#   3  CONNECT to polling.<instance>...:443      -> the second hostname (Halibut over 443)
#   4  CONNECT to an unrelated host is refused   -> destination allowlist
#   5  plain HTTP through the proxy is refused   -> tunnels only
#   6  CONNECT to port 10943 is refused          -> 443 only
#   7  the certificate seen THROUGH the proxy == the one seen WITHOUT it
#                                                -> NO TLS INTERCEPTION (CD-58). Octopus's
#                                                   protocol needs an uninterrupted tunnel;
#                                                   a re-signed cert here means the Tentacle
#                                                   can never connect, so find out now.
#   (8 — refusal from another source — cannot be run from here; the mimic
#    wrapper runs it from the proxy host.)
#
# PROBE 7 NEEDS A BASELINE: EXPECTED_POLLING_CERT_SHA256, the polling endpoint's
# sha256 fingerprint taken from a network WITHOUT the proxy (your laptop):
#   openssl s_client -connect polling.<instance>.octopus.app:443 \
#     -servername polling.<instance>.octopus.app </dev/null 2>/dev/null \
#     | openssl x509 -fingerprint -sha256 -noout
# Without it probe 7 prints the fingerprint it saw and WARNs instead of passing.
#
# Inputs (env):  EGRESS_PROXY_HOST  EGRESS_PROXY_PORT  OCTOPUS_INSTANCE
#                EXPECTED_POLLING_CERT_SHA256 (optional)   PROBE_TIMEOUT (default 15s)
# Exit: 0 = all probes passed; 1 = at least one FAIL.
# =============================================================================
set -euo pipefail

: "${EGRESS_PROXY_HOST:?set EGRESS_PROXY_HOST (from egress-handover.auto.tfvars: egress_proxy_host)}"
: "${EGRESS_PROXY_PORT:?set EGRESS_PROXY_PORT (egress_proxy_port)}"
: "${OCTOPUS_INSTANCE:?set OCTOPUS_INSTANCE (the <instance> in https://<instance>.octopus.app)}"
: "${EXPECTED_POLLING_CERT_SHA256:=}"
: "${PROBE_TIMEOUT:=15}"

for t in curl openssl getent; do command -v "$t" >/dev/null 2>&1 || { echo "required tool not found: $t" >&2; exit 2; }; done

PASS=0; FAIL=0; WARN=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  WARN  %s\n' "$*"; WARN=$((WARN+1)); }

PROXY="http://${EGRESS_PROXY_HOST}:${EGRESS_PROXY_PORT}"
REST="${OCTOPUS_INSTANCE}.octopus.app"
POLL="polling.${OCTOPUS_INSTANCE}.octopus.app"

# via_proxy <url> -> "<connect> <code>": the proxy's answer to CONNECT and the
# end server's HTTP status. TWO numbers, because curl reports a REFUSED CONNECT
# as http_code=000 — the proxy's 403 lives in %{http_connect} (build finding
# B20: a single %{http_code} scored allow and deny alike). For a plain http://
# URL there is no CONNECT, so connect=000 and code is the proxy's own answer.
#   allowed https  -> "200 <octopus status>"      refused https -> "403 000"
#   no connection  -> "000 000"                    plain http    -> "000 <proxy status>"
via_proxy() { curl -sS -m "$PROBE_TIMEOUT" -x "$PROXY" -o /dev/null -w '%{http_connect} %{http_code}' "$1" 2>/dev/null || true; }

printf '\n=== egress proxy verification: %s -> %s / %s ===\n' "$PROXY" "$REST" "$POLL"

# 1 -- name resolution
if getent hosts "$EGRESS_PROXY_HOST" >/dev/null 2>&1; then
  ok "1  ${EGRESS_PROXY_HOST} resolves to $(getent hosts "$EGRESS_PROXY_HOST" | awk '{print $1}' | paste -sd, -)"
else
  bad "1  ${EGRESS_PROXY_HOST} does not resolve here — the proxy name is not reachable from this VPC (corporate DNS / private zone not associated?)"
fi

# 2 -- REST hostname, allow
read -r con code <<<"$(via_proxy "https://${REST}/api")"
case "${con:-000}" in
  200) ok "2  CONNECT ${REST}:443 accepted; Octopus answered HTTP ${code} (allowed, tunnel works)" ;;
  403) bad "2  proxy refused CONNECT ${REST}:443 (403) — this host is not the allowlisted source, or the destination is missing from the allowlist" ;;
  000) bad "2  no connection through ${PROXY} — route to the egress prefix missing, wrong port, or the proxy is down" ;;
  *)   bad "2  unexpected CONNECT response ${con} for ${REST}" ;;
esac

# 3 -- polling hostname, allow
read -r con code <<<"$(via_proxy "https://${POLL}/")"
case "${con:-000}" in
  200) ok "3  CONNECT ${POLL}:443 accepted (HTTP ${code} from the polling endpoint — any status is fine)" ;;
  403) bad "3  proxy refused CONNECT ${POLL}:443 (403) — the SECOND hostname is missing from the allowlist (CD-59)" ;;
  000) bad "3  no connection to ${POLL} through the proxy" ;;
  *)   bad "3  unexpected CONNECT response ${con} for ${POLL}" ;;
esac

# 4 -- unrelated destination, deny
read -r con code <<<"$(via_proxy "https://example.com/")"
[ "${con:-000}" = "403" ] && ok "4  CONNECT example.com:443 refused (403) — destination allowlist holds" \
                          || bad "4  expected the proxy to refuse example.com's CONNECT with 403, got connect=${con:-000} — the allowlist is wider than two hostnames"

# 5 -- plain HTTP, deny (tunnels only). No CONNECT here: the proxy's own status is the code.
read -r con code <<<"$(via_proxy "http://${REST}/")"
[ "${code:-000}" = "403" ] && ok "5  plain HTTP to ${REST} refused (403) — tunnels only" \
                           || warn "5  plain HTTP to ${REST} returned ${code:-000} — the proxy forwards non-CONNECT requests. The Tentacle does not need that; ask for CONNECT-only if the bank's policy allows"

# 6 -- non-443 port, deny
read -r con code <<<"$(via_proxy "https://${REST}:10943/")"
[ "${con:-000}" = "403" ] && ok "6  CONNECT ${REST}:10943 refused (403) — 443 only" \
                          || warn "6  CONNECT to 10943 returned connect=${con:-000} — the proxy allows non-443 tunnels. Harmless for us (we use 443) but wider than asked"

# 7 -- no TLS interception
SEEN="$(openssl s_client -proxy "${EGRESS_PROXY_HOST}:${EGRESS_PROXY_PORT}" -connect "${POLL}:443" -servername "$POLL" </dev/null 2>/dev/null \
        | openssl x509 -fingerprint -sha256 -noout 2>/dev/null | sed 's/^.*=//' || true)"
if [ -z "$SEEN" ]; then
  bad "7  could not complete a TLS handshake with ${POLL} through the proxy"
elif [ -z "$EXPECTED_POLLING_CERT_SHA256" ]; then
  warn "7  certificate seen through the proxy: ${SEEN}. No baseline given — compare it to the fingerprint from a network WITHOUT the proxy (see header). Equal = no interception."
elif [ "$SEEN" = "$EXPECTED_POLLING_CERT_SHA256" ]; then
  ok "7  certificate through the proxy == baseline (${SEEN}) — NO TLS interception; the Tentacle's pinned tunnel will hold (CD-58)"
else
  bad "7  certificate THROUGH the proxy (${SEEN}) != baseline (${EXPECTED_POLLING_CERT_SHA256}) — the proxy is DECRYPTING. Octopus rejects this ('requires an uninterrupted TLS tunnel'). Ask for a no-decrypt exception for both hostnames (R-10 item 4) before registering anything."
fi

printf '\n%d passed, %d warnings, %d failed\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ]

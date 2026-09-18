#!/usr/bin/env bash
# =============================================================================
# scripts/pki/issue-app-rpc-cert.sh  (Stage 8 — app-rpc pool)
# -----------------------------------------------------------------------------
# Issues the app-rpc SERVER-TLS keystore and stores it in Secrets Manager so the
# app-rpc Besu pods can mount it. RUN THIS BEFORE deploying the app-rpc pool with
# app_rpc_tls_enabled=true (else the pods start with an empty keystore and
# crashloop — same failure mode as the SWIFT pool).
#
# DIFFERENT from the SWIFT pool (issue-server-cert.sh):
#   * SERVER-TLS ONLY — no truststore, because the app plane uses
#     client-auth=false (server-TLS + JWT, NO client-cert mTLS; dossier §3).
#   * The JWT material is NOT issued here — app/scripts/gen-app-identity.sh
#     --push-secrets writes besu-node-apprpc-jwt-pubkey + besu-apprpc-jwt-signing-key.
#
# It produces and stores:
#   besu-node-apprpc-keystore   base64 PKCS12 (app-rpc server cert+key, CA-signed)
#
# The cert's SAN MUST match the host the app connects to. The app uses the
# stable name rpc.<private_dns_zone> (default rpc.chain.internal) for
# BOTH https (HTTP RPC) and wss (WS) — so one SAN covers both ports. Add extra
# SANs (e.g. the app-rpc NLB DNS) via APP_RPC_EXTRA_SANS (comma-separated).
#
# Reads the CA (besu-ca-private-key, besu-node-ca-cert) and the app-rpc keystore
# password (besu-node-apprpc-keystore-password, Terraform-generated). Run from
# the in-VPC runner (or any host with Secrets Manager perms + openssl). Idempotent:
# re-running rotates the cert (roll the app-rpc pods after).
#
# Usage:
#   AWS_REGION=us-east-1 [APP_RPC_HOSTNAME=rpc.chain.internal] \
#     [APP_RPC_EXTRA_SANS=my-nlb.elb.amazonaws.com] \
#     scripts/pki/issue-app-rpc-cert.sh
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

: "${APP_RPC_HOSTNAME:=rpc.chain.internal}" # the name the app's https/wss URLs use
need openssl; need aws; need base64

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

log "fetching CA + app-rpc keystore password from Secrets Manager"
sm_get besu-ca-private-key > ca.key
sm_get besu-node-ca-cert   > ca.crt
[ -s ca.key ] || die "besu-ca-private-key is empty — is the CA bootstrapped (stage 2)?"
KS_PASS="$(sm_get besu-node-apprpc-keystore-password)"
[ -n "$KS_PASS" ] || die "besu-node-apprpc-keystore-password missing — apply the chain (secrets module) first"

log "generating app-rpc server key + CSR (CN=${APP_RPC_HOSTNAME})"
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=${APP_RPC_HOSTNAME}/O=Besu app-rpc"

# Build the SAN list: the primary hostname + any extras (comma-separated).
SAN_LINE="DNS:${APP_RPC_HOSTNAME}"
if [ -n "${APP_RPC_EXTRA_SANS:-}" ]; then
  IFS=',' read -ra _extra <<< "${APP_RPC_EXTRA_SANS}"
  for s in "${_extra[@]}"; do
    s="$(echo "$s" | xargs)" # trim
    [ -n "$s" ] && SAN_LINE="${SAN_LINE},DNS:${s}"
  done
fi

log "signing app-rpc server cert with the CA (SAN=${SAN_LINE}, 825-day, serverAuth)"
cat > ext.cnf <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${SAN_LINE}
EOF
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 825 -sha256 -extfile ext.cnf -out server.crt

log "building PKCS12 keystore (server cert+key + CA chain) — server-TLS only, NO truststore"
openssl pkcs12 -export -name apprpc-server -inkey server.key -in server.crt -certfile ca.crt \
  -out keystore.p12 -password "pass:${KS_PASS}"

log "storing besu-node-apprpc-keystore in Secrets Manager"
sm_put besu-node-apprpc-keystore "$(base64 -w0 keystore.p12)"

ok "app-rpc server keystore issued (SAN ${SAN_LINE})."
ok "If the app-rpc pods are already running, roll them: kubectl -n besu delete pod -l besu.role=app-rpc"
log "Reminder: also run app/scripts/gen-app-identity.sh --push-secrets for the JWT keypair."

#!/usr/bin/env bash
# =============================================================================
# scripts/access/sign-client-csr.sh
# -----------------------------------------------------------------------------
# CSR-SIGNING flow (the DEFAULT per the settled design): SWIFT generates its own
# key + CSR and keeps the private key; we sign the CSR with our CA to produce a
# client certificate SWIFT presents for mTLS. The private key NEVER leaves SWIFT.
#
# Usage:
#   AWS_REGION=us-east-1 scripts/access/sign-client-csr.sh <client.csr> [days] [out.crt]
#
# Output: a signed client cert (clientAuth EKU). Hand <out.crt> + the CA cert
# back to SWIFT (see make-join-pack.sh). PKCS12 fallback (we generate the key)
# is intentionally NOT here — only do that if SWIFT cannot generate a CSR.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
need openssl; need aws

CSR="${1:?usage: sign-client-csr.sh <client.csr> [days] [out.crt]}"
DAYS="${2:-365}"
OUT="${3:-client.crt}"
[ -s "$CSR" ] || die "CSR not found/empty: $CSR"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
log "fetching CA"
sm_get besu-ca-private-key > "$WORK/ca.key"
sm_get besu-node-ca-cert   > "$WORK/ca.crt"
[ -s "$WORK/ca.key" ] || die "CA private key missing"

cat > "$WORK/ext.cnf" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
EOF

log "signing client CSR (${DAYS}d, clientAuth)"
openssl x509 -req -in "$CSR" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" -CAcreateserial \
  -days "$DAYS" -sha256 -extfile "$WORK/ext.cnf" -out "$OUT"
openssl x509 -in "$OUT" -noout -subject -dates
ok "signed client cert written: $OUT  (deliver with the CA cert via make-join-pack.sh)"

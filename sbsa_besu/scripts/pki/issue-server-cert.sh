#!/usr/bin/env bash
# =============================================================================
# scripts/pki/issue-server-cert.sh
# -----------------------------------------------------------------------------
# Issues the RPC SERVER mTLS material and the JWT key, storing them in Secrets
# Manager so the RPC pods can mount them. RUN THIS BEFORE deploying the RPC
# nodes with rpc_mtls_enabled=true (otherwise the pods start with an empty
# keystore and crashloop).
#
# It produces and stores:
#   besu-node-rpc-keystore      base64 PKCS12 (server cert+key, signed by our CA)
#   besu-node-rpc-truststore    base64 PKCS12 (the CA cert; verifies clients)
#   besu-node-rpc-jwt-pubkey    RSA public key  (Besu verifies SWIFT JWTs)
#   besu-rpc-jwt-signing-key    RSA private key (ops; mints SWIFT JWTs) [ops-only]
#
# Reads the CA from Secrets Manager (besu-ca-private-key, besu-node-ca-cert) and
# the keystore/truststore passwords (besu-node-tls-*-password). Run from the
# In-VPC EC2 Runner (or any host with the right Secrets Manager permissions + openssl
# + keytool). Idempotent: re-running rotates the server cert (roll RPC pods after).
#
# Usage:
#   AWS_REGION=us-east-1 RPC_HOSTNAME=rpc.nonprod.internal \
#     scripts/pki/issue-server-cert.sh
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

: "${RPC_HOSTNAME:?set RPC_HOSTNAME (the CN/SAN SWIFT connects to, e.g. rpc.nonprod.internal)}"
# keytool builds the truststore as a proper Java trustedCertEntry — an
# openssl -nokeys PKCS12 is NOT reliably usable as a Java trust anchor, so Besu
# throws a TLS internal error during client-cert validation. keytool ships with
# any JRE (the runner installs java-headless via user-data).
need openssl; need keytool; need aws; need base64

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

log "fetching CA + passwords from Secrets Manager"
sm_get besu-ca-private-key > ca.key
sm_get besu-node-ca-cert   > ca.crt
[ -s ca.key ] || die "besu-ca-private-key is empty — is the CA bootstrapped (stage 2)?"
KS_PASS="$(sm_get besu-node-tls-keystore-password)";   [ -n "$KS_PASS" ] || die "keystore password missing"
TS_PASS="$(sm_get besu-node-tls-truststore-password)"; [ -n "$TS_PASS" ] || die "truststore password missing"

log "generating server key + CSR (CN=${RPC_HOSTNAME})"
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=${RPC_HOSTNAME}/O=Besu RPC"

log "signing server cert with the CA (SAN=${RPC_HOSTNAME}, 825-day)"
cat > ext.cnf <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${RPC_HOSTNAME}
EOF
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 825 -sha256 -extfile ext.cnf -out server.crt

log "building PKCS12 keystore (server cert+key) and truststore (CA)"
openssl pkcs12 -export -name rpc-server -inkey server.key -in server.crt -certfile ca.crt \
  -out keystore.p12 -password "pass:${KS_PASS}"
# Truststore: a PKCS12 with the CA as a Java trustedCertEntry (keytool), so
# Besu can build the client-cert trust path. (openssl -nokeys is NOT reliable
# here — Java fails to treat its cert bag as a trust anchor.)
keytool -importcert -noprompt -alias rpc-ca -file ca.crt \
  -keystore truststore.p12 -storetype PKCS12 -storepass "${TS_PASS}"

log "generating JWT RSA keypair (method-scoping tokens)"
openssl genrsa -out jwt-private.pem 2048
openssl rsa -in jwt-private.pem -pubout -out jwt-public.pem

log "storing material in Secrets Manager"
sm_put besu-node-rpc-keystore   "$(base64 -w0 keystore.p12)"
sm_put besu-node-rpc-truststore "$(base64 -w0 truststore.p12)"
sm_put_file besu-node-rpc-jwt-pubkey   jwt-public.pem
sm_put_file besu-rpc-jwt-signing-key   jwt-private.pem

ok "RPC server mTLS material + JWT key issued. If RPC pods are already running, roll them: kubectl -n besu delete pod -l besu.role=rpc"

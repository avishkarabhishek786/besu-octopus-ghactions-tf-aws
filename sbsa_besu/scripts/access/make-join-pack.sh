#!/usr/bin/env bash
# =============================================================================
# scripts/access/make-join-pack.sh
# -----------------------------------------------------------------------------
# Builds the connection "join pack" handed to SWIFT to reach the RPC endpoint:
#   ca.crt          our CA cert (SWIFT trusts the server + we trust their client)
#   client.crt      SWIFT's CA-signed client cert (from sign-client-csr.sh)
#   endpoint.txt    host:port of the RPC NLB over SIPN
#   methods.txt     the permitted JSON-RPC methods
#   token.jwt       a method-scoped RS256 JWT (when tls-plus-method) signed by
#                   besu-rpc-jwt-signing-key; its `permissions` claim limits the
#                   methods Besu will serve for this client
#   README.txt      how to use it
#
# Usage:
#   AWS_REGION=us-east-1 RPC_HOSTNAME=rpc.nonprod.internal RPC_PORT=8545 \
#   METHODS="eth_call,eth_sendRawTransaction,eth_getLogs,eth_blockNumber,net_version,web3_clientVersion" \
#     scripts/access/make-join-pack.sh <client.crt> [out-dir]
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
need openssl; need aws; need base64

CLIENT_CRT="${1:?usage: make-join-pack.sh <client.crt> [out-dir]}"
OUT="${2:-join-pack}"
: "${RPC_HOSTNAME:?set RPC_HOSTNAME}"; : "${RPC_PORT:=8545}"
: "${METHODS:=eth_call,eth_sendRawTransaction,eth_getLogs,eth_blockNumber,net_version,web3_clientVersion}"
[ -s "$CLIENT_CRT" ] || die "client cert not found: $CLIENT_CRT"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

mkdir -p "$OUT"
log "assembling join pack in $OUT/"
sm_get besu-node-ca-cert > "$OUT/ca.crt"
cp "$CLIENT_CRT" "$OUT/client.crt"
echo "${RPC_HOSTNAME}:${RPC_PORT}" > "$OUT/endpoint.txt"
echo "$METHODS" | tr ',' '\n' > "$OUT/methods.txt"

# Mint a method-scoped RS256 JWT. Besu permission strings are method names with
# the first underscore as a colon (eth_blockNumber -> eth:blockNumber).
PERMS=$(echo "$METHODS" | tr ',' '\n' | sed 's/_/:/' | sed 's/.*/"&"/' | paste -sd, -)
SIGN_KEY="$(mktemp)"; trap 'rm -f "$SIGN_KEY"' EXIT
sm_get besu-rpc-jwt-signing-key > "$SIGN_KEY"
if [ -s "$SIGN_KEY" ]; then
  # H9: bound the token. Default TTL 90d (was a hardcoded ~1yr static bearer), and
  # add aud/jti/iat/nbf so tokens are auditable, revocable-by-jti, and time-bounded.
  # Shorten JWT_TTL_SECONDS further (and re-mint) for higher-assurance clients.
  : "${JWT_TTL_SECONDS:=7776000}" # 90 days
  : "${JWT_AUDIENCE:=besu-swift-rpc}"
  NOW=$(date +%s)
  JTI=$(openssl rand -hex 16)
  HDR=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  # nbf = NOW-60 for small clock-skew tolerance; exp = NOW + TTL.
  PAY=$(printf '{"permissions":[%s],"aud":"%s","jti":"%s","iat":%d,"nbf":%d,"exp":%d}' \
    "$PERMS" "$JWT_AUDIENCE" "$JTI" "$NOW" "$((NOW - 60))" "$((NOW + JWT_TTL_SECONDS))" | b64url)
  SIG=$(printf '%s.%s' "$HDR" "$PAY" | openssl dgst -sha256 -sign "$SIGN_KEY" | b64url)
  printf '%s.%s.%s' "$HDR" "$PAY" "$SIG" > "$OUT/token.jwt"
  ok "minted method-scoped JWT (permissions: $PERMS; jti=$JTI; ttl=$((JWT_TTL_SECONDS / 86400))d)"
else
  log "no JWT signing key (tls-only mode) — skipping token.jwt"
fi

cat > "$OUT/README.txt" <<EOF
Besu RPC connection pack
========================
Endpoint : $(cat "$OUT/endpoint.txt")   (reachable over SWIFT SIPN)
mTLS     : present client.crt + your PRIVATE key; trust ca.crt for the server.
Methods  : see methods.txt (other methods are rejected).
$( [ -f "$OUT/token.jwt" ] && echo "JWT      : send token.jwt as 'Authorization: Bearer <token>' (method scoping)." )

Example (curl):
  curl --cert client.crt --key client.key --cacert ca.crt \\
    $( [ -f "$OUT/token.jwt" ] && echo "-H \"Authorization: Bearer \$(cat token.jwt)\" \\" )
    -X POST -H 'Content-Type: application/json' \\
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \\
    https://$(cat "$OUT/endpoint.txt")
EOF

tar -czf "${OUT}.tgz" -C "$OUT" .
ok "join pack written: ${OUT}/ and ${OUT}.tgz  (deliver securely to SWIFT)"

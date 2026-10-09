#!/usr/bin/env bash
# =============================================================================
# scripts/permissioning/fund-account.sh
# -----------------------------------------------------------------------------
# Fund one or more accounts on the zero-gas chain by sending native value from an
# already-allowlisted, already-funded FAUCET account (backlog C6 / F20).
#
# WHY THIS EXISTS: genesis funding (genesis_funded_accounts / initial_account_
# allowlist) only fires at chain creation — it CANNOT reach an account added
# later. On this free-gas chain a ZERO-BALANCE sender's tx is never mined (F20),
# so a newly-allowlisted account still can't transact until it holds a balance.
# The only post-genesis way to fund it is an on-chain transfer from an account
# that is BOTH allowlisted AND funded (the admin, or any initial_account_allowlist
# member — each got a large genesis balance). This is that transfer.
#
# The transfer itself is FREE (gasPrice 0); the faucet just needs balance to cover
# the value it sends. Account permissioning gates the SENDER only, so the
# recipient need not be allowlisted to RECEIVE funds (allowlist + fund are
# independent steps, either order — see add-account.sh).
#
#   # by raw key, against an endpoint you can reach:
#   FAUCET_KEY=0x<faucetPrivKey> RPC_URL=http://127.0.0.1:8545 \
#     scripts/permissioning/fund-account.sh 0x<new> [0x<new2> ...]
#
#   # faucet key pulled from Secrets Manager, endpoint via an auto port-forward
#   # to a PLAIN-HTTP pool (explorer-rpc / an enabled validator ops listener):
#   FAUCET_KEY_SECRET=besu-faucet-key PF_STATEFULSET=besu-explorer-rpc-1 \
#     AMOUNT=5ether scripts/permissioning/fund-account.sh 0x<new>
#
# Env:
#   AMOUNT            value per recipient (cast units; default "1ether")
#   FAUCET_KEY        faucet private key (0x…)         ] provide exactly
#   FAUCET_KEY_SECRET Secrets Manager name holding it  ] ONE of these
#   RPC_URL           tx-capable JSON-RPC endpoint      ] provide exactly ONE:
#   PF_STATEFULSET    plain-HTTP STS to port-forward    ]  RPC_URL or PF_STATEFULSET
#   NAMESPACE         k8s namespace (default besu); AWS_REGION for the secret
#
# Needs `cast` (Foundry) on the runner: curl -L https://foundry.paradigm.xyz | bash && foundryup
# RUN FROM the In-VPC EC2 Runner (private EKS endpoint). See _perm-lib.sh header.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_perm-lib.sh"   # log/ok/err/die, need, valid_addr, cm_addrs, sm_get, NAMESPACE
need cast

AMOUNT="${AMOUNT:-1ether}"
[ "$#" -ge 1 ] || die "usage: fund-account.sh <0xrecipient> [<0xrecipient> ...]   (AMOUNT=${AMOUNT})"
for a in "$@"; do valid_addr "$a" || die "not a valid 20-byte hex address: $a"; done

# --- resolve the faucet key (never echoed) -----------------------------------
if [ -n "${FAUCET_KEY:-}" ] && [ -n "${FAUCET_KEY_SECRET:-}" ]; then
  die "set only ONE of FAUCET_KEY / FAUCET_KEY_SECRET"
elif [ -n "${FAUCET_KEY_SECRET:-}" ]; then
  FAUCET_KEY="$(sm_get "$FAUCET_KEY_SECRET")"
  [ -n "$FAUCET_KEY" ] && [ "$FAUCET_KEY" != "None" ] || die "secret '$FAUCET_KEY_SECRET' is empty/missing"
  log "faucet key loaded from Secrets Manager ($FAUCET_KEY_SECRET)"
elif [ -z "${FAUCET_KEY:-}" ]; then
  die "provide FAUCET_KEY=0x… or FAUCET_KEY_SECRET=<secret-name>"
fi
case "$FAUCET_KEY" in 0x*) : ;; *) FAUCET_KEY="0x${FAUCET_KEY}" ;; esac

# --- resolve the RPC endpoint (RPC_URL, or an auto port-forward) --------------
PF_PID=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
if [ -n "${RPC_URL:-}" ]; then
  log "using RPC_URL=$RPC_URL"
elif [ -n "${PF_STATEFULSET:-}" ]; then
  need kubectl
  LPORT=$(( 18545 + RANDOM % 2000 ))
  log "port-forwarding statefulset/${PF_STATEFULSET} ${LPORT}->8545 (plain HTTP)"
  kubectl -n "$NAMESPACE" port-forward "statefulset/${PF_STATEFULSET}" "${LPORT}:8545" >/dev/null 2>&1 &
  PF_PID=$!; sleep 3
  RPC_URL="http://127.0.0.1:${LPORT}"
else
  die "set RPC_URL=<tx-capable endpoint> or PF_STATEFULSET=<plain-HTTP sts, e.g. besu-explorer-rpc-1>. The SWIFT/app pools require mTLS/JWT — pass an RPC_URL you can reach for those."
fi

# --- sanity: endpoint reachable + faucet identity/balance --------------------
FAUCET_ADDR="$(cast wallet address --private-key "$FAUCET_KEY" 2>/dev/null || true)"
[ -n "$FAUCET_ADDR" ] || die "could not derive the faucet address from the key (bad key?)"
CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || true)"
[ -n "$CHAIN_ID" ] || die "RPC endpoint $RPC_URL not reachable / not answering eth_chainId"
FBAL="$(cast balance "$FAUCET_ADDR" --rpc-url "$RPC_URL" 2>/dev/null || echo 0)"
log "faucet ${FAUCET_ADDR} on chainId ${CHAIN_ID}; balance ${FBAL} wei"
[ "$FBAL" != "0" ] || die "faucet ${FAUCET_ADDR} has ZERO balance — it must be an allowlisted + genesis-funded account (admin or an initial_account_allowlist member)"

# --- warn if a recipient is not (yet) on the allowlist -----------------------
if kubectl -n "$NAMESPACE" get configmap "$CONFIGMAP" >/dev/null 2>&1; then
  ALLOW="$(cm_addrs | tr 'A-F' 'a-f')"
  for a in "$@"; do
    echo "$ALLOW" | grep -qi "$(printf '%s' "$a" | tr 'A-F' 'a-f')" \
      || err "NOTE: $a is NOT on the account allowlist yet — it can receive funds but cannot originate tx until you run add-account.sh"
  done
fi

# --- send ---------------------------------------------------------------------
# Zero-gas chain: legacy tx at gasPrice 0. cast send blocks until mined.
for a in "$@"; do
  log "funding ${a} with ${AMOUNT} from ${FAUCET_ADDR}"
  cast send "$a" --value "$AMOUNT" \
    --private-key "$FAUCET_KEY" --rpc-url "$RPC_URL" \
    --legacy --gas-price 0 >/dev/null \
    || die "transfer to ${a} failed (is the FAUCET allowlisted? is the chain producing?)"
  NBAL="$(cast balance "$a" --rpc-url "$RPC_URL" 2>/dev/null || echo 0)"
  ok "${a} funded — balance now ${NBAL} wei"
done
ok "fund-account complete ($# recipient(s), ${AMOUNT} each)"

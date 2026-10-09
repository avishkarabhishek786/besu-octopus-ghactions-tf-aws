#!/usr/bin/env bash
# =============================================================================
# verify-deployed.sh — the assertions that are only observable AFTER deploy
# -----------------------------------------------------------------------------
# READ-ONLY by default. The NetworkPolicy enforcement probe creates two
# short-lived pods and is therefore OPT-IN (--probe-netpol). Free either way.
# Run from the In-VPC EC2 Runner.
#
# WHY IT EXISTS
#   Four of the silent failures in CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md §3
#   cannot be detected before the workload is running, and three of those
#   LOOK LIKE SUCCESS. A preflight cannot catch them; only an assertion on the
#   deployed state can. (CLOUD_TEAM_REDESIGN_NOTES §12.13.2, class "D".)
#
# THE CENTRAL ONE  (#27 / D-36)
#   A ResourceQuota a few hundred millicores short admits THREE validators and
#   refuses the fourth. QBFT with N=3F+1 needs 2F+1 = 3 of 4, so the chain
#   starts, produces blocks, and every dashboard is green — while sitting ONE
#   failure away from a halt. The refusal is an event on the StatefulSet; there
#   is no fourth pod for anyone to notice the absence of.
#
#   Therefore: this script asserts a COUNT, never the absence of errors. Four
#   validators, Ready, on four DISTINCT nodes. Anything else is a failure, and
#   "three healthy validators" is the specific thing it exists to refuse.
#
# WHAT IT ASSERTS, AND THE REQUIREMENT EACH MAPS TO
#   #27/D-36  exactly N validators exist and are Ready  (default N=4)
#   #28/D-39  each validator is on a DISTINCT node
#   #31       a validator pod's AWS identity is OUR role, not the node role
#   #33       the RPC pods carry the pod-ENI annotation, when SGP is the route
#   #30/#33   the NLB target groups have healthy targets, not an empty list
#   #34 F-1   each validator's peer count is N-1
#   #27/D-36  the QBFT block-producing set contains N validators
#   #35/D-37  a connection NetworkPolicy forbids is actually refused (opt-in)
#
# Usage:
#   scripts/validation/verify-deployed.sh -n <namespace> [-N 4]
#       [-l besu.role=validator] [-R <role-arn-substring>]
#       [-r <rpc-url>] [-j <jwt>] [-g <target-group-arn>]... [--probe-netpol]
#
#   -r/-j  an endpoint exposing the QBFT and NET APIs. The validator ops
#          listener is JWT-authenticated (H6), so -j is normally required with
#          it. WITHOUT -r the chain-level assertions are SKIPPED AS WARNINGS,
#          never as passes — see the note at the end of this header.
#
# THE RULE THIS FILE IS WRITTEN UNDER
#   A check that cannot fail is worse than no check, because it is trusted
#   (CICD design notes 11.3). So anything this script could not evaluate is
#   reported WARN and counted, and the summary says so out loud. "We could not
#   look" must never render as PASS.
# =============================================================================
set -euo pipefail

NS=""; WANT=4; SELECTOR="besu.role=validator"; ROLE_HINT=""
RPC=""; JWT=""; PROBE_NETPOL=0; TGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NS="$2"; shift 2 ;;
    -N) WANT="$2"; shift 2 ;;
    -l) SELECTOR="$2"; shift 2 ;;
    -R) ROLE_HINT="$2"; shift 2 ;;
    -r) RPC="$2"; shift 2 ;;
    -j) JWT="$2"; shift 2 ;;
    -g) TGS+=("$2"); shift 2 ;;
    --probe-netpol) PROBE_NETPOL=1; shift ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$NS" ]] || { echo "usage: verify-deployed.sh -n <namespace> [-N 4] [...]" >&2; exit 2; }
command -v kubectl >/dev/null || { echo "kubectl is required" >&2; exit 1; }
command -v jq      >/dev/null || { echo "jq is required" >&2; exit 1; }

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; WARN=$((WARN+1)); }
sec()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '        %s\n' "$*"; }

printf '\n=== deployed-state assertions: %s (expecting %s validators) ===\n' "$NS" "$WANT"

# -----------------------------------------------------------------------------
# #27 / D-36 — the count, and the per-node spread (#28 / D-39)
# -----------------------------------------------------------------------------
sec "#27 (D-36)  validator count and readiness — the silent-success check"
PODS_JSON="$(kubectl -n "$NS" get pods -l "$SELECTOR" -o json 2>/dev/null || echo '{"items":[]}')"
N_TOTAL="$(jq '.items | length' <<<"$PODS_JSON")"
N_READY="$(jq '[.items[] | select((.status.conditions // [])[]? | select(.type=="Ready" and .status=="True"))] | length' <<<"$PODS_JSON")"

if [[ "$N_TOTAL" -eq "$WANT" && "$N_READY" -eq "$WANT" ]]; then
  ok "$N_READY/$WANT validators exist and are Ready"
elif [[ "$N_TOTAL" -lt "$WANT" ]]; then
  bad "#27 VIOLATED: only $N_TOTAL validator pods EXIST (want $WANT); $N_READY Ready"
  note "A MISSING pod is the quota case. Nothing reports it as a failure: QBFT's quorum is"
  note "3 of 4, so with 3 the chain produces blocks and looks healthy with ZERO fault"
  note "tolerance. Look for the refusal on the StatefulSet, not on a pod:"
  note "  kubectl -n $NS describe statefulset -l $SELECTOR | sed -n '/Events/,\$p'"
  note "  kubectl -n $NS get resourcequota -o yaml"
  note "Then quote shared-cluster requirements §1's footprint table to the cloud team (#27)."
else
  bad "#27: $N_TOTAL validator pods, $N_READY Ready (want $WANT Ready)"
  jq -r '.items[] | "        \(.metadata.name)  phase=\(.status.phase)  node=\(.spec.nodeName // "<unscheduled>")"' <<<"$PODS_JSON"
  note "A Pending validator is the DESIGNED failure of D-39 (required anti-affinity): fewer"
  note "schedulable nodes than validators. It is loud on purpose. Check node count and the"
  note "#28 taint/label, not the anti-affinity rule."
fi

sec "#28 (D-39)  one validator per node"
# `// empty` alone is not enough: it fires on null, not on "". An unscheduled pod
# normally has no nodeName key at all, but a "" would be counted as a distinct node
# and this check would report "4 validators on 4 distinct nodes" for 3 scheduled
# pods — a false PASS on the exact question being asked. Filter both.
NODESEL='[.items[].spec.nodeName // empty | select(. != "")]'
NODES="$(jq -r "$NODESEL | sort | join(\" \")" <<<"$PODS_JSON")"
N_NODES="$(jq -r "$NODESEL | unique | length" <<<"$PODS_JSON")"
N_SCHED="$(jq -r "$NODESEL | length" <<<"$PODS_JSON")"
if [[ "$N_SCHED" -eq 0 ]]; then
  warn "no validator pods are scheduled yet — nothing to assert"
elif [[ "$N_NODES" -eq "$N_SCHED" ]]; then
  ok "$N_SCHED validators on $N_NODES distinct nodes"
else
  bad "#28 VIOLATED: $N_SCHED validators on only $N_NODES distinct nodes — two share a node"
  note "nodes: $NODES"
  note "A single drain of the shared node removes 2 of 4 and the chain HALTS (H1). Nothing"
  note "reports this: four Running pods on three nodes looks exactly like four on four."
  note "The required podAntiAffinity (D-39) should have made this impossible — if it is"
  note "visibly violated, antiAffinity.requireDistinctNodes was set false somewhere."
fi

# -----------------------------------------------------------------------------
# #31 — which AWS principal do our pods actually run as?
# -----------------------------------------------------------------------------
sec "#31  pod AWS identity (IRSA / Pod Identity, not the node role)"
POD1="$(jq -r '[.items[] | select(.status.phase=="Running")][0].metadata.name // empty' <<<"$PODS_JSON")"
if [[ -z "$POD1" ]]; then
  warn "no Running validator to interrogate"
elif ! CALLER="$(kubectl -n "$NS" exec "$POD1" -c besu -- sh -lc \
        'aws sts get-caller-identity --query Arn --output text 2>/dev/null || true' 2>/dev/null | tr -d '\r')" \
     || [[ -z "$CALLER" ]]; then
  warn "#31: could not run 'aws sts get-caller-identity' inside $POD1 (no AWS CLI in the image?)"
  note "This assertion is the only one that catches the SILENT form of #31: with no credential"
  note "env injected, the SDK falls through to instance metadata and the pod runs as the CLOUD"
  note "TEAM'S NODE ROLE — which on a shared cluster may be BROADER than ours, so the call"
  note "SUCCEEDS with the wrong principal, in their CloudTrail. Not a pass; find another way:"
  note "  kubectl -n $NS get sa -o yaml | grep -A2 eks.amazonaws.com/role-arn   (IRSA)"
  note "  aws eks list-pod-identity-associations --cluster-name <c> --namespace $NS"
elif [[ -n "$ROLE_HINT" && "$CALLER" != *"$ROLE_HINT"* ]]; then
  bad "#31 VIOLATED: $POD1 is $CALLER — expected a role matching '$ROLE_HINT'"
  note "If that ARN is a NODE instance role, credentials fell back to instance metadata:"
  note "no IRSA annotation and no pod identity association for this service account."
else
  ok "$POD1 runs as $CALLER"
  [[ -n "$ROLE_HINT" ]] || note "pass -R <role-arn-substring> to make this an assertion rather than a report."
fi

# -----------------------------------------------------------------------------
# #33 — Security Groups for Pods, if that is the chosen route
# -----------------------------------------------------------------------------
sec "#33  pod-ENI annotation on the RPC pods (only if SGP is the route)"
if kubectl get crd securitygrouppolicies.vpcresources.k8s.aws >/dev/null 2>&1; then
  RPCPODS="$(kubectl -n "$NS" get pods -l 'besu.role in (rpc,app-rpc,explorer-rpc)' -o json 2>/dev/null || echo '{"items":[]}')"
  NRPC="$(jq '.items | length' <<<"$RPCPODS")"
  NENI="$(jq '[.items[] | select(.metadata.annotations["vpc.amazonaws.com/pod-eni"] != null)] | length' <<<"$RPCPODS")"
  if [[ "$NRPC" -eq 0 ]]; then
    warn "no RPC pods found to check"
  elif [[ "$NENI" -eq "$NRPC" ]]; then
    ok "$NENI/$NRPC RPC pods have a branch ENI — our security group is applied"
  else
    bad "#33 VIOLATED: only $NENI/$NRPC RPC pods carry vpc.amazonaws.com/pod-eni"
    note "They got an ordinary node ENI instead, so OUR security group is NOT applied — with"
    note "NO error anywhere. The SecurityGroupPolicy selector does not match these pods."
    note "  kubectl -n $NS get securitygrouppolicy -o yaml"
  fi
else
  note "no SecurityGroupPolicy CRD — #33 must be satisfied by an ingress rule on THEIR node SG."
  note "That one is only observable through target health, below."
fi

# -----------------------------------------------------------------------------
# #30 / #33 — did anything actually register into the target groups?
# -----------------------------------------------------------------------------
sec "#30/#33  NLB target registration"
if [[ ${#TGS[@]} -eq 0 ]]; then
  warn "no -g <target-group-arn> given; target registration NOT verified"
  note "This is the check that catches BOTH silent failures at the load-balancer layer: a"
  note "TargetGroupBinding accepted by a controller that is not reconciling (#30), and the"
  note "controller's RegisterTargets being denied by its own IAM policy because our"
  note "Terraform-made target group carries no elbv2.k8s.aws/cluster tag (#30, Q-17)."
  note "Both present identically: a healthy-looking binding and an EMPTY target group."
elif ! command -v aws >/dev/null; then
  warn "aws CLI not found; cannot read target health"
else
  for tg in "${TGS[@]}"; do
    TH="$(aws elbv2 describe-target-health --target-group-arn "$tg" \
            --query 'TargetHealthDescriptions[].{id:Target.Id,state:TargetHealth.State,reason:TargetHealth.Reason}' \
            --output json 2>/dev/null || echo '[]')"
    NT="$(jq 'length' <<<"$TH")"
    NH="$(jq '[.[] | select(.state=="healthy")] | length' <<<"$TH")"
    if [[ "$NT" -eq 0 ]]; then
      bad "#30 VIOLATED: target group has NO registered targets — ${tg##*/}"
      note "The TargetGroupBinding was accepted and nothing acted on it. Either the"
      note "load-balancer controller is not running (#30), or its IAM policy refuses"
      note "RegisterTargets on a target group without the cluster tag (Q-17). Its log is in"
      note "a namespace our scoped access cannot read (#32), which is why this is the gate."
    elif [[ "$NH" -eq "$NT" ]]; then
      ok "${tg##*/}: $NH/$NT targets healthy"
    else
      bad "#33 VIOLATED: ${tg##*/}: only $NH/$NT targets healthy"
      jq -r '.[] | "        \(.id) \(.state) \(.reason // "")"' <<<"$TH"
      note "Target.FailedHealthChecks with pod IP targets is the node security group: health"
      note "checks arrive at THEIR node SG, which must admit 8545-8546 from our NLB SGs (#33)."
      note "Nothing in this output names a security group — that is the silent part."
    fi
  done
fi

# -----------------------------------------------------------------------------
# #34 F-1 and the QBFT set — the chain-level assertions
# -----------------------------------------------------------------------------
sec "#34 F-1 / #27  peer count and the QBFT block-producing set"
rpc_call() { # <method> -> result JSON, or empty
  local m="$1" auth=()
  [[ -n "$JWT" ]] && auth=(-H "Authorization: Bearer $JWT")
  curl -fsS --max-time 10 "${auth[@]}" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$m\",\"params\":[]}" "$RPC" 2>/dev/null \
    | jq -r '.result // empty' 2>/dev/null
}
if [[ -z "$RPC" ]]; then
  warn "no -r <rpc-url>; the CHAIN-level assertions were not run"
  note "Without them this script proved the pods are scheduled and spread, not that the chain"
  note "has four validators PRODUCING. Those are different failures: a validator can be Ready"
  note "and not in the set. The QBFT and NET APIs live on the validator ops listener, which is"
  note "JWT-authenticated (H6) — pass -r and -j to close this."
elif ! command -v curl >/dev/null; then
  warn "curl not found; chain-level assertions skipped"
else
  PEERS_HEX="$(rpc_call net_peerCount)"
  if [[ -n "$PEERS_HEX" ]]; then
    PEERS=$(( PEERS_HEX ))
    EXPECT=$(( WANT - 1 ))
    if [[ "$PEERS" -ge "$EXPECT" ]]; then
      ok "net_peerCount = $PEERS (>= $EXPECT)"
    else
      bad "#34 F-1 VIOLATED: net_peerCount = $PEERS, expected >= $EXPECT"
      note "Validators are spread across AZs, so EVERY validator-to-validator connection"
      note "crosses a subnet boundary and meets the cloud team's rules. A peer count of zero"
      note "is the ONLY symptom of a blocked F-1 — no log names the network as the cause."
      note "Note F-1 needs BOTH protocols: with 30303/TCP open and UDP closed, static peers"
      note "still connect and discovery is silently dead."
    fi
  else
    warn "net_peerCount returned nothing — is NET enabled on this endpoint, and the JWT valid?"
  fi

  VALSET="$(rpc_call qbft_getValidatorsByBlockNumber)"
  if [[ -n "$VALSET" ]]; then
    NSET="$(jq 'length' <<<"$VALSET" 2>/dev/null || echo 0)"
    if [[ "$NSET" -eq "$WANT" ]]; then
      ok "QBFT block-producing set contains $NSET validators"
    else
      bad "#27 VIOLATED: the QBFT set contains $NSET validators, expected $WANT"
      note "THIS IS THE CHECK THAT MATTERS. A chain running on $NSET of $WANT produces blocks"
      note "and reports healthy. With 3 of 4 it tolerates ZERO further failures; the next"
      note "node rotation (#29) halts the ledger."
    fi
  else
    warn "qbft_getValidatorsByBlockNumber returned nothing — is the QBFT API enabled here?"
    note "Pools are configured ETH,NET,WEB3; QBFT lives on the validator ops listener (H6)."
  fi
fi

# -----------------------------------------------------------------------------
# #35 / D-37 — prove enforcement, do not read configuration
# -----------------------------------------------------------------------------
sec "#35 (D-37)  NetworkPolicy enforcement probe"
if [[ "$PROBE_NETPOL" -ne 1 ]]; then
  warn "not run (needs --probe-netpol; it creates two short-lived pods)"
  note "Reading the CNI configuration is not evidence. The API server accepts NetworkPolicy"
  note "objects whether or not anything enforces them, so a default-deny that enforces"
  note "nothing is indistinguishable from one that works — and on shared nodes that policy"
  note "IS our tenant boundary. Only a refused connection proves it."
else
  PROBE="netpol-probe-$$"
  cleanup_probe() { kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
  trap cleanup_probe EXIT INT TERM
  # Target something our own default-deny policy must forbid. The validator RPC
  # port is the right target: it is exactly what must be unreachable from an
  # unlabelled pod in our namespace.
  TARGET_IP="$(jq -r '[.items[] | select(.status.phase=="Running")][0].status.podIP // empty' <<<"$PODS_JSON")"
  if [[ -z "$TARGET_IP" ]]; then
    warn "no Running validator pod IP to probe"
  else
    note "probing tcp/8545 at $TARGET_IP from an unlabelled pod (must be REFUSED)"
    # A 5s timeout, then report. `nc -z` returns 0 on connect.
    if kubectl -n "$NS" run "$PROBE" --image="${PROBE_IMAGE:-busybox:1.36}" --restart=Never \
         --command --quiet -- sh -c "nc -z -w 5 $TARGET_IP 8545" >/dev/null 2>&1; then
      kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$PROBE" --timeout=60s >/dev/null 2>&1 \
        && PROBE_RC=0 || PROBE_RC=1
      if [[ "$PROBE_RC" -eq 0 ]]; then
        bad "#35 VIOLATED: the connection SUCCEEDED. NetworkPolicy is accepted and NOT enforced"
        note "Every pod in this shared cluster can reach the validators' RPC. The tenant"
        note "boundary does not exist. Ask the cloud team for VPC CNI network policy"
        note "(ENABLE_NETWORK_POLICY=true on aws-node) or Calico/Cilium (#35)."
      else
        ok "the connection was refused — NetworkPolicy is enforced"
      fi
    else
      warn "could not create the probe pod (admission? #27/#32) — enforcement NOT proven"
    fi
  fi
  cleanup_probe
  trap - EXIT INT TERM
fi

printf '\n=== %d passed, %d failed, %d warnings ===\n' "$PASS" "$FAIL" "$WARN"
if [[ "$WARN" -gt 0 ]]; then
  printf '\033[33m%d assertion(s) could NOT be evaluated and are NOT passes.\033[0m Re-run with the missing\n' "$WARN"
  printf 'inputs (-r/-j for the chain, -g for target groups, -R for the role, --probe-netpol)\n'
  printf 'before treating this deployment as verified.\n'
fi
[[ "$FAIL" -eq 0 ]] || { echo "Deployed state does not meet the contract. Each failure names a requirement number." >&2; exit 1; }

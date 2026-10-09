#!/usr/bin/env bash
# =============================================================================
# verify-contract.sh — assert the CLUSTER hand-over against LIVE AWS.
# -----------------------------------------------------------------------------
# Read-only. The producer side of the contract, mirroring
# mimic_vpc/scripts/verify-contract.sh: it checks the actual API rather than
# Terraform state, because state can be stale and the platform will meet
# reality, not state.
#
# This is NOT a duplicate of the platform's modules/cluster-contract. That one
# asks "may I deploy onto this?" from the consumer side, at plan time. This one
# asks "is what I am about to hand over actually what I rendered?" — and it runs
# after an apply, when the two can have diverged.
#
# Every check names the requirement, so a failure reads the same way the
# platform's would.
#
# Usage:  scripts/verify-contract.sh [cluster-name] [region]
#     or: scripts/verify-contract.sh            (reads Terraform outputs)
# =============================================================================
set -euo pipefail

PASS=0; FAIL=0; NOTE=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
dlb()  { printf '  \033[33mBY DESIGN\033[0m  %s\n' "$*"; NOTE=$((NOTE+1)); }
head_(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

if [[ $# -ge 2 ]]; then
  CLUSTER="$1"; REGION="$2"; PROFILE="${3:-unknown}"
else
  TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
  CLUSTER="$(cd "$TF_DIR" && terraform output -raw cluster_name)"
  REGION="$(cd "$TF_DIR" && terraform output -raw region)"
  PROFILE="$(cd "$TF_DIR" && terraform output -raw profile)"
fi
A=(aws --region "$REGION")

printf '\n=== cluster contract verification: %s (%s, profile=%s) ===\n' "$CLUSTER" "$REGION" "$PROFILE"
if [[ "$PROFILE" == "hostile" ]]; then
  printf '\n\033[33mHOSTILE PROFILE: the lines marked BY DESIGN below are the fixture working.\n'
  printf 'They are what the platform must refuse. A FAIL here is a mimic bug.\033[0m\n'
fi

C="$("${A[@]}" eks describe-cluster --name "$CLUSTER" --query cluster --output json 2>/dev/null)" \
  || { echo "cannot describe cluster $CLUSTER in $REGION" >&2; exit 1; }

head_ "Cluster"
ok "version $(jq -r .version <<<"$C")"
[[ "$(jq -r .status <<<"$C")" == "ACTIVE" ]] && ok "status ACTIVE" || bad "status is $(jq -r .status <<<"$C")"

PRIV="$(jq -r .resourcesVpcConfig.endpointPrivateAccess <<<"$C")"
PUB="$(jq -r .resourcesVpcConfig.endpointPublicAccess <<<"$C")"
[[ "$PRIV" == "true" ]] && ok "#32 private endpoint access on" \
  || bad "#32 private endpoint access OFF — the runner would have no path at all"
if [[ "$PUB" == "true" ]]; then
  if [[ "$PROFILE" == "hostile" ]]; then
    dlb "#32 public endpoint access ON — the platform's CG-2 must refuse this"
  else
    bad "#32 public endpoint access ON in the strict profile"
  fi
else
  ok "#32 public endpoint access off"
fi

head_ "Pod identity (#31)"
ISS="$(jq -r '.identity.oidc.issuer // ""' <<<"$C")"
[[ -n "$ISS" ]] && ok "OIDC issuer present" || bad "#31 no OIDC issuer on the cluster"
if "${A[@]}" iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null \
     | tr '\t' '\n' | grep -q "${ISS#https://}"; then
  ok "#31 an IAM OIDC provider exists for this issuer"
else
  bad "#31 NO IAM OIDC provider for ${ISS} — AssumeRoleWithWebIdentity will reject every token our pods present"
fi

head_ "Node groups (#28)"
NGS="$("${A[@]}" eks list-nodegroups --cluster-name "$CLUSTER" --query nodegroups --output json 2>/dev/null || echo '[]')"
echo "    node groups: $(jq -r 'join(", ")' <<<"$NGS")"
TAINTED=0
for ng in $(jq -r '.[]' <<<"$NGS"); do
  N="$("${A[@]}" eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" --query nodegroup --output json)"
  SZ="$(jq -r .scalingConfig.desiredSize <<<"$N")"
  TN="$(jq -r '[.taints[]?| "\(.key)=\(.value):\(.effect)"] | join(",")' <<<"$N")"
  printf '    %-40s nodes=%s taints=%s\n' "$ng" "$SZ" "${TN:-none}"
  [[ -n "$TN" ]] && TAINTED=1
  if [[ "$SZ" -lt 4 ]]; then
    if [[ "$PROFILE" == "hostile" ]]; then
      dlb "#28 $ng has $SZ nodes for 4 validators — D-39's required anti-affinity must leave the 4th Pending"
    else
      bad "#28 $ng has only $SZ nodes; 4 validators need 4 distinct nodes (D-39)"
    fi
  fi
done
if [[ "$TAINTED" -eq 1 ]]; then
  ok "#28 a tainted node group exists"
elif [[ "$PROFILE" == "hostile" ]]; then
  dlb "#28 no tainted node group — with #35 also off, the platform's ISOLATION FLOOR (CG-9) must refuse the pair"
else
  bad "#28 no tainted node group in the strict profile"
fi

head_ "Node security group (#33)"
NSG="$(jq -r '.resourcesVpcConfig.clusterSecurityGroupId // ""' <<<"$C")"
if [[ -n "$NSG" ]]; then
  if "${A[@]}" ec2 describe-security-groups --group-ids "$NSG" \
       --query 'SecurityGroups[0].IpPermissions[?FromPort==`8545`]' --output json 2>/dev/null | jq -e 'length > 0' >/dev/null; then
    ok "#33 ingress for 8545 present on $NSG"
  elif [[ "$PROFILE" == "hostile" ]]; then
    dlb "#33 no 8545-8546 ingress — NLB targets must go unhealthy with nothing naming a security group"
  else
    bad "#33 no 8545-8546 ingress on $NSG in the strict profile"
  fi
fi

head_ "Access entries (#32)"
for p in $("${A[@]}" eks list-access-entries --cluster-name "$CLUSTER" --query accessEntries --output text 2>/dev/null || true); do
  SCOPE="$("${A[@]}" eks list-associated-access-policies --cluster-name "$CLUSTER" --principal-arn "$p" \
            --query 'associatedAccessPolicies[].{p:policyArn,s:accessScope.type}' --output json 2>/dev/null || echo '[]')"
  printf '    %s\n' "$p"
  jq -r '.[] | "      " + (.p | split("/") | last) + "  scope=" + .s' <<<"$SCOPE"
  if jq -e 'any(.s == "cluster")' <<<"$SCOPE" >/dev/null 2>&1; then
    if [[ "$PROFILE" == "hostile" ]]; then
      dlb "#32 a CLUSTER-scoped grant — the silent direction: it works exactly as well as a scoped one, so only verify-cluster.sh's NEGATIVE probes find it"
    else
      bad "#32 a cluster-scoped grant in the strict profile; it must be namespace-scoped"
    fi
  fi
done

printf '\n=== %d passed, %d failed, %d by design ===\n' "$PASS" "$FAIL" "$NOTE"
if [[ "$PROFILE" == "hostile" && "$NOTE" -eq 0 ]]; then
  echo "WARNING: hostile profile but no deliberate defects were observed. The fixture is not doing its job." >&2
  exit 1
fi
[[ "$FAIL" -eq 0 ]] || { echo "The mimic does not match what it rendered. This is a MIMIC bug." >&2; exit 1; }

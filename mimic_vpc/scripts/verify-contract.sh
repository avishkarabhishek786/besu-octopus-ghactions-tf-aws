#!/usr/bin/env bash
# =============================================================================
# verify-contract.sh — assert the hand-over contract against LIVE AWS.
# -----------------------------------------------------------------------------
# Read-only. Checks the actual API rather than Terraform state, because state
# can be stale or diverged and the platform will meet reality, not state.
#
# Every check names the requirement it enforces, so a failure can be quoted
# straight back to the cloud team.
#
# Usage:  scripts/verify-contract.sh <vpc-id> <region>
#     or: scripts/verify-contract.sh          (reads Terraform outputs)
# =============================================================================
set -euo pipefail

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

if [[ $# -ge 2 ]]; then
  VPC_ID="$1"; REGION="$2"
else
  TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
  VPC_ID="$(cd "$TF_DIR" && terraform output -raw vpc_id)"
  REGION="$(cd "$TF_DIR" && terraform output -raw region)"
fi
A=(aws --region "$REGION")

printf '\n=== network contract verification: %s (%s) ===\n' "$VPC_ID" "$REGION"

head_ "VPC attributes"
V=$("${A[@]}" ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0]' --output json)
[[ "$(jq -r '.InstanceTenancy' <<<"$V")" == "default" ]] \
  && ok "#1  instance_tenancy = default" \
  || bad "#1  instance_tenancy is NOT default — forced dedicated tenancy is irreversible and costs ~\$1,460/mo"

for attr in enableDnsSupport enableDnsHostnames; do
  val=$("${A[@]}" ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute "$attr" \
        --query "${attr^}.Value" --output text 2>/dev/null || echo unknown)
  [[ "$val" == "True" ]] && ok "#2  $attr = true" \
    || bad "#2  $attr is '$val' — endpoint Private DNS will not resolve; every AWS SDK call HANGS"
done

head_ "Addressing"
SEC=$(jq -r '[.CidrBlockAssociationSet[].CidrBlock] | map(select(startswith("100.64") or startswith("198.19"))) | length' <<<"$V")
[[ "$SEC" -ge 1 ]] && ok "#17 secondary CG-NAT CIDR associated" \
  || bad "#17 no secondary CIDR — a future move to CNI custom networking would need a rolling node replacement"

SUBS=$("${A[@]}" ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets' --output json)
N=$(jq 'length' <<<"$SUBS")
[[ "$N" -eq 15 ]] && ok "15 subnets present" || bad "expected 15 subnets, found $N"

AZN=$(jq -r '[.[].AvailabilityZoneId] | unique | length' <<<"$SUBS")
[[ "$AZN" -eq 3 ]] && ok "#5  subnets span exactly 3 distinct AZ IDs" \
  || bad "#5  subnets span $AZN AZ IDs — QBFT validator spread needs exactly 3"

IN_SEC=$(jq -r '[.[] | select(.CidrBlock | startswith("100.64") or startswith("198.19"))] | length' <<<"$SUBS")
[[ "$IN_SEC" -eq 0 ]] && ok "#17 secondary CIDR is UNUSED (no subnets carved from it)" \
  || bad "#17 $IN_SEC subnet(s) carved from the secondary CIDR — it must stay in reserve"

PUB=$(jq -r '[.[] | select(.MapPublicIpOnLaunch == true)] | length' <<<"$SUBS")
[[ "$PUB" -eq 0 ]] && ok "no subnet auto-assigns a public IP" || bad "$PUB subnet(s) auto-assign public IPs"

head_ "Kubernetes discovery tags"
TAGGED=$(jq -r '[.[] | select(.Tags[]? | select(.Key=="kubernetes.io/role/internal-elb" and .Value=="1"))] | length' <<<"$SUBS")
[[ "$TAGGED" -eq 3 ]] && ok "#4  internal-elb tag on 3 load-balancer subnets" \
  || bad "#4  internal-elb tag found on $TAGGED subnets (expected 3) — the LB Controller cannot place NLBs, and it fails only at Service-creation time"

head_ "No egress — the defining property of this VPC"
IGW=$("${A[@]}" ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'length(InternetGateways)' --output text)
[[ "$IGW" == "0" ]] && ok "no Internet Gateway attached" || bad "an Internet Gateway is attached — this VPC must have none"

NAT=$("${A[@]}" ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" \
      --query 'length(NatGateways[?State!=`deleted`])' --output text)
[[ "$NAT" == "0" ]] && ok "no NAT Gateway" || bad "$NAT NAT Gateway(s) present — impossible without a public subnet, and forbidden"

DEF=$("${A[@]}" ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'length(RouteTables[?Routes[?DestinationCidrBlock==`0.0.0.0/0`]])' --output text)
[[ "$DEF" == "0" ]] && ok "#12 no 0.0.0.0/0 route in any route table" \
  || bad "#12 $DEF route table(s) carry a default route — the ledger must never acquire one"

head_ "Capacity"
# Process substitution, NOT a pipe. A `cmd | while read` loop runs in a SUBSHELL,
# so PASS/FAIL increments inside it are lost — the checks would print but never
# count, and a genuine capacity failure would exit 0.
while read -r free name; do
  [[ "$free" -ge 50 ]] && ok "free IPs $free  $name" || bad "only $free free IPs in $name"
done < <(jq -r '.[] | "\(.AvailableIpAddressCount) \(.Tags[]? | select(.Key=="Name") | .Value)"' <<<"$SUBS")

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || { echo "Contract NOT satisfied. Quote the failing requirement number to the cloud team." >&2; exit 1; }
echo "Contract satisfied — safe to emit the hand-over and build the platform."

#!/usr/bin/env bash
# =============================================================================
# verify-endpoints.sh — are the cloud team's VPC endpoints usable by us?
# -----------------------------------------------------------------------------
# READ-ONLY. Costs nothing. Run it BEFORE any apply, and again after any change
# the cloud team makes to the shared VPC.
#
# WHY IT EXISTS
#   We are a tenant in a VPC we do not own, and the endpoints are operated
#   centrally (`central_interface_endpoints = true`). Every assumption we make
#   about them is a silent dependency on another team's configuration.
#
#   In a VPC with no egress, a wrong endpoint does not return an error. The
#   call routes to a public IP with no path out and HANGS until timeout,
#   surfacing as a pod stuck in Init, a node that never joins, or a bare
#   ImagePullBackOff that names neither the service nor the cause. Those are
#   the most expensive failures in this entire design to diagnose, and every
#   one of them is visible here in about ten seconds, for free.
#
# WHAT IT CANNOT DO
#   It does not evaluate IAM policy the way AWS does. Endpoint policies are
#   reported as PASS only when they are provably permissive; anything else is a
#   WARN with the policy printed, never a silent PASS. A WARN here means "read
#   this yourself", not "probably fine".
#
# Usage:
#   scripts/preflight/verify-endpoints.sh <vpc-id> [region] [--route-tables rtb-a,rtb-b]
#                                                           [--addon-account <id>]
#                                                           [--pod-identity]
# Example:
#   scripts/preflight/verify-endpoints.sh vpc-0abc123 af-south-1 \
#       --route-tables rtb-011,rtb-022,rtb-033
# =============================================================================
set -euo pipefail

VPC_ID="${1:?usage: verify-endpoints.sh <vpc-id> [region] [--route-tables ids] [--addon-account id]}"
shift
REGION="${AWS_REGION:-af-south-1}"
ROUTE_TABLES=""
ADDON_ACCOUNT=""

# First positional after the VPC, if it does not look like a flag, is the region.
POD_IDENTITY=0
if [[ $# -gt 0 && "${1:0:2}" != "--" ]]; then REGION="$1"; shift; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --route-tables)  ROUTE_TABLES="${2:?}"; shift 2 ;;
    --addon-account) ADDON_ACCOUNT="${2:?}"; shift 2 ;;
    # #31: the cluster's pod-identity mechanism is the cloud team's choice, not
    # ours. Pass this when the eks-handover says pod_identity = true.
    --pod-identity)  POD_IDENTITY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# -----------------------------------------------------------------------------
# The EKS managed-addon registry account is REGION-SPECIFIC.
# -----------------------------------------------------------------------------
# This is a documented trap, not a detail: af-south-1 is 877085696533, NOT the
# widely-quoted 602401143452 that serves us-east-1, eu-west-1 and most other
# regions. A policy written with the common value fails in af-south-1 exactly
# as if no policy allowed the pull at all.
#
# Only values we have verified are listed. For any other region the script
# refuses to guess -- look it up in the AWS docs under "View Amazon container
# image registries for Amazon EKS add-ons" and pass --addon-account.
# -----------------------------------------------------------------------------
declare -A ADDON_ACCOUNTS=(
  [af-south-1]=877085696533
)
if [[ -z "$ADDON_ACCOUNT" ]]; then
  ADDON_ACCOUNT="${ADDON_ACCOUNTS[$REGION]:-}"
fi

# The 15 interface endpoints this platform cannot run without. Kept in the same
# order as terraform/shared/variables.tf:interface_endpoint_services so a
# divergence is visible on sight.
REQUIRED_INTERFACE=(
  ssm ssmmessages ec2messages
  ec2 ecr.api ecr.dkr
  sts eks elasticloadbalancing
  secretsmanager kms
  logs monitoring
  sns sqs
)

# -----------------------------------------------------------------------------
# #31 / D-14 — eks-auth is CONDITIONAL, and the condition is not ours to set.
# -----------------------------------------------------------------------------
# D-14 dropped eks-auth on the reasoning "we use IRSA, not Pod Identity". Under
# CT-5 we do not choose: the cluster is the cloud team's and so is the mechanism
# (#31). If it is EKS Pod Identity, the agent on their nodes reaches the
# eks-auth endpoint -- and in this VPC a missing endpoint does not error, it
# HANGS until timeout (prime directive 2), presenting as pods that start and
# then cannot obtain credentials for no stated reason.
#
# Driven by a flag rather than hand-edited into the array above, so the list
# cannot drift from the hand-over value that decides it.
if [[ "${POD_IDENTITY:-0}" -eq 1 ]]; then
  REQUIRED_INTERFACE+=(eks-auth)
fi

# Endpoints whose Private DNS is not merely desirable but load-bearing: without
# it the service hostname resolves to a PUBLIC address this VPC cannot route to.
# ecr.dkr is called out in AWS's own docs as requiring it (#22).
PRIVATE_DNS_CRITICAL=(ecr.api ecr.dkr sts kms secretsmanager ssm ssmmessages ec2messages)

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; WARN=$((WARN+1)); }
sec()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

printf '\n=== VPC endpoint readiness: %s in %s ===\n' "$VPC_ID" "$REGION"

# One API call. Everything below reads from this document, so the script makes
# no assumptions the account cannot see.
EP=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
       --filters "Name=vpc-id,Values=$VPC_ID" \
       --query 'VpcEndpoints' --output json 2>/dev/null) \
  || { echo "cannot describe VPC endpoints -- needs ec2:DescribeVpcEndpoints on $VPC_ID (see follow-up R-6)" >&2; exit 1; }

[[ "$(jq 'length' <<<"$EP")" -gt 0 ]] \
  || { echo "no VPC endpoints found in $VPC_ID at all. Nothing in this design can start." >&2; exit 1; }

# -----------------------------------------------------------------------------
# is_permissive <policy-json>
# -----------------------------------------------------------------------------
# True only when the policy is the AWS default full-access document, or is
# plainly equivalent: an Allow, to any principal, on Action "*" and Resource
# "*", with no Condition and no Deny anywhere.
#
# Deliberately conservative. A policy this function cannot prove permissive is
# reported as a WARN and printed, never assumed adequate -- a false PASS here
# would return us to exactly the silent mid-apply hang the script exists to
# prevent.
# -----------------------------------------------------------------------------
is_permissive() {
  jq -e '
    (.Statement | if type == "array" then . else [.] end) as $s
    | ($s | map(select(.Effect == "Deny")) | length) == 0
      and ($s | any(
            .Effect == "Allow"
            and (has("Condition") | not)
            and ((.Action    | if type=="array" then . else [.] end) | any(. == "*"))
            and ((.Resource  | if type=="array" then . else [.] end) | any(. == "*"))
          ))
  ' >/dev/null 2>&1 <<<"$1"
}

# --- 1. interface endpoints exist and are available --------------------------
sec "Interface endpoints (#22, Q-2)"
MISSING=()
for svc in "${REQUIRED_INTERFACE[@]}"; do
  NAME="com.amazonaws.${REGION}.${svc}"
  E=$(jq --arg n "$NAME" '[.[] | select(.ServiceName == $n and .VpcEndpointType == "Interface")][0]' <<<"$EP")
  if [[ "$E" == "null" ]]; then
    MISSING+=("$svc"); continue
  fi
  STATE=$(jq -r '.State' <<<"$E")
  [[ "$STATE" == "available" ]] \
    || bad "$svc endpoint state is '$STATE', not 'available'"
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
  ok "all ${#REQUIRED_INTERFACE[@]} required interface endpoints present"
else
  bad "MISSING interface endpoints: ${MISSING[*]}"
  # The SSM trio has no workaround at all, so say so separately and loudly.
  for m in "${MISSING[@]}"; do
    case "$m" in
      ssm|ssmmessages|ec2messages)
        bad "  ^ '$m' is one of the SSM trio: Session Manager is the ONLY path to the In-VPC EC2 Runner, which is the only path into the cluster. Nothing can be bootstrapped without it." ;;
      ecr.api|ecr.dkr)
        bad "  ^ '$m' carries every container image pull. Every pod stays in ImagePullBackOff." ;;
      kms)
        bad "  ^ 'kms' decrypts the validator private keys at pod start (C12). Without it no validator can boot and the chain never produces a block." ;;
      sts)
        bad "  ^ 'sts' is IRSA: every pod that assumes an IAM role. Its absence breaks the CSI drivers, log shipping and secret retrieval together." ;;
    esac
  done
fi

# --- 2. private DNS ----------------------------------------------------------
sec "Private DNS (#22)"
for svc in "${PRIVATE_DNS_CRITICAL[@]}"; do
  NAME="com.amazonaws.${REGION}.${svc}"
  # NOT `.PrivateDnsEnabled // "absent"` -- jq's `//` treats FALSE as empty, so
  # the one value this check exists to catch would report as "absent" and be
  # skipped silently. Ask whether the key is present instead.
  PD=$(jq -r --arg n "$NAME" '
        [.[] | select(.ServiceName == $n)][0]
        | if . == null then "absent"
          elif has("PrivateDnsEnabled") then (.PrivateDnsEnabled | tostring)
          else "unset" end' <<<"$EP")
  case "$PD" in
    true)   ok "$svc has Private DNS enabled" ;;
    false)  bad "$svc has Private DNS DISABLED -- the service hostname resolves to a PUBLIC address with no route from this VPC. Every call hangs until timeout. AWS documents ecr.dkr as REQUIRING it." ;;
    unset)  warn "$svc endpoint does not report PrivateDnsEnabled -- check by hand" ;;
    absent) : ;;  # already counted as missing above
  esac
done

# --- 3. endpoint security groups admit 443 -----------------------------------
# An endpoint can exist, resolve correctly, and still time out on every
# connection because its ENI security group has no ingress rule. Same silent
# failure as a missing endpoint, different cause.
sec "Endpoint security groups"
VPC_CIDRS=$(aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$VPC_ID" \
              --query 'Vpcs[0].CidrBlockAssociationSet[?CidrBlockState.State==`associated`].CidrBlock' \
              --output json 2>/dev/null || echo '[]')
SG_IDS=$(jq -r '[.[] | select(.VpcEndpointType == "Interface") | .Groups[]?.GroupId] | unique | .[]' <<<"$EP")
if [[ -z "$SG_IDS" ]]; then
  warn "no security groups reported on the interface endpoints (cannot verify 443 ingress)"
else
  SG_JSON=$(aws ec2 describe-security-groups --region "$REGION" \
              --group-ids $SG_IDS --query 'SecurityGroups' --output json 2>/dev/null || echo '[]')
  ANY443=$(jq --argjson cidrs "$VPC_CIDRS" '
      [ .[] | .IpPermissions[]?
        | select((.IpProtocol == "-1") or ((.FromPort <= 443) and (.ToPort >= 443)))
        | select( (.IpRanges[]?.CidrIp) as $c | ($c == "0.0.0.0/0") or ($cidrs | index($c)) )
      ] | length' <<<"$SG_JSON")
  if [[ "${ANY443:-0}" -gt 0 ]]; then
    ok "endpoint security group admits 443 from inside the VPC"
  else
    warn "could not find a 443 ingress rule from a VPC CIDR on the endpoint security groups. If the rule is written against another security group rather than a CIDR this is a false alarm -- check by hand, because the failure mode is a silent timeout."
  fi
fi

# --- 4. S3 gateway endpoint: the one that carries image LAYERS ---------------
sec "S3 gateway endpoint (#20, #10)"
S3EP=$(jq --arg n "com.amazonaws.${REGION}.s3" '[.[] | select(.ServiceName == $n and .VpcEndpointType == "Gateway")][0]' <<<"$EP")
if [[ "$S3EP" == "null" ]]; then
  bad "NO S3 gateway endpoint. ECR serves image manifests over ecr.dkr but the LAYERS come from S3 -- every pull fails partway through the download, presenting as an intermittent network fault rather than an access error. Terraform state is also unreachable."
else
  ok "S3 gateway endpoint present"

  if [[ -n "$ROUTE_TABLES" ]]; then
    ASSOC=$(jq -r '.RouteTableIds[]?' <<<"$S3EP")
    IFS=',' read -ra WANT <<<"$ROUTE_TABLES"
    for rt in "${WANT[@]}"; do
      grep -qx "$rt" <<<"$ASSOC" \
        && ok "route table $rt is associated with the S3 gateway endpoint" \
        || bad "route table $rt is NOT associated with the S3 gateway endpoint -- subnets using it have no path to S3, so pods there cannot pull image layers"
    done
  else
    warn "no --route-tables given, so association was not checked. A gateway endpoint only serves subnets whose route table it is associated with; pass the ledger/app/lb/endpoint route table IDs to verify."
  fi

  # The layer bucket. This is region-named, and it is named for the region the
  # IMAGES are served from -- which is why #25's "ECR is in af-south-1" answer
  # matters here and not only in the registry section.
  LAYER_ARN="arn:aws:s3:::prod-${REGION}-starport-layer-bucket/*"
  POL=$(jq -r '.PolicyDocument // empty' <<<"$S3EP")
  if [[ -z "$POL" ]]; then
    ok "S3 endpoint has no policy (full access) -- the layer bucket is reachable"
  elif is_permissive "$POL"; then
    ok "S3 endpoint policy is full-access -- the layer bucket is reachable"
  elif grep -q "starport-layer-bucket" <<<"$POL"; then
    grep -q "prod-${REGION}-starport-layer-bucket" <<<"$POL" \
      && ok "S3 endpoint policy names $LAYER_ARN" \
      || bad "S3 endpoint policy names a starport layer bucket for a DIFFERENT region. ECR image layers are served from the bucket of the region the registry lives in; this policy will not match."
  else
    warn "S3 endpoint policy is restrictive and does not mention the ECR layer bucket. Unless a broader statement covers it, every image pull will stall mid-layer. Required: s3:GetObject on $LAYER_ARN"
    printf '        policy: %s\n' "$(jq -c . <<<"$POL" 2>/dev/null || echo "$POL")"
  fi
fi

# --- 5. ECR endpoint policies: the cross-account addon trap ------------------
sec "ECR endpoint policies (#23)"
for svc in ecr.api ecr.dkr; do
  NAME="com.amazonaws.${REGION}.${svc}"
  POL=$(jq -r --arg n "$NAME" '[.[] | select(.ServiceName == $n)][0].PolicyDocument // empty' <<<"$EP")
  [[ "$(jq -r --arg n "$NAME" '[.[] | select(.ServiceName == $n)] | length' <<<"$EP")" -gt 0 ]] || continue

  if [[ -z "$POL" ]] || is_permissive "$POL"; then
    ok "$svc endpoint policy is full-access -- no addon or auth trap"
    continue
  fi

  # Trap 1: GetAuthorizationToken is a REGISTRY-level action whose resource is
  # always "*". Folded into a statement scoped to repository ARNs, it fails
  # authentication before any pull is attempted -- and reads as a credentials
  # problem, not a policy one.
  if grep -q "GetAuthorizationToken" <<<"$POL"; then
    ok "$svc policy mentions ecr:GetAuthorizationToken"
  else
    warn "$svc policy is restrictive and does not mention ecr:GetAuthorizationToken. It is registry-level (Resource must be \"*\") and needs its own statement; without it authentication fails before any pull, presenting as a credentials error."
  fi

  # Trap 2: the EKS managed addons (vpc-cni, coredns, kube-proxy) are pulled BY
  # our node role but FROM an AWS-owned account. A Resource scoped to our own
  # repositories denies them, and the cluster simply never becomes ready.
  if grep -qE '"Resource"[[:space:]]*:[[:space:]]*"\*"' <<<"$POL"; then
    ok "$svc policy allows Resource \"*\" -- the AWS-owned addon registry is reachable"
  elif [[ -n "$ADDON_ACCOUNT" ]] && grep -q "$ADDON_ACCOUNT" <<<"$POL"; then
    ok "$svc policy names the EKS addon registry account $ADDON_ACCOUNT"
  elif [[ -z "$ADDON_ACCOUNT" ]]; then
    warn "$svc policy is resource-scoped and no addon registry account is known for $REGION. Look it up (AWS docs: 'View Amazon container image registries for Amazon EKS add-ons') and re-run with --addon-account <id>."
  else
    bad "$svc policy is resource-scoped and does NOT name the EKS addon registry account $ADDON_ACCOUNT for $REGION. vpc-cni, coredns and kube-proxy will fail to pull and the cluster will never become ready -- which presents as a broken cluster, not a policy problem."
    printf '        policy: %s\n' "$(jq -c . <<<"$POL" 2>/dev/null || echo "$POL")"
  fi
done

# --- 6. informational: anything else already there ---------------------------
sec "Also present in this VPC (informational)"
jq -r --arg p "com.amazonaws.${REGION}." '
  [ .[] | .ServiceName | select(startswith($p)) | ltrimstr($p) ] | sort | join(", ")' <<<"$EP" \
  | fold -s -w 92 | sed 's/^/  /'

printf '\n=== %d passed, %d failed, %d warnings ===\n' "$PASS" "$FAIL" "$WARN"
if [[ "$FAIL" -ne 0 ]]; then
  cat >&2 <<'MSG'

Endpoints are NOT ready. Every failure above is a configuration on infrastructure
we do not own, so quote the requirement number to the cloud team rather than the
symptom -- see docs/CLOUD_TEAM_FOLLOWUP_2026-09-09.md.

Do not apply. In a VPC with no egress these do not fail fast; they hang.
MSG
  exit 1
fi
[[ "$WARN" -eq 0 ]] \
  && echo "Endpoints are ready." \
  || echo "Endpoints are usable, but read the warnings above -- each one is a check this script could not prove, not one it passed."

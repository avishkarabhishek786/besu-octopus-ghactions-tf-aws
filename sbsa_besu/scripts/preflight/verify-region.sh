#!/usr/bin/env bash
# =============================================================================
# verify-region.sh — can the target region host this design?
# -----------------------------------------------------------------------------
# READ-ONLY. Run this BEFORE switching region in tfvars.
#
# WHY IT EXISTS
#   The configuration is fully region-parameterised, so switching production to
#   af-south-1 is a tfvars change. But "the Terraform is portable" is not the
#   same as "the region can host it". Smaller regions carry fewer instance
#   families, fewer AZs, and occasionally fewer service endpoints — and every
#   one of those failures lands mid-apply, after money has been spent.
#
#   This script answers the question in about ten seconds, for free.
#
# Usage:  scripts/preflight/verify-region.sh <region> [instance-type] [k8s-version]
# Example: scripts/preflight/verify-region.sh af-south-1 m6i.xlarge 1.35
# =============================================================================
set -euo pipefail

REGION="${1:?usage: verify-region.sh <region> [instance-type] [k8s-version]}"
ITYPE="${2:-m6i.xlarge}"
K8S="${3:-1.35}"
NEED_AZS=3

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; WARN=$((WARN+1)); }
sec()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
printf '\n=== region readiness: %s ===\n' "$REGION"

# --- 1. opt-in status --------------------------------------------------------
# af-south-1 is an OPT-IN region: nothing provisions until it is enabled on the
# account, and enabling takes a few minutes.
sec "Region enablement"
STATUS=$(aws account get-region-opt-status --region-name "$REGION" \
         --query RegionOptStatus --output text 2>/dev/null || echo UNKNOWN)
case "$STATUS" in
  ENABLED|ENABLED_BY_DEFAULT) ok "region is $STATUS" ;;
  DISABLED) bad "region is DISABLED. Enable it first:  aws account enable-region --region-name $REGION  (takes a few minutes)" ;;
  *) warn "could not read opt-in status (needs account:GetRegionOptStatus). Check manually." ;;
esac

# --- 2. AZs + 3. instance type, INTERSECTED ---------------------------------
# These two must be answered together. An AZ that exists but does not offer the
# instance family is useless to us, and us-east-1 has a well-known example:
# use1-az3 is a constrained zone where newer families are often unavailable.
# Recommending AZ IDs without checking the family is how you discover the problem
# at node-group creation instead of now.
sec "Availability Zones x instance type $ITYPE"

AZJSON='[]'; OFFERS='[]'
AZJSON=$(aws ec2 describe-availability-zones --region "$REGION" \
         --query 'AvailabilityZones[?State==`available`].[ZoneName,ZoneId]' --output json 2>/dev/null) \
  || bad "cannot list AZs — is the region enabled and are credentials valid?"

# --location-type availability-zone-id returns Location as the ZONE ID
# (use1-az1). The 'availability-zone' variant returns zone NAMES, which do not
# compare against the zone IDs used everywhere else in this programme.
OFFERS=$(aws ec2 describe-instance-type-offerings --region "$REGION" \
         --location-type availability-zone-id \
         --filters "Name=instance-type,Values=$ITYPE" \
         --query 'InstanceTypeOfferings[].Location' --output json 2>/dev/null) \
  || warn "could not query instance type offerings"

TOTAL=$(jq 'length' <<<"$AZJSON")
USABLE=$(jq -n --argjson az "$AZJSON" --argjson off "$OFFERS" \
         '[$az[] | select(.[1] as $id | $off | index($id))]')
NUSABLE=$(jq 'length' <<<"$USABLE")

[[ "$TOTAL" -ge "$NEED_AZS" ]] \
  && ok "$TOTAL AZs in region" \
  || bad "$TOTAL AZs — need at least $NEED_AZS. Four validators must spread across three zones so losing one leaves a 2F+1 quorum."

if [[ "$NUSABLE" -ge "$NEED_AZS" ]]; then
  ok "$ITYPE offered in $NUSABLE of $TOTAL AZs — enough for validator spread"
elif [[ "$NUSABLE" -gt 0 ]]; then
  bad "$ITYPE offered in only $NUSABLE of $TOTAL AZs. Validators cannot spread across $NEED_AZS zones. Pick another family — and note the 161 TPS load-test result was measured on m6i.xlarge, so re-test if you change it."
else
  bad "$ITYPE is NOT offered anywhere in $REGION."
fi

EXCLUDED=$(jq -n --argjson az "$AZJSON" --argjson off "$OFFERS" \
           '[$az[] | select(.[1] as $id | ($off | index($id)) | not) | .[1]]')
[[ "$(jq 'length' <<<"$EXCLUDED")" -eq 0 ]] \
  || warn "AZs WITHOUT $ITYPE (do not use): $(jq -r 'join(", ")' <<<"$EXCLUDED")"

printf '\n  AZ ID       Zone name      %s\n' "$ITYPE"
jq -r --argjson off "$OFFERS" \
   '.[] | .[1] as $id | "    \($id)\t\(.[0])\t" + (if ($off | index($id)) then "yes" else "NO" end)' <<<"$AZJSON" \
  | column -t

if [[ "$NUSABLE" -ge "$NEED_AZS" ]]; then
  printf '\n  \033[1mPaste into your tfvars:\033[0m\n'
  printf '    az_ids = %s\n' "$(jq -c "[.[] | .[1]] | .[0:$NEED_AZS]" <<<"$USABLE")"
fi

# --- 4. interface endpoint services ------------------------------------------
# In an air-gapped VPC a missing endpoint service is fatal: there is no NAT
# fallback, and the call hangs rather than failing.
sec "Interface endpoint services (air-gapped VPC has no fallback)"
SERVICES=(ssm ssmmessages ec2messages ec2 ecr.api ecr.dkr sts eks
          elasticloadbalancing secretsmanager kms logs monitoring sns sqs)
if AVAIL=$(aws ec2 describe-vpc-endpoint-services --region "$REGION" \
           --query 'ServiceNames' --output json 2>/dev/null); then
  MISSING=()
  for s in "${SERVICES[@]}"; do
    jq -e --arg n "com.amazonaws.$REGION.$s" 'index($n)' <<<"$AVAIL" >/dev/null 2>&1 || MISSING+=("$s")
  done
  if [[ ${#MISSING[@]} -eq 0 ]]; then
    ok "all ${#SERVICES[@]} required interface endpoint services available"
  else
    bad "missing endpoint services: ${MISSING[*]}"
  fi
  for g in s3 dynamodb; do
    jq -e --arg n "com.amazonaws.$REGION.$g" 'index($n)' <<<"$AVAIL" >/dev/null 2>&1 \
      && ok "gateway endpoint '$g' available (free)" \
      || bad "gateway endpoint '$g' unavailable — S3 carries container image layers; nothing starts without it"
  done
else
  warn "could not list endpoint services"
fi

# --- 5. EKS version ----------------------------------------------------------
sec "EKS Kubernetes $K8S"
if V=$(aws eks describe-cluster-versions --region "$REGION" \
       --query "clusterVersions[?clusterVersion=='$K8S'].clusterVersion" --output text 2>/dev/null) && [[ -n "$V" ]]; then
  ok "Kubernetes $K8S offered"
else
  warn "could not confirm Kubernetes $K8S (API may not exist in this CLI version). Fallback ladder: 1.35 -> 1.34 -> ..."
fi

printf '\n=== %d passed, %d failed, %d warnings ===\n' "$PASS" "$FAIL" "$WARN"
[[ "$FAIL" -eq 0 ]] || { echo "Region NOT ready. Resolve the failures before switching tfvars." >&2; exit 1; }
echo "Region $REGION can host the design. Switch region + az_ids in the environment tfvars."

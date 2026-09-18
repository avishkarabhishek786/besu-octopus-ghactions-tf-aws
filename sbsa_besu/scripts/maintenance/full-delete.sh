#!/usr/bin/env bash
# =============================================================================
# scripts/maintenance/full-delete.sh  —  IRREVERSIBLE tag-keyed teardown (backstop)
# -----------------------------------------------------------------------------
# Deletes EVERY resource tagged DeletionGroup=<value> in AWS_REGION. This is the
# BACKSTOP for when the Terraform state is lost — the normal teardown is
# `terraform destroy`.
#
# SAFETY:
#   * DRY-RUN BY DEFAULT — prints the inventory and exits. Pass --confirm to act.
#   * --confirm requires typing exactly:  DELETE <deletion_group>
#   * Keyed strictly on the DeletionGroup tag, so a different deployment in the
#     same account is never in the blast radius.
#   * It removes keys (Secrets Manager) and chain data (EBS) — UNRECOVERABLE.
#
# Usage:
#   AWS_REGION=us-east-1 scripts/maintenance/full-delete.sh <deletion_group>            # dry-run
#   AWS_REGION=us-east-1 scripts/maintenance/full-delete.sh <deletion_group> --confirm  # delete
#
# Prefer `terraform destroy` when state exists. Use this only as the nuke option.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
need aws; need jq

DG="${1:?usage: full-delete.sh <deletion_group> [--confirm]}"
shift || true
CONFIRM=false
while [ $# -gt 0 ]; do case "$1" in
  --confirm) CONFIRM=true ;;
  *) die "unknown arg: $1" ;;
esac; shift; done

# H26 (human decision 2026-07-06): full-delete is a DEPLOY-TEST-ONLY teardown backstop
# and MUST NOT run against the production account. Refuse unless the caller explicitly
# names the intended deploy-test account + region AND they match the live identity.
# (This script is also excluded from any prod deploy bundle — C9 test-only-artifact audit.)
: "${EXPECT_ACCOUNT_ID:?H26 guard: set EXPECT_ACCOUNT_ID=<deploy-test account id>. full-delete is deploy-test-only and must never touch prod.}"
: "${EXPECT_REGION:?H26 guard: set EXPECT_REGION=<deploy-test region> (avoids the silent us-east-1 default nuking the wrong region).}"
_caller_acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
[ -n "$_caller_acct" ] || die "cannot resolve caller account (aws sts get-caller-identity failed) — refusing."
[ "$_caller_acct" = "$EXPECT_ACCOUNT_ID" ] || die "H26 guard: caller account ($_caller_acct) != EXPECT_ACCOUNT_ID ($EXPECT_ACCOUNT_ID) — refusing (not the deploy-test account)."
[ "${AWS_REGION}" = "$EXPECT_REGION" ] || die "H26 guard: AWS_REGION ($AWS_REGION) != EXPECT_REGION ($EXPECT_REGION) — export AWS_REGION explicitly to the intended deploy-test region."

# H26: validate DeletionGroup before it is interpolated into JMESPath / CLI filters.
case "$DG" in
  "" | *[!A-Za-z0-9._-]*) die "invalid DeletionGroup '$DG' (allowed characters: A-Za-z0-9._-)." ;;
esac

REGIONS=("$AWS_REGION")

inventory() { # $1 region
  aws resourcegroupstaggingapi get-resources --region "$1" \
    --tag-filters "Key=DeletionGroup,Values=${DG}" \
    --query "ResourceTagMappingList[].ResourceARN" --output text 2>/dev/null | tr '\t' '\n'
}

echo "=================================================================="
echo " FULL-DELETE  DeletionGroup=${DG}   regions: ${REGIONS[*]}"
echo "=================================================================="
for r in "${REGIONS[@]}"; do
  echo "--- $r ---"; inventory "$r" | sed 's/^/  /' || true
done

if ! $CONFIRM; then
  echo; log "DRY-RUN (no --confirm): nothing deleted. Re-run with --confirm to delete."
  exit 0
fi

echo; echo "This will IRREVERSIBLY delete the above, including keys and chain data."
printf 'Type "DELETE %s" to proceed: ' "$DG"
read -r ans
[ "$ans" = "DELETE ${DG}" ] || die "confirmation mismatch — aborted."

# tagged <region> <service> <resourcetype-substr> -> matching ARNs
tagged() { inventory "$1" | grep -E ":$2:" | { [ -n "${3:-}" ] && grep -E "$3" || cat; } || true; }
idof()   { awk -F'[:/]' '{print $NF}'; }

for R in "${REGIONS[@]}"; do
  log "===== region $R ====="

  # 1) EKS — delete nodegroups + addons, then the cluster.
  for c in $(tagged "$R" eks "cluster/" | idof); do
    log "EKS cluster $c"
    for ng in $(aws eks list-nodegroups --region "$R" --cluster-name "$c" --query nodegroups --output text 2>/dev/null); do
      aws eks delete-nodegroup --region "$R" --cluster-name "$c" --nodegroup-name "$ng" 2>/dev/null || true
    done
    for ng in $(aws eks list-nodegroups --region "$R" --cluster-name "$c" --query nodegroups --output text 2>/dev/null); do
      aws eks wait nodegroup-deleted --region "$R" --cluster-name "$c" --nodegroup-name "$ng" 2>/dev/null || true
    done
    for ad in $(aws eks list-addons --region "$R" --cluster-name "$c" --query addons --output text 2>/dev/null); do
      aws eks delete-addon --region "$R" --cluster-name "$c" --addon-name "$ad" 2>/dev/null || true
    done
    aws eks delete-cluster --region "$R" --name "$c" 2>/dev/null || true
    aws eks wait cluster-deleted --region "$R" --name "$c" 2>/dev/null || true
  done

  # 2) EC2 instances (runner, etc.)
  ids=$(tagged "$R" ec2 "instance/" | idof | tr '\n' ' ')
  [ -n "${ids// }" ] && { log "terminate instances: $ids"; aws ec2 terminate-instances --region "$R" --instance-ids $ids >/dev/null 2>&1 || true; aws ec2 wait instance-terminated --region "$R" --instance-ids $ids 2>/dev/null || true; }

  # 3) Load balancers (NLB/ALB)
  for lb in $(tagged "$R" elasticloadbalancing "loadbalancer/"); do
    log "delete LB $lb"; aws elbv2 delete-load-balancer --region "$R" --load-balancer-arn "$lb" 2>/dev/null || true
  done
  sleep 10

  # 4) NAT gateways + release EIPs
  for nat in $(tagged "$R" ec2 "natgateway/" | idof); do
    log "delete NAT $nat"; aws ec2 delete-nat-gateway --region "$R" --nat-gateway-id "$nat" >/dev/null 2>&1 || true
  done
  # H26: NAT deletion alone leaves the allocated EIPs behind — they keep BILLING and
  # were never released before. After NAT teardown, release the DeletionGroup-tagged
  # EIPs that are now unassociated. (NAT deletion is async; give it a moment first.)
  sleep 5
  for eip in $(aws ec2 describe-addresses --region "$R" \
      --filters "Name=tag:DeletionGroup,Values=${DG}" \
      --query "Addresses[?AssociationId==null].AllocationId" --output text 2>/dev/null); do
    log "release EIP $eip"; aws ec2 release-address --region "$R" --allocation-id "$eip" >/dev/null 2>&1 || true
  done

  # 5) AWS Backup — selections, plans, vaults (recovery points first)
  for v in $(tagged "$R" backup "backup-vault" | awk -F: '{print $NF}' | sed 's#backup-vault:##'); do
    for rp in $(aws backup list-recovery-points-by-backup-vault --region "$R" --backup-vault-name "$v" --query "RecoveryPoints[].RecoveryPointArn" --output text 2>/dev/null); do
      aws backup delete-recovery-point --region "$R" --backup-vault-name "$v" --recovery-point-arn "$rp" 2>/dev/null || true
    done
  done

  # 6) Secrets Manager (force-delete — UNRECOVERABLE).
  # C11: query list-secrets DIRECTLY with --include-planned-deletion — the tagging
  # API stops returning secrets once a `terraform destroy` has put them into their
  # 30-day scheduled-deletion window, yet those still BLOCK a re-deploy (fixed
  # secret names collide). Filter on our DeletionGroup tag.
  for s in $(aws secretsmanager list-secrets --region "$R" --include-planned-deletion \
      --query "SecretList[?Tags[?Key=='DeletionGroup' && Value=='${DG}']].Name" --output text 2>/dev/null); do
    log "force-delete secret $s"; aws secretsmanager delete-secret --region "$R" --secret-id "$s" --force-delete-without-recovery >/dev/null 2>&1 || true
  done
  for s in $(tagged "$R" secretsmanager "secret:"); do # belt-and-braces: tagging-API view
    aws secretsmanager delete-secret --region "$R" --secret-id "$s" --force-delete-without-recovery >/dev/null 2>&1 || true
  done

  # 7) SNS topics, CloudWatch alarms + log groups, CloudTrail
  for t in $(tagged "$R" sns); do aws sns delete-topic --region "$R" --topic-arn "$t" 2>/dev/null || true; done
  for a in $(tagged "$R" cloudwatch "alarm:" | awk -F: '{print $NF}'); do aws cloudwatch delete-alarms --region "$R" --alarm-names "$a" 2>/dev/null || true; done
  for tr in $(tagged "$R" cloudtrail "trail/" | awk -F/ '{print $NF}'); do aws cloudtrail delete-trail --region "$R" --name "$tr" 2>/dev/null || true; done

  # 8) S3 buckets (empty then delete)
  for b in $(tagged "$R" s3 | awk -F: '{print $NF}'); do
    log "empty+delete bucket $b"; aws s3 rb "s3://$b" --force >/dev/null 2>&1 || true
  done

  # 9) Orphaned EBS volumes (available, our tag).
  # C11: PVC volumes are stamped with DeletionGroup via the StorageClass
  # tagSpecification (modules/storage-csi), so this DG-keyed sweep now catches
  # chain-data volumes too. Volumes from OLDER deployments (pre-tagSpecification)
  # carry no DG tag — they are REPORTED (not deleted) by the leftover check below.
  for vol in $(aws ec2 describe-volumes --region "$R" --filters Name=status,Values=available "Name=tag:DeletionGroup,Values=${DG}" --query "Volumes[].VolumeId" --output text 2>/dev/null); do
    log "delete volume $vol"; aws ec2 delete-volume --region "$R" --volume-id "$vol" 2>/dev/null || true
  done

  log "region $R: core resources deleted. NOTE: VPC/IGW/subnets/SGs and IAM roles"
  log "  may need a follow-up sweep once ENIs drain (run again, or finish via console)."

  # 10) C11 leftover report (REPORT-ONLY — outside this DeletionGroup's blast
  # radius, so never deleted here). These are the two leak classes that survived
  # multiple "zero-check PASS" teardowns before 2026-07-02 (79 EBS vols ~2.5 TB;
  # 24 secrets stuck in scheduled deletion blocking re-deploys):
  log "----- leftover report (region $R, NOT deleted — other/older deployments) -----"
  LEFT_VOLS=$(aws ec2 describe-volumes --region "$R" --filters Name=status,Values=available \
    --query "Volumes[?Tags[?Key=='Name' && starts_with(Value, 'besu-')]].[VolumeId,Size,Tags[?Key=='Name']|[0].Value]" --output text 2>/dev/null | grep -v "^$" || true)
  if [ -n "$LEFT_VOLS" ]; then
    log "AVAILABLE besu-* EBS volumes remain (orphans from other runs — billing!):"
    echo "$LEFT_VOLS" | sed 's/^/    /'
  else
    log "no leftover available besu-* EBS volumes"
  fi
  LEFT_SECRETS=$(aws secretsmanager list-secrets --region "$R" --include-planned-deletion \
    --query "SecretList[?starts_with(Name, 'besu')].Name" --output text 2>/dev/null || true)
  if [ -n "$LEFT_SECRETS" ]; then
    log "besu* secrets still present/scheduled (will COLLIDE with a re-deploy's fixed names):"
    echo "$LEFT_SECRETS" | tr '\t' '\n' | sed 's/^/    /'
  else
    log "no leftover besu* secrets (incl. scheduled deletion)"
  fi
done

ok "full-delete complete for DeletionGroup=${DG}. Verify in the console; re-run to sweep stragglers."

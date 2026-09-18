#!/usr/bin/env bash
# =============================================================================
# simulate-runner-policy.sh — will the runner's IAM policy survive a deploy?
# -----------------------------------------------------------------------------
# READ-ONLY. Creates nothing, changes nothing, costs nothing.
#
# WHY IT EXISTS
#   An IAM reduction fails at APPLY time, never at plan time. `terraform plan`
#   looks perfect and the run dies twenty minutes in with
#   `AccessDenied ... not authorized to perform <action>`, after money has been
#   spent and, on a chain apply, with half a stack standing.
#
#   `iam:SimulatePrincipalPolicy` answers the same question for free, before
#   anything is applied. It is not a proof -- it cannot model every condition
#   key, and a resource-scoped Allow may simulate as denied against the wildcard
#   ARN this script uses -- but it catches the whole class of "we dropped an
#   action the stack actually needs", which is the failure that costs a
#   deploy-test.
#
#   Run it before flipping `runner_scope = "in-cluster"` (CD-54), and after any
#   edit to `deploy_service_actions`.
#
# Usage:
#   scripts/validation/simulate-runner-policy.sh <runner-role-arn> [region]
#
#   Find the ARN:  terraform -chdir=terraform/runner output -raw runner_role_arn
# =============================================================================
set -euo pipefail

ROLE_ARN="${1:?usage: simulate-runner-policy.sh <runner-role-arn> [region]}"
REGION="${2:-${AWS_REGION:-af-south-1}}"

PASS=0; FAIL=0
ok()   { printf '  \033[32mALLOW\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mDENY \033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
sec()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v aws >/dev/null || { echo "aws CLI required" >&2; exit 1; }

# -----------------------------------------------------------------------------
# The actions each capability actually needs, grouped by the thing that breaks.
# Grouping matters: a bare list of denied actions tells you nothing, while "the
# in-cluster Terraform layer will fail" tells you what to do about it.
# -----------------------------------------------------------------------------
declare -A GROUPS=(
  [cluster-auth]="eks:DescribeCluster sts:GetCallerIdentity"
  [preflight-endpoints]="ec2:DescribeVpcEndpoints ec2:DescribeVpcs ec2:DescribeSecurityGroups ec2:DescribeSubnets"
  [preflight-images]="ecr:GetAuthorizationToken ecr:BatchGetImage ecr:GetDownloadUrlForLayer ecr:BatchCheckLayerAvailability"
  [terraform-state]="s3:GetObject s3:PutObject s3:DeleteObject s3:ListBucket"
  [pki-and-permissioning]="secretsmanager:GetSecretValue secretsmanager:PutSecretValue secretsmanager:DescribeSecret kms:Decrypt kms:GenerateDataKey"
  [diagnosis]="logs:FilterLogEvents logs:DescribeLogGroups cloudwatch:GetMetricData eks:ListClusters elasticloadbalancing:DescribeLoadBalancers"
)

# Actions that must be DENIED once runner_scope = "in-cluster". A pass here is a
# finding: it means the narrow policy is not actually narrow, or the broad one is
# still attached.
EXPECT_DENIED="iam:CreateRole iam:PutRolePolicy iam:PassRole kms:CreateKey ec2:RunInstances eks:CreateCluster cloudtrail:DeleteTrail"

printf '\n=== simulating %s ===\n' "$ROLE_ARN"

simulate() {
  # SimulatePrincipalPolicy returns one EvaluationResult per action.
  aws iam simulate-principal-policy \
      --policy-source-arn "$ROLE_ARN" \
      --action-names $1 \
      --region "$REGION" \
      --query 'EvaluationResults[].[EvalActionName,EvalDecision]' \
      --output text 2>/dev/null
}

for g in cluster-auth preflight-endpoints preflight-images terraform-state pki-and-permissioning diagnosis; do
  sec "$g"
  if ! out=$(simulate "${GROUPS[$g]}"); then
    echo "  could not simulate (needs iam:SimulatePrincipalPolicy on the caller)" >&2
    exit 1
  fi
  while read -r action decision; do
    [[ -n "$action" ]] || continue
    case "$decision" in
      allowed) ok "$action" ;;
      # A resource-scoped Allow simulates as implicitDeny against the wildcard
      # resource this script uses, so say so rather than crying wolf.
      *) bad "$action  ($decision — if this action is resource-scoped in the policy, re-check it against a real ARN before treating it as a gap)" ;;
    esac
  done <<<"$out"
done

sec "must be DENIED under runner_scope = in-cluster"
if out=$(simulate "$EXPECT_DENIED"); then
  while read -r action decision; do
    [[ -n "$action" ]] || continue
    if [[ "$decision" == "allowed" ]]; then
      printf '  \033[31mFINDING\033[0m  %s is ALLOWED — the narrow policy is not attached, or not narrow\n' "$action"
      FAIL=$((FAIL+1))
    else
      printf '  \033[32mok\033[0m       %s correctly denied\n' "$action"
    fi
  done <<<"$out"
fi

printf '\n=== %d allowed, %d to look at ===\n' "$PASS" "$FAIL"
cat <<'MSG'

This is a screen, not a proof. It cannot model every condition key, and a
resource-scoped Allow can simulate as denied against a wildcard ARN. What it
does reliably catch is a dropped action the stack needs -- the failure that
otherwise costs a billed deploy-test. Validate on a mock before go-live (H5).
MSG
[[ "$FAIL" -eq 0 ]] || exit 1

#!/usr/bin/env bash
# =============================================================================
# verify-pull-canary.sh — can THE CLUSTER pull from our registry?  (#38, D-38)
# -----------------------------------------------------------------------------
# READ-ONLY to everything that matters; creates and deletes exactly one Pod in
# our own namespace. Free. About thirty seconds.
#
# WHY IT EXISTS
#   verify-images.sh proves the images exist and that the HOST RUNNING IT can
#   pull them. It authenticates as itself. Under CT-5 the pull that matters is
#   kubelet's, with the cloud team's node role via the ECR credential provider:
#   a different principal, evaluated against the repository policy and that
#   role's own identity policy. verify-images.sh never exercises either, and
#   exits 0 regardless — the exact "check that cannot fail" this programme has
#   already been bitten by once (CICD design notes 11.3).
#
#   The only way to prove the cluster can pull is to make the cluster pull. One
#   pod, one small image, our namespace, before anything expensive exists.
#
# WHAT A FAILURE MEANS
#   Distinguishing the causes matters, because they land on different desks:
#     - ImagePullBackOff with "no basic auth credentials" / "authorization
#       token"  -> the node role lacks ecr:GetAuthorizationToken in its IDENTITY
#       policy. No repository policy can grant this. Cloud team (#38).
#     - ImagePullBackOff with "denied" / "not authorized to perform"
#       -> the repository policy does not grant their node role. Ours to fix in
#       the shared-services account (#38), or theirs if ECR is managed centrally.
#     - ImagePullBackOff with "manifest unknown" -> the digest is not mirrored.
#       Ours: run the mirror (D-18, by digest only).
#     - The pull STALLS with no event text at all -> a network cause, not an
#       authorisation one: the S3 layer-bucket policy (#20), Private DNS on
#       ecr.api/ecr.dkr (#22), or the ECR endpoint policy scoped to one account
#       (#23). Run verify-endpoints.sh. In this VPC these HANG, they do not error.
#
# Usage:
#   scripts/preflight/verify-pull-canary.sh -n <namespace> -i <image-ref> [-t secs]
#       [--check-policy <node-role-arn> -R <repo> [-R <repo> ...]]
#
# --check-policy reads our ECR repository policies and reports whether they name
# the cloud team's node role with all three pull actions. It runs BEFORE the
# canary, because it names the likely CAUSE while the canary proves the VERDICT.
# It lives here rather than in modules/cluster-contract because THERE IS NO
# `aws_ecr_repository_policy` DATA SOURCE — a Terraform plan cannot read an
# existing repository policy at all, and declaring one as a resource would mean
# this project started owning a central registry's policies. One `aws ecr
# get-repository-policy` call answers it instead.
#
# The image ref should be one we already mirror — a tools/busybox-class image is
# ideal because it is small and we are testing the PATH, not the image. Take it
# from `verify-images.sh -e <env>` output so the two agree on the digest.
# =============================================================================
set -euo pipefail

NS=""; IMAGE=""; TIMEOUT=120; NODE_ROLE=""; REPOS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NS="$2"; shift 2 ;;
    -i) IMAGE="$2"; shift 2 ;;
    -t) TIMEOUT="$2"; shift 2 ;;
    -R) REPOS+=("$2"); shift 2 ;;
    --check-policy) NODE_ROLE="$2"; shift 2 ;;
    -h|--help) sed -n '2,56p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# No defaults for either. A defaulted namespace would test a namespace the
# operator is not deploying into; a defaulted image would test an image we do
# not ship. Both would produce a confident PASS about the wrong thing.
[[ -n "$NS"    ]] || { echo "usage: verify-pull-canary.sh -n <namespace> -i <image-ref> [-t secs]" >&2; exit 2; }
[[ -n "$IMAGE" ]] || { echo "usage: verify-pull-canary.sh -n <namespace> -i <image-ref> [-t secs]" >&2; exit 2; }

command -v kubectl >/dev/null || { echo "kubectl is required" >&2; exit 1; }

POD="pull-canary-$$"
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*" >&2; }
note() { printf '        %s\n' "$*"; }

# Always remove the canary, including on Ctrl-C or a failed wait. A leaked pod in
# ImagePullBackOff retries forever and would be read by the next operator as a
# live incident rather than the residue of a test.
cleanup() { kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# #38, first half — do our repository policies name THEIR node role?
# -----------------------------------------------------------------------------
# kubelet's ECR credential provider needs all three actions. Granting two of the
# three is worse than granting none: the pull fails partway through with no
# message that names a policy.
POLICY_FAIL=0
if [[ -n "$NODE_ROLE" ]]; then
  if [[ ${#REPOS[@]} -eq 0 ]]; then
    echo "--check-policy needs at least one -R <repository>" >&2; exit 2
  fi
  command -v aws >/dev/null || { echo "aws CLI required for --check-policy" >&2; exit 1; }
  command -v jq  >/dev/null || { echo "jq required for --check-policy" >&2; exit 1; }
  printf '\n=== #38 repository policies (cause) ===\n'
  note "node role: $NODE_ROLE"
  for repo in "${REPOS[@]}"; do
    # SAME ACCOUNT: a repository policy is not needed at all — the node role's
    # identity policy alone governs a same-account pull. Without this, a
    # single-account registry FAILed with "their node role cannot pull" while
    # the canary below proved it could (B36, 2026-10-10). The bank's registry is
    # cross-account (CD-27), where the policy check below is the real question.
    reg_acct="$(aws ecr describe-repositories --repository-names "$repo" \
                  --query 'repositories[0].registryId' --output text 2>/dev/null || true)"
    role_acct="$(cut -d: -f5 <<<"$NODE_ROLE")"
    if [[ -n "$reg_acct" && "$reg_acct" == "$role_acct" ]]; then
      ok "$repo is in the node role's own account ($reg_acct) — no repository policy needed; its identity policy decides, and the canary tests that"
      continue
    fi
    pol="$(aws ecr get-repository-policy --repository-name "$repo" \
             --query policyText --output text 2>/dev/null || true)"
    if [[ -z "$pol" || "$pol" == "None" ]]; then
      bad "$repo has NO repository policy — their node role cannot pull (#38)"
      note "A repository with no policy is private to its owning account. Cross-account"
      note "pull is granted by the repository policy and nothing else."
      POLICY_FAIL=1; continue
    fi
    # One jq pass: is there an Allow statement naming this principal with all three?
    if jq -e --arg r "$NODE_ROLE" '
          ([.Statement] | flatten)
          | map(select(.Effect == "Allow"))
          | map(select(
              ((.Principal.AWS? // .Principal? // []) | if type=="string" then [.] else . end)
              | index($r) != null))
          | map([ (.Action | if type=="string" then [.] else . end) ] | flatten)
          | map(. as $a
                | ["ecr:BatchGetImage","ecr:GetDownloadUrlForLayer","ecr:BatchCheckLayerAvailability"]
                | all(. as $need | ($a | index($need) != null) or ($a | index("ecr:*") != null) or ($a | index("*") != null)))
          | any' >/dev/null 2>&1 <<<"$pol"; then
      ok "$repo grants $NODE_ROLE all three pull actions"
    else
      bad "#38: $repo does NOT grant $NODE_ROLE all of BatchGetImage, GetDownloadUrlForLayer, BatchCheckLayerAvailability"
      note "Every pod will ImagePullBackOff against a registry that looks fully populated."
      POLICY_FAIL=1
    fi
  done
  note "This covers only the half a repository policy can express. The node role ALSO"
  note "needs ecr:GetAuthorizationToken in its own IDENTITY policy, which no repository"
  note "policy can grant and which we cannot read cross-account. The canary below is the"
  note "only check that exercises both halves, because it is the only one that pulls as"
  note "that role."
fi

printf '\n=== #38 registry pull canary ===\n'
note "namespace: $NS"
note "image:     $IMAGE"
echo

# `command: ["false"]` would make the pod Error after a SUCCESSFUL pull, which is
# indistinguishable from what we want to measure. Sleep briefly instead: Running
# (or Completed) both prove the image was pulled, which is the only question.
#
# The pod must be ADMISSIBLE in the namespace we deploy into, or this script
# measures admission and never reaches the registry. A bare `kubectl run` has
# no resources and no securityContext, so it was refused by any ResourceQuota
# that names requests (#27 asks for exactly that — P-1's lesson) and by
# `restricted` Pod Security. Explicit small requests/limits (cpu limit too: a
# quota that does not track limits.cpu ignores it) and a restricted-compliant
# securityContext make the pull the only thing under test. uid 65534 because
# the image's own user may be root, which `restricted` refuses.
OVERRIDES=$(cat <<JSON
{"apiVersion":"v1","spec":{
  "securityContext":{"runAsNonRoot":true,"runAsUser":65534,"runAsGroup":65534,"seccompProfile":{"type":"RuntimeDefault"}},
  "containers":[{"name":"$POD","image":"$IMAGE","command":["/bin/sh","-c","exit 0"],
    "resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"100m","memory":"64Mi"}},
    "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}
JSON
)
if ! kubectl -n "$NS" run "$POD" \
      --image="$IMAGE" --restart=Never --overrides="$OVERRIDES" \
      --command -- /bin/sh -c 'exit 0' >/dev/null 2>&1; then
  # A refusal HERE is admission, not the registry — PSA (#27) or RBAC (#32).
  bad "the API server refused to create the canary pod. This is NOT a registry failure."
  note "Most likely Pod Security (#27) or the access entry's RBAC (#32)."
  note "Re-run with -v to see it:  kubectl -n $NS run $POD --image=$IMAGE --restart=Never"
  exit 1
fi

# Wait for ANY terminal-for-our-purposes state. We cannot use `kubectl wait
# --for=condition=Ready` alone: a pod that pulled and exited 0 is Succeeded and
# never becomes Ready, and a pod stuck in ImagePullBackOff never becomes
# anything — so wait on the pull, not on the pod.
PULLED=0; REASON=""; MSG=""
deadline=$(( $(date +%s) + TIMEOUT ))
while [[ $(date +%s) -lt $deadline ]]; do
  phase=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  REASON=$(kubectl -n "$NS" get pod "$POD" \
            -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
  MSG=$(kubectl -n "$NS" get pod "$POD" \
            -o jsonpath='{.status.containerStatuses[0].state.waiting.message}' 2>/dev/null || echo "")
  case "$phase" in
    Running|Succeeded) PULLED=1; break ;;
  esac
  # Terminal pull failures: stop waiting, we already have the answer.
  case "$REASON" in
    ImagePullBackOff|ErrImagePull|InvalidImageName|RegistryUnavailable) break ;;
  esac
  sleep 3
done

echo
if [[ "$PULLED" -eq 1 ]]; then
  ok "the cluster pulled $IMAGE"
  note "This is the only check that proves the NODE ROLE can pull (#38)."
  note "It does not prove the other images are mirrored — that is verify-images.sh."
  if [[ "$POLICY_FAIL" -eq 1 ]]; then
    bad "...but a repository policy check above FAILED. The canary image is pullable and"
    note "at least one other repository is not, so some pods will ImagePullBackOff. Fix"
    note "the policy before deploying; do not read this PASS as the supply chain being proven."
    exit 1
  fi
  exit 0
fi

bad "#38 VIOLATED: the cluster could NOT pull $IMAGE"
note "waiting reason: ${REASON:-<none — the pull STALLED, which in this VPC is the network class>}"
[[ -n "$MSG" ]] && note "kubelet said: $MSG"
echo
# Classify, because the three causes go to three different places.
case "$MSG" in
  *"no basic auth"*|*"authorization token"*|*"GetAuthorizationToken"*)
    note "CAUSE: the node role lacks ecr:GetAuthorizationToken in its IDENTITY policy."
    note "       No repository policy can grant this. -> cloud team, #38." ;;
  *denied*|*"not authorized"*|*AccessDenied*)
    note "CAUSE: the repository policy does not grant their node role pull."
    note "       Needs ecr:BatchGetImage, GetDownloadUrlForLayer, BatchCheckLayerAvailability."
    note "       -> our shared-services account, or theirs if ECR is central. #38." ;;
  *"manifest unknown"*|*"not found"*|*MANIFEST_UNKNOWN*)
    note "CAUSE: that digest is not in the registry. -> run the mirror (D-18, by digest)." ;;
  *)
    note "CAUSE: no authorisation error was reported, which points at the NETWORK, not the policy:"
    note "       the S3 layer-bucket policy (#20), Private DNS on ecr.api/ecr.dkr (#22),"
    note "       or an ECR endpoint policy scoped to one account (#23)."
    note "       Next: scripts/preflight/verify-endpoints.sh <vpc-id> <region> --route-tables <ids>" ;;
esac
echo
note "Recent events (the authoritative text):"
kubectl -n "$NS" describe pod "$POD" 2>/dev/null | sed -n '/^Events:/,$p' | sed 's/^/        /' || true
exit 1

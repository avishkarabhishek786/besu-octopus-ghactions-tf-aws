#!/usr/bin/env bash
# =============================================================================
# verify-cluster.sh — the cluster-side contract, from inside the VPC  (CT-5)
# -----------------------------------------------------------------------------
# READ-ONLY. Every call is a get or a SelfSubjectAccessReview. Free, ~15s.
# MUST run from the in-VPC runner: the API endpoint is private, so a laptop
# cannot ask these questions at all (D-34).
#
# WHY IT EXISTS
#   We do not own this cluster. Thirteen requirements in §9.3 of
#   NETWORK_REQUIREMENTS_CLOUD_TEAM.md describe things the cloud team configures
#   and we depend on, and almost every one of them fails SILENTLY — it hangs, or
#   it looks like success. This is the Kubernetes-side half of the gate set
#   (CLOUD_TEAM_REDESIGN_NOTES §12.13.2, class "K").
#
# WHAT IT CHECKS, AND THE REQUIREMENT EACH MAPS TO
#   #36  Kubernetes version inside the range Besu + our charts are tested against
#   #30  the four CRDs we consume, and whether a controller is actually RUNNING
#   #30  the StorageClass's binding mode, expansion flag and encryption key
#   #27  the namespace's Pod Security labels (NOT authoritative — see below)
#   #27  ResourceQuota HEADROOM against our footprint, and LimitRange bounds
#   #32  what our role may do in our namespace — and what it must NOT do elsewhere
#   #35  whether the CNI enforces NetworkPolicy at all
#
# TWO THINGS IT DELIBERATELY DOES NOT CLAIM
#   * Pod Security: the namespace labels are read for information only. PSA can
#     be enforced cluster-wide through the API server's AdmissionConfiguration,
#     which is invisible here. The authoritative check is a bare-Pod dry-run:
#     scripts/preflight/verify-admission.sh (D-40).
#   * A CRD existing is not a controller reconciling. Where our namespace-scoped
#     access (#32) cannot see the controller's namespace, this reports WARN and
#     not PASS — the proof moves to the post-deploy target-registration gate.
#     Reporting PASS for "we could not look" is how a check becomes decorative.
#
# Usage:
#   scripts/preflight/verify-cluster.sh -n <ledger-ns> [-a <app-ns>] [-s <storageclass>]
#                                       [--cpu 8] [--mem 24Gi] [--pods 40] [--pvc 12]
#                                       [--k8s-min 1.33] [--k8s-max 1.36]
#
# The footprint defaults are the §9.1 table. They are defaults, not a second copy
# of the source of truth: if §9.1 changes, pass the new numbers or change them
# HERE and nowhere else (CD-12).
# =============================================================================
set -euo pipefail

NS=""; APP_NS=""; SC=""
REQ_CPU="8"; REQ_MEM="24Gi"; REQ_PODS="40"; REQ_PVC="12"
K8S_MIN="1.33"; K8S_MAX="1.36"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NS="$2"; shift 2 ;;
    -a) APP_NS="$2"; shift 2 ;;
    -s) SC="$2"; shift 2 ;;
    --cpu)     REQ_CPU="$2"; shift 2 ;;
    --mem)     REQ_MEM="$2"; shift 2 ;;
    --pods)    REQ_PODS="$2"; shift 2 ;;
    --pvc)     REQ_PVC="$2"; shift 2 ;;
    --k8s-min) K8S_MIN="$2"; shift 2 ;;
    --k8s-max) K8S_MAX="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$NS" ]] || { echo "usage: verify-cluster.sh -n <ledger-ns> [-a <app-ns>] [-s <storageclass>]" >&2; exit 2; }
command -v kubectl >/dev/null || { echo "kubectl is required" >&2; exit 1; }
command -v jq      >/dev/null || { echo "jq is required" >&2; exit 1; }

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; WARN=$((WARN+1)); }
sec()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '        %s\n' "$*"; }

# --- unit helpers ------------------------------------------------------------
# Quota values arrive as Kubernetes quantities ("8", "8500m", "24Gi", "25000Mi").
# Comparing them as strings is how a 900m-vs-8 difference goes unnoticed.
to_milli() { # cpu quantity -> millicores
  local q="${1:-0}"
  case "$q" in
    *m) printf '%s\n' "${q%m}" ;;
    "") printf '0\n' ;;
    *)  awk -v v="$q" 'BEGIN{printf "%d\n", v*1000}' ;;
  esac
}
to_bytes() { # memory quantity -> bytes
  local q="${1:-0}" n u
  n="${q//[!0-9.]/}"; u="${q//[0-9.]/}"
  [[ -n "$n" ]] || { printf '0\n'; return; }
  case "$u" in
    Ki) awk -v n="$n" 'BEGIN{printf "%d\n", n*1024}' ;;
    Mi) awk -v n="$n" 'BEGIN{printf "%d\n", n*1024*1024}' ;;
    Gi) awk -v n="$n" 'BEGIN{printf "%d\n", n*1024*1024*1024}' ;;
    Ti) awk -v n="$n" 'BEGIN{printf "%d\n", n*1024*1024*1024*1024}' ;;
    K|k) awk -v n="$n" 'BEGIN{printf "%d\n", n*1000}' ;;
    M)  awk -v n="$n" 'BEGIN{printf "%d\n", n*1000000}' ;;
    G)  awk -v n="$n" 'BEGIN{printf "%d\n", n*1000000000}' ;;
    *)  awk -v n="$n" 'BEGIN{printf "%d\n", n}' ;;
  esac
}
human_gib() { awk -v b="${1:-0}" 'BEGIN{printf "%.1fGiB\n", b/1073741824}'; }
# ver_le a b -> true if a <= b, comparing as dotted versions
ver_le() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; }

printf '\n=== cluster contract: namespace %s ===\n' "$NS"
kubectl version -o json >/dev/null 2>&1 \
  || { echo "cannot reach the API server. From the runner? kubeconfig current-context set?" >&2; exit 1; }

# -----------------------------------------------------------------------------
# #36 — Kubernetes version
# -----------------------------------------------------------------------------
# The upper bound is the point. A cluster NEWER than we have tested breaks on our
# NEXT apply, when a removed API version stops a chart reconciling — long after
# their upgrade landed, with nothing connecting the two. (D-41; the plan-time
# version of this gate lives in modules/cluster-contract.)
sec "#36  Kubernetes version"
SRV="$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.major + "." + (.serverVersion.minor|gsub("[^0-9]";""))')"
if [[ -z "$SRV" || "$SRV" == "." ]]; then
  warn "could not read the server version"
elif ! ver_le "$K8S_MIN" "$SRV"; then
  bad "#36: cluster is $SRV, below the tested floor $K8S_MIN"
elif ! ver_le "$SRV" "$K8S_MAX"; then
  bad "#36: cluster is $SRV, ABOVE the validated ceiling $K8S_MAX — run the Besu/chart compatibility pass before deploying"
  note "This is the upgrade-without-notice case (#29 item 3). Do not widen the ceiling to make it pass."
else
  ok "cluster is $SRV (tested range $K8S_MIN..$K8S_MAX)"
fi

# -----------------------------------------------------------------------------
# #30 — CRDs, and whether anything reconciles them
# -----------------------------------------------------------------------------
sec "#30  Cluster add-ons: CRD present AND a controller running"
check_crd() { # <crd> <what breaks> <controller label selector> <hard|soft>
  local crd="$1" breaks="$2" selector="$3" severity="$4" dep
  if ! kubectl get crd "$crd" >/dev/null 2>&1; then
    if [[ "$severity" == hard ]]; then
      bad "#30: CRD $crd is ABSENT — $breaks"
    else
      warn "#30: CRD $crd is absent — $breaks"
    fi
    return
  fi
  # A CRD proves only that something once installed it. It survives an uninstall.
  dep="$(kubectl get deploy -A -l "$selector" \
          -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}:{.status.readyReplicas}/{.spec.replicas} {end}' 2>/dev/null || true)"
  if [[ -z "$dep" ]]; then
    warn "#30: CRD $crd exists but we cannot see a controller for it"
    note "Either it runs under a label we did not guess, or our namespace-scoped access (#32)"
    note "cannot list deployments cluster-wide. NOT a pass: a CRD with no controller accepts"
    note "our objects and reconciles nothing. Proof moves to the post-deploy gate."
  elif [[ "$dep" == *":0/"* || "$dep" == *":/"* ]]; then
    bad "#30: CRD $crd exists but its controller has NO ready replicas — $dep"
    note "Our objects will be accepted and never acted on. $breaks"
  else
    ok "CRD $crd + controller $dep"
  fi
}
check_crd targetgroupbindings.elbv2.k8s.aws \
  "no RPC endpoint can be exposed; there is NO fallback (hard requirement)" \
  "app.kubernetes.io/name=aws-load-balancer-controller" hard
check_crd secretproviderclasses.secrets-store.csi.x-k8s.io \
  "fallback: fetch from Secrets Manager at pod start via the pod's IAM role (D-24)" \
  "app.kubernetes.io/name=secrets-store-csi-driver" soft
check_crd podmonitors.monitoring.coreos.com \
  "fallback: a plain Prometheus in our namespace (D-24)" \
  "app.kubernetes.io/name=prometheus-operator" soft
check_crd prometheusrules.monitoring.coreos.com \
  "fallback: alert rules on our own Prometheus (D-24)" \
  "app.kubernetes.io/name=prometheus-operator" soft
# Not one of the four: present only if #33 was answered with Security Groups for Pods.
if kubectl get crd securitygrouppolicies.vpcresources.k8s.aws >/dev/null 2>&1; then
  ok "CRD securitygrouppolicies.vpcresources.k8s.aws present (#33 via SGP is available)"
  note "If SGP is the chosen route, the post-deploy gate must confirm the RPC pods actually"
  note "carry the vpc.amazonaws.com/pod-eni annotation — a selector that misses is SILENT."
else
  note "no SecurityGroupPolicy CRD: #33 must be the node-SG ingress rule instead (question D)."
fi

# -----------------------------------------------------------------------------
# #30 — the StorageClass
# -----------------------------------------------------------------------------
sec "#30  StorageClass"
if [[ -z "$SC" ]]; then
  warn "no -s <storageclass> given; skipping. Pass the class the cloud team told us to use."
  kubectl get storageclass -o custom-columns='NAME:.metadata.name,PROVISIONER:.provisioner,BINDING:.volumeBindingMode,EXPAND:.allowVolumeExpansion' 2>/dev/null | sed 's/^/        /' || true
elif ! SCJSON="$(kubectl get storageclass "$SC" -o json 2>/dev/null)"; then
  bad "#30: StorageClass '$SC' does not exist — the chain has nowhere to put its data"
else
  BIND="$(jq -r '.volumeBindingMode // "Immediate"' <<<"$SCJSON")"
  EXPAND="$(jq -r '.allowVolumeExpansion // false' <<<"$SCJSON")"
  ENCRYPT="$(jq -r '.parameters.encrypted // "unset"' <<<"$SCJSON")"
  KMS="$(jq -r '.parameters.kmsKeyId // ""' <<<"$SCJSON")"
  if [[ "$BIND" == "WaitForFirstConsumer" ]]; then
    ok "volumeBindingMode=WaitForFirstConsumer"
  else
    bad "#30: volumeBindingMode=$BIND. The volume is provisioned BEFORE the pod is scheduled and pinned to whichever AZ the provisioner picked"
    note "With validators spread across three AZs, one can end up permanently Pending with"
    note "its data in the wrong zone — and the message says only 'no nodes available'."
  fi
  if [[ "$EXPAND" == "true" ]]; then
    ok "allowVolumeExpansion=true"
  else
    bad "#30: allowVolumeExpansion=false. The chain grows; without this the first disk-full is an incident, not a change request"
  fi
  [[ "$ENCRYPT" == "true" ]] && ok "encrypted=true" || warn "#30: encrypted=$ENCRYPT on a financial ledger's data volumes"
  if [[ -n "$KMS" ]]; then
    note "KMS key: $KMS"
    note "If this key is THEIRS, chain data is encrypted under a key we cannot audit or hold,"
    note "and a key-policy change on their side stops the ledger. Record it either way (#30)."
  else
    note "no explicit kmsKeyId: volumes use the account's EBS default key."
  fi
fi

# -----------------------------------------------------------------------------
# #27 — Pod Security labels (information), quota and LimitRange (arithmetic)
# -----------------------------------------------------------------------------
sec "#27  Namespace: Pod Security labels, quota headroom, LimitRange"
for n in "$NS" ${APP_NS:+$APP_NS}; do
  if ! NSJSON="$(kubectl get ns "$n" -o json 2>/dev/null)"; then
    bad "#27: namespace '$n' does not exist (or we cannot read it)"
    continue
  fi
  ENFORCE="$(jq -r '.metadata.labels["pod-security.kubernetes.io/enforce"] // "unset"' <<<"$NSJSON")"
  note "$n: pod-security enforce=$ENFORCE audit=$(jq -r '.metadata.labels["pod-security.kubernetes.io/audit"] // "unset"' <<<"$NSJSON")"
  case "$ENFORCE" in
    restricted)
      bad "#27: namespace $n enforces 'restricted'. Our F32 ownership-fix init container runs as uid 0 and is refused at admission (D-33)"
      note "Ask for 'baseline', or rework the init container non-root first." ;;
    baseline|privileged)
      ok "$n enforce=$ENFORCE admits the validator pod template" ;;
    unset)
      warn "#27: no enforce label on $n. This does NOT mean unrestricted — PSA can be set cluster-wide via AdmissionConfiguration, which is invisible from here (question K)"
      note "Authoritative check: scripts/preflight/verify-admission.sh -n $n -f <rendered.yaml>" ;;
  esac
done

QJSON="$(kubectl -n "$NS" get resourcequota -o json 2>/dev/null || echo '{"items":[]}')"
if [[ "$(jq '.items | length' <<<"$QJSON")" -eq 0 ]]; then
  warn "#27: no ResourceQuota on $NS. Nothing to exceed — but confirm one is coming, because it will arrive AFTER we size for no quota"
else
  # Process substitution, NOT a pipe. `jq ... | while read` puts the loop body in a
  # SUBSHELL, so every ok()/bad() inside it increments a copy of the counters and the
  # exit code comes out 0 with quota failures printed above it. That is precisely the
  # "check that cannot fail" defect these scripts exist to catch (CICD notes 11.3), and
  # it was present in the first draft of this file.
  while IFS= read -r q; do
    QN="$(jq -r '.metadata.name' <<<"$q")"
    note "quota $QN:"
    # The arithmetic is the point. A quota a few hundred millicores short admits
    # THREE validators and refuses the fourth. QBFT's quorum is 3 of 4, so the chain
    # starts, produces blocks and reports healthy with ZERO fault tolerance — and the
    # refusal is an event on the StatefulSet, with no fourth pod to inspect (D-36).
    for pair in "requests.cpu:$REQ_CPU:cpu" "requests.memory:$REQ_MEM:mem" \
                "limits.cpu:$REQ_CPU:cpu" "limits.memory:$REQ_MEM:mem" \
                "pods:$REQ_PODS:count" "persistentvolumeclaims:$REQ_PVC:count"; do
      key="${pair%%:*}"; rest="${pair#*:}"; want="${rest%%:*}"; kind="${rest##*:}"
      hard="$(jq -r --arg k "$key" '.status.hard[$k] // ""' <<<"$q")"
      used="$(jq -r --arg k "$key" '.status.used[$k] // "0"' <<<"$q")"
      # No hard limit on this dimension means nothing to exceed. Skipping is correct
      # here (unlike skipping because we could not READ it, which is a WARN).
      [[ -n "$hard" ]] || continue
      case "$kind" in
        cpu)   h=$(to_milli "$hard"); u=$(to_milli "$used"); w=$(to_milli "$want")
               show_hard="${h}m"; show_used="${u}m"; show_want="${w}m" ;;
        mem)   h=$(to_bytes "$hard"); u=$(to_bytes "$used"); w=$(to_bytes "$want")
               show_hard="$(human_gib "$h")"; show_used="$(human_gib "$u")"; show_want="$(human_gib "$w")" ;;
        count) h="$hard"; u="$used"; w="$want"
               show_hard="$h"; show_used="$u"; show_want="$w" ;;
      esac
      # Compare the CEILING, not the headroom. The namespace is ours alone (#27 asks
      # for dedicated namespaces), so nothing else consumes this quota — which means
      # `used` is OUR OWN pods. Subtracting it would make the check fail on every
      # redeploy and pass only on an empty namespace: a gate that is wrong in the
      # common case gets disabled, and a disabled gate catches nothing.
      # `used` is printed for context, never used in the decision.
      if (( h >= w )); then
        ok "quota $key: ceiling $show_hard >= footprint $show_want (currently using $show_used)"
      else
        bad "#27 quota $key: ceiling $show_hard, FOOTPRINT NEEDS $show_want (using $show_used)"
        note "A short quota admits 3 of 4 validators and refuses the fourth. The chain will"
        note "look HEALTHY with zero fault tolerance. Quote the §9.1 footprint table back."
      fi
    done
  done < <(jq -c '.items[]' <<<"$QJSON")
fi

LRJSON="$(kubectl -n "$NS" get limitrange -o json 2>/dev/null || echo '{"items":[]}')"
if [[ "$(jq '.items | length' <<<"$LRJSON")" -gt 0 ]]; then
  note "LimitRange present — check its max/default against §9.1 (a max below our request refuses the pod):"
  jq -r '.items[].spec.limits[] | "          type=\(.type) max=\(.max // {}) default=\(.default // {}) defaultRequest=\(.defaultRequest // {})"' <<<"$LRJSON"
else
  ok "no LimitRange on $NS to conflict with our requests"
fi

# -----------------------------------------------------------------------------
# #32 — what we may do here, and what we must NOT do elsewhere
# -----------------------------------------------------------------------------
# D-37: a boundary works identically whether it is present or missing, so the
# only proof is a probe that MUST FAIL. The negatives below are the whole reason
# this section exists; the positives would be discovered anyway, loudly, on the
# first deploy.
sec "#32  Access scope — positives, then NEGATIVES (D-37)"
cani() { kubectl auth can-i "$@" 2>/dev/null | tr -d '[:space:]'; }

for v in "create statefulsets" "create services" "create configmaps" "create secrets" \
         "create persistentvolumeclaims" "create poddisruptionbudgets" "create networkpolicies"; do
  # shellcheck disable=SC2086
  if [[ "$(cani ${v} -n "$NS")" == "yes" ]]; then ok "may $v in $NS"
  else bad "#32: may NOT $v in $NS — nothing can be deployed"; fi
done
for crdkind in targetgroupbindings secretproviderclasses podmonitors prometheusrules; do
  if [[ "$(cani create "$crdkind" -n "$NS")" == "yes" ]]; then
    ok "may create $crdkind in $NS"
  else
    bad "#32: may NOT create $crdkind in $NS"
    note "Expected: 'edit' enumerates BUILT-IN kinds. Custom resources are covered only if the"
    note "add-on ships a ClusterRole labelled aggregate-to-edit, which is not guaranteed."
    note "Ask for an explicit Role on the four kinds in our namespaces (#32)."
  fi
done

# The negatives. A 'yes' here is not a convenience — it is a grant we did not ask
# for, that we would have to explain in a review, and that nothing else reports.
for probe in "create pods:-n kube-system" "delete nodes:" "create clusterrolebindings:" \
             "list secrets:--all-namespaces" "create namespaces:"; do
  verb="${probe%%:*}"; scope="${probe#*:}"
  # shellcheck disable=SC2086
  res="$(cani ${verb} ${scope})"
  if [[ "$res" == "no" ]]; then
    ok "correctly DENIED: $verb ${scope:-(cluster-wide)}"
  else
    bad "#32: ALLOWED to '$verb ${scope:-(cluster-wide)}' — the grant is broader than we asked for"
    note "This is the silent direction of #32: a cluster-wide grant works exactly as well as a"
    note "scoped one, so nothing would ever have told us. Ask for AmazonEKSEditPolicy scoped to"
    note "our namespaces, or a Role + RoleBinding."
  fi
done

# -----------------------------------------------------------------------------
# #35 — does anything enforce NetworkPolicy?
# -----------------------------------------------------------------------------
sec "#35  NetworkPolicy enforcement"
if AWSNODE="$(kubectl -n kube-system get ds aws-node -o json 2>/dev/null)"; then
  NPENV="$(jq -r '[.spec.template.spec.containers[]?.env[]? | select(.name|test("NETWORK_POLICY|POD_ENI"))
                   | "\(.name)=\(.value)"] | join(" ")' <<<"$AWSNODE")"
  note "aws-node: ${NPENV:-<neither NETWORK_POLICY nor POD_ENI set>}"
  if [[ "$NPENV" == *"ENABLE_NETWORK_POLICY=true"* ]]; then
    ok "VPC CNI network policy is enabled"
  else
    bad "#35: the VPC CNI does not have network policy enabled"
    note "The API server ACCEPTS NetworkPolicy objects regardless. Our default-deny policies"
    note "would be accepted and enforced by nothing, and every pod in this shared cluster could"
    note "reach the validators' privileged RPC. Unless Calico/Cilium is installed instead —"
    note "check, then prove it with the deny-probe, not with configuration."
  fi
elif kubectl get crd installations.operator.tigera.io >/dev/null 2>&1 || kubectl get crd ciliumnetworkpolicies.cilium.io >/dev/null 2>&1; then
  ok "a third-party policy CNI (Calico/Cilium) appears to be installed"
else
  warn "#35: cannot read kube-system/aws-node (expected with namespace-scoped access, #32) and saw no Calico/Cilium CRDs"
  note "Configuration is unreadable from here, so it must be PROVEN instead: the two-pod"
  note "deny-probe in the post-deploy gate is the only evidence that survives (D-37)."
fi

printf '\n=== %d passed, %d failed, %d warnings ===\n' "$PASS" "$FAIL" "$WARN"
printf 'Pod Security is NOT decided here. Run: scripts/preflight/verify-admission.sh -n %s -f <rendered.yaml>\n' "$NS"
[[ "$FAIL" -eq 0 ]] || { echo "The cluster does not meet the contract. Each failure names a requirement number from NETWORK_REQUIREMENTS_CLOUD_TEAM.md §9.3." >&2; exit 1; }

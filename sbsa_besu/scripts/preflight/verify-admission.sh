#!/usr/bin/env bash
# =============================================================================
# verify-admission.sh — will the namespace actually ACCEPT our pods?  (D-40)
# -----------------------------------------------------------------------------
# READ-ONLY: every submission is --dry-run=server. Nothing is created. Free.
#
# WHY IT EXISTS
#   Under CT-5 the namespace is configured by someone else, and four separate
#   admission controllers can refuse our workloads: Pod Security (#27),
#   ResourceQuota (#27), LimitRange (#27) and RBAC (#32) — plus a missing CRD
#   (#30) is refused by the API server itself. Every one of those is cheap to
#   discover now and expensive to discover against a billing cluster.
#
#   --dry-run=server runs the real admission chain on the real cluster without
#   persisting anything, so it answers all five at once.
#
# THE TRAP THIS SCRIPT EXISTS TO AVOID  (the reason it is not a one-liner)
#   Pod Security does NOT reject a StatefulSet, Deployment or Job whose pod
#   template violates the policy. It evaluates the template and returns a
#   WARNING, because enforcement happens later, when the controller creates the
#   Pod. So:
#
#       helm template ... | kubectl apply --dry-run=server -f -
#
#   EXITS 0 ON A `restricted` NAMESPACE THAT WILL REFUSE EVERY VALIDATOR POD.
#   Our F32 ownership-fix init container runs as uid 0; on `restricted` the
#   StatefulSet applies, the controller then cannot create a single pod, and the
#   symptom is a StatefulSet with 0 replicas and an event nobody is watching.
#
#   Two things follow, and both are load-bearing:
#     1. We synthesise a BARE POD from each pod template and dry-run that too.
#        PSA enforces hard on a Pod, so the failure becomes an error.
#     2. ANY warning on ANY object is a FAILURE here, not a log line. A warning
#        is how this class announces itself.
#
# WHAT IT DOES NOT COVER
#   Quota ARITHMETIC. Admission checks one object against current usage, so a
#   quota that admits validator #1 but not all four passes here. The headroom sum
#   is verify-cluster.sh's job (#27), and the post-deploy count gate is the
#   backstop (D-36).
#
# Usage:
#   scripts/preflight/verify-admission.sh -n <namespace> -f <rendered.yaml> [-f ...]
#   helm template ... > /tmp/r.yaml && scripts/preflight/verify-admission.sh -n ledger -f /tmp/r.yaml
#
# Render with the SAME values Terraform will pass, or this proves the wrong pods.
# =============================================================================
set -euo pipefail

NS=""; FILES=()
while getopts "n:f:h" opt; do
  case "$opt" in
    n) NS="$OPTARG" ;;
    f) FILES+=("$OPTARG") ;;
    h) sed -n '2,47p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

[[ -n "$NS" ]]        || { echo "usage: verify-admission.sh -n <namespace> -f <rendered.yaml> [-f ...]" >&2; exit 2; }
[[ ${#FILES[@]} -gt 0 ]] || { echo "usage: verify-admission.sh -n <namespace> -f <rendered.yaml> [-f ...]" >&2; exit 2; }
for f in "${FILES[@]}"; do [[ -r "$f" ]] || { echo "cannot read $f" >&2; exit 2; }; done

command -v kubectl >/dev/null || { echo "kubectl is required" >&2; exit 1; }
command -v jq      >/dev/null || { echo "jq is required" >&2; exit 1; }

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
sec()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '        %s\n' "$*"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

printf '\n=== admission dry-run against namespace %s ===\n' "$NS"

# -----------------------------------------------------------------------------
# submit <label> <file> — dry-run one manifest, treating WARNINGS as failures.
# -----------------------------------------------------------------------------
# kubectl writes admission warnings to stderr and still exits 0. That is correct
# for kubectl and wrong for a gate, so stderr is captured and inspected rather
# than shown. This is the whole mechanism; if it is ever "simplified" to rely on
# the exit code, the PSA-on-a-controller case goes silent again.
submit() {
  local label="$1" file="$2" out rc=0
  out="$(kubectl -n "$NS" apply --dry-run=server -f "$file" 2>&1)" || rc=$?

  if [[ $rc -ne 0 ]]; then
    bad "$label — REJECTED"
    printf '%s\n' "$out" | sed 's/^/        /'
    classify "$out"
    return 1
  fi

  if grep -qi '^Warning:' <<<"$out"; then
    bad "$label — admission WARNING (treated as a failure: see the header of this script)"
    grep -i '^Warning:' <<<"$out" | sed 's/^/        /'
    classify "$out"
    return 1
  fi

  ok "$label"
  return 0
}

classify() {
  # Every matching cause is named, not just the first (B29: this was a `case`,
  # so a manifest refused for BOTH Pod Security and a missing CRD was reported
  # as Pod Security only, and the #30 half — the one with no fallback when the
  # CRD is TargetGroupBinding — went unmentioned).
  local text="$1" hit=0
  if grep -qiE 'PodSecurity|privileged|runAsNonRoot|allowPrivilegeEscalation' <<<"$text"; then hit=1
      note "-> #27: Pod Security. Our F32 ownership-fix init container runs as uid 0, which"
      note "   'restricted' refuses. Ask for 'baseline' on this namespace, or rework the init"
      note "   container non-root first (D-33). NOTE: PSA can also be enforced CLUSTER-WIDE via"
      note "   AdmissionConfiguration, which does not appear in the namespace labels (question K)."
  fi
  if grep -qiE 'exceeded quota|forbidden: exceeded|failed quota' <<<"$text"; then hit=1
      note "-> #27: ResourceQuota. Compare hard-minus-used against the footprint table in shared-cluster requirements §1."
      note "   Remember admission tests ONE pod: a quota that admits three validators and refuses"
      note "   the fourth passes here and still leaves QBFT one failure from a halt (D-36)."
      if grep -qiE 'must specify limits' <<<"$text"; then
        note "   'must specify limits.X': the quota sets limits.X, so EVERY container must declare"
        note "   one. Our charts set no CPU limits — ask for a quota without limits.cpu"
        note "   (shared-cluster requirements point 2 asks for requests + MEMORY limits only)."
      fi
  fi
  if grep -qiE 'LimitRange|minimum memory usage|maximum cpu usage' <<<"$text"; then hit=1
      note "-> #27: LimitRange defaults or maxima sit below/above our requests (shared-cluster requirements §1)."
  fi
  # kubectl apply says "resource mapping not found … ensure CRDs are installed
  # first"; kubectl create says "no matches for kind". Both mean the same thing.
  if grep -qiE 'no matches for kind|could not find the requested resource|resource mapping not found|ensure CRDs are installed' <<<"$text"; then hit=1
      note "-> #30: the CRD is not installed on this cluster. Which one is named above."
      note "   TargetGroupBinding has NO fallback (the RPC endpoints cannot be exposed without"
      note "   it); SecretProviderClass, PodMonitor and PrometheusRule each have one (D-24)."
  fi
  # RBAC only on an RBAC denial ("User … cannot …"). A bare "forbidden" also
  # appears on PSA and quota refusals and on a missing ServiceAccount, and B29
  # was exactly that: a missing SA reported as an RBAC grant to ask for.
  if grep -qiE 'forbidden: User .* cannot |cannot (create|get|list|patch|update) resource' <<<"$text"; then hit=1
      note "-> #32: RBAC. AmazonEKSEditPolicy follows the built-in 'edit' role, which enumerates"
      note "   BUILT-IN kinds — our four custom resources are covered only if the add-on ships a"
      note "   ClusterRole labelled aggregate-to-edit. Ask for an explicit Role."
  fi
  if grep -qiE 'error looking up service account' <<<"$text"; then hit=1
      note "-> NOT a cluster finding: the ServiceAccount does not exist yet (Terraform creates it"
      note "   at apply). If this appears on a bare-Pod probe the probe is broken — it should run"
      note "   as 'default' (B29)."
  fi
  [[ $hit -eq 1 ]] || note "-> unclassified refusal: read the server's message above."
}

# -----------------------------------------------------------------------------
# 1. The objects as rendered.
# -----------------------------------------------------------------------------
# Catches missing CRDs (#30), RBAC (#32) and quota/LimitRange on the objects that
# are created directly. Does NOT catch PSA — see 2.
sec "As rendered (CRDs, RBAC, quota)"
for f in "${FILES[@]}"; do
  submit "$(basename "$f")" "$f" || true
done

# -----------------------------------------------------------------------------
# 2. A bare Pod per pod template — the PSA-enforcing path.
# -----------------------------------------------------------------------------
# kubectl's client dry-run is used purely as a YAML->JSON converter, so this
# needs no python or yq on the runner (jq is already a dependency of the other
# preflights, kubectl is in the S3 bundle).
sec "Pod templates submitted as bare Pods (Pod Security enforces hard here)"
NPODS=0
for f in "${FILES[@]}"; do
  kubectl create -f "$f" --dry-run=client -o json 2>/dev/null \
    | jq -c '
        # Unwrap a List, otherwise pass the single object through.
        if .kind == "List" then .items[] else . end
        | select(.kind == "StatefulSet" or .kind == "Deployment"
              or .kind == "DaemonSet"  or .kind == "Job"
              or .kind == "ReplicaSet" or .kind == "ReplicationController")
        | {
            apiVersion: "v1",
            kind: "Pod",
            metadata: {
              # A distinct name per workload so a failure names the workload.
              name:   ((.metadata.name // "workload") + "-admission-probe"),
              labels: (.spec.template.metadata.labels // {}),
              annotations: (.spec.template.metadata.annotations // {})
            },
            # The ServiceAccount admission plugin runs BEFORE Pod Security and
            # rejects a Pod whose SA does not exist yet — which, before the first
            # apply, is every one of ours. That masked the PSA verdict this probe
            # exists to obtain (B29). PSA does not depend on the SA, so the probe
            # runs as the namespace default and mounts no token.
            #
            # The volumeClaimTemplates of a StatefulSet become volumes only when the
            # controller creates the Pod, so a bare Pod referencing them is
            # INVALID before PSA runs (found on the same run). Each claim template
            # is stood in for by an emptyDir, which every PSA level permits, so
            # the substitution cannot change the verdict.
            spec: ((.spec.volumeClaimTemplates // []) as $vct
                   | .spec.template.spec
                   | .serviceAccountName = "default"
                   | del(.serviceAccount)
                   | .automountServiceAccountToken = false
                   | .volumes = ((.volumes // []) + [$vct[] | {name: .metadata.name, emptyDir: {}}]))
          }' 2>/dev/null \
    | while IFS= read -r obj; do
        [[ -n "$obj" ]] || continue
        name="$(jq -r '.metadata.name' <<<"$obj")"
        printf '%s' "$obj" > "$TMP/$name.json"
        echo "$TMP/$name.json"
      done
done > "$TMP/podlist" || true

while IFS= read -r pf; do
  [[ -n "$pf" && -r "$pf" ]] || continue
  NPODS=$((NPODS+1))
  submit "pod $(basename "$pf" .json)" "$pf" || true
done < "$TMP/podlist"

if [[ "$NPODS" -eq 0 ]]; then
  # Not a pass. If the manifests contained no workload, this script proved
  # nothing about Pod Security and must not imply otherwise.
  bad "no pod templates were found in the supplied manifests — Pod Security was NOT exercised"
  note "Render the besu-node chart (which carries the validator pod template) and pass it with -f."
fi

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo "The namespace will NOT accept these workloads as rendered. Each failure above names a requirement number." >&2
  exit 1
fi
echo "Admission accepts every object and every pod template. (Quota ARITHMETIC is verify-cluster.sh — see the header.)"

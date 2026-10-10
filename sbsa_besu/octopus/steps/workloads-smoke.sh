#!/usr/bin/env bash
# =============================================================================
# octopus/steps/workloads-smoke.sh   — besu-workloads, until the CT-5 rewrite
# -----------------------------------------------------------------------------
# Runs ON THE IN-VPC EC2 RUNNER, as an Octopus polling-Tentacle worker (CD-57),
# with the runner's instance role — the only host that can reach the private
# EKS endpoint. It proves the in-cluster path end to end WITHOUT the workload
# Helm releases, which cannot deploy air-gapped yet (CD-67):
#   1. the cluster is reachable and every node Ready;
#   2. a namespace with a ResourceQuota exists (created if absent — the shape #27
#      asks the cloud team for), so the next two run under admission like ours;
#   3. #38 — verify-pull-canary.sh pulls the mirrored tools image BY DIGEST as the
#      node role;
#   4. C-2 — DNS from a pod, UDP and TCP, through the cluster's CoreDNS.
# The Helm workload steps replace this script's role after the CT-5 rewrite;
# the step, its worker pool and its package plumbing stay.
#
# Environment:  BESU_CLUSTER  AWS_REGION  BESU_SMOKE_NAMESPACE (default besu-smoke)
#               BESU_TOOLS_IMAGE  the mirrored tools image, registry/path@sha256:…
# =============================================================================
set -euo pipefail

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${BESU_CLUSTER:?}" "${AWS_REGION:?}" "${BESU_TOOLS_IMAGE:?}"
NS="${BESU_SMOKE_NAMESPACE:-besu-smoke}"
export KUBECONFIG="${KUBECONFIG:-$(mktemp)}"

# The runner's toolchain is on PATH via /etc/profile.d in a login shell; a
# Tentacle step is not one.
[[ -d /usr/local/besu-tools/bin ]] && export PATH="/usr/local/besu-tools/bin:$PATH"

echo "== 1. cluster"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$BESU_CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null
kubectl get nodes -o wide
notready="$(kubectl get nodes --no-headers | awk '$2 != "Ready"' | wc -l)"
[[ "$notready" -eq 0 ]] || { echo "FAIL: $notready node(s) not Ready" >&2; exit 1; }

echo "== 2. namespace $NS with a quota"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    pod-security.kubernetes.io/enforce: baseline
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: smoke-quota
  namespace: $NS
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.memory: 2Gi
    pods: "10"
EOF

echo "== 3. #38 pull canary"
bash "$PKG/scripts/preflight/verify-pull-canary.sh" -n "$NS" -i "$BESU_TOOLS_IMAGE" -t 300

echo "== 4. C-2 DNS through CoreDNS (UDP and TCP)"
POD="dns-smoke-$$"
trap 'kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
kubectl -n "$NS" run "$POD" --image="$BESU_TOOLS_IMAGE" --restart=Never --overrides='{"apiVersion":"v1","spec":{"containers":[{"name":"'"$POD"'","image":"'"$BESU_TOOLS_IMAGE"'","command":["/bin/sh","-c","sleep 600"],"resources":{"requests":{"cpu":"10m","memory":"32Mi"},"limits":{"cpu":"200m","memory":"128Mi"}}}]}}' >/dev/null
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=180s >/dev/null
kubectl -n "$NS" exec "$POD" -- python3 - <<'PY'
import socket, struct, random, sys
ns = open("/etc/resolv.conf").read().split("nameserver")[1].split()[0]
name = b"".join(bytes([len(p)]) + p.encode() for p in "kubernetes.default.svc.cluster.local".split(".")) + b"\0"
bad = 0
for proto in ("udp", "tcp"):
    ok = 0
    for _ in range(10):
        tid = random.randint(0, 65535)
        m = struct.pack(">HHHHHH", tid, 0x0100, 1, 0, 0, 0) + name + struct.pack(">HH", 1, 1)
        try:
            if proto == "udp":
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2); s.sendto(m, (ns, 53)); r, _ = s.recvfrom(512)
            else:
                s = socket.create_connection((ns, 53), timeout=2); s.sendall(struct.pack(">H", len(m)) + m)
                r = s.recv(struct.unpack(">H", s.recv(2))[0])
            ok += struct.unpack(">H", r[:2])[0] == tid
        except Exception:
            pass
    print(f"{proto}: {ok}/10 answered via {ns}")
    bad += ok != 10
sys.exit(1 if bad else 0)
PY
echo "PASS: cluster reachable, quota'd namespace admitted the canary, #38 pull and C-2 DNS proven from the Octopus worker"

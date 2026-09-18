# The 15 images carried by upstream Helm charts

**— in addition to the 8 in `var.container_images`.** 23 images total. The two lists
behave completely differently, and conflating them is how a deploy-test dies.

Enumerated 2026-08-30 by `helm template` at the pinned versions, **not from memory**.
Helm v3.21.3. Reproduce with the commands in the appendix.

> **Registry-independent.** These 15 are a property of the pinned charts, not of the
> registry: whichever mirror they are pulled from, the same 15 must be present and the
> same per-chart value overrides are required. The registry is Amazon ECR (CT-3a,
> `sbsa_besu/docs/CLOUD_TEAM_REDESIGN_NOTES.md` §11).

## The two lists

| | Count | What | Declared in |
|---|---|---|---|
| **Platform images** | 8 | What this repository runs directly | `var.container_images`, `terraform/chain/variables.tf` |
| **Chart-carried images** | 15 | What the five upstream charts pull on their own | **nowhere** — that is the point |

The 8 platform images, for reference:

| Key | Upstream | Repository | Tag |
|---|---|---|---|
| `besu` | docker.io | `hyperledger/besu` | `26.6.1` |
| `tools` | docker.io | `alpine/k8s` | `1.30.13` |
| `blockscout` | ghcr.io | `blockscout/blockscout` | `9.0.2` |
| `frontend` | ghcr.io | `blockscout/frontend` | `v2.3.5` |
| `stats` | ghcr.io | `blockscout/stats` | `v2.16.0` |
| `visualizer` | ghcr.io | `blockscout/visualizer` | `v0.2.1` |
| `proxy` | docker.io | `nginx` | `1.27-alpine` |
| `postgres` | docker.io | `postgres` | `16-alpine` |

**Why the split matters.** The 8 flow through `local.image_ref`: set `registry_host` and
they are all rewritten to ECR automatically, they are validated at plan time, and
`verify-images.sh` checks them. The 15 do not — each chart hardcodes its own images under
its own values key — so **`verify-images.sh` can exit 0 while all 15 are missing**, and
Besu and Blockscout pull fine from ECR while Prometheus, Grafana and the CSI sidecars
hang on `ImagePullBackOff`. That gap is PORTING item 4.

## The 15 images

| # | Image | Registry | From chart |
|---|---|---|---|
| 1 | `csi-secrets-store/driver:v1.6.0` | registry.k8s.io | secrets-store-csi-driver 1.6.0 |
| 2 | `csi-secrets-store/driver-crds:v1.6.0` | registry.k8s.io | secrets-store-csi-driver 1.6.0 |
| 3 | `sig-storage/csi-node-driver-registrar:v2.16.0` | registry.k8s.io | secrets-store-csi-driver 1.6.0 |
| 4 | `sig-storage/livenessprobe:v2.18.0` | registry.k8s.io | secrets-store-csi-driver 1.6.0 |
| 5 | `aws-secrets-manager/secrets-store-csi-driver-provider-aws:3.1.1` | public.ecr.aws | ascp 3.1.1 |
| 6 | `aws-observability/aws-for-fluent-bit:3.2.1` | public.ecr.aws | aws-for-fluent-bit 0.2.0 |
| 7 | `eks/aws-load-balancer-controller:v3.4.0` | public.ecr.aws | aws-load-balancer-controller 3.4.0 |
| 8 | `prometheus/prometheus:v3.12.0-distroless` | quay.io | kube-prometheus-stack 86.2.3 |
| 9 | `prometheus/alertmanager:v0.33.0` | quay.io | kube-prometheus-stack 86.2.3 |
| 10 | `prometheus/node-exporter:v1.11.1-distroless` | quay.io | kube-prometheus-stack 86.2.3 |
| 11 | `prometheus-operator/prometheus-operator:v0.91.0` | quay.io | kube-prometheus-stack 86.2.3 |
| 12 | `kiwigrid/k8s-sidecar:2.7.3` | quay.io | kube-prometheus-stack 86.2.3 |
| 13 | `kube-state-metrics/kube-state-metrics:v2.19.1` | registry.k8s.io | kube-prometheus-stack 86.2.3 |
| 14 | `grafana/grafana:13.0.2` | docker.io | kube-prometheus-stack 86.2.3 |
| 15 | `jkroepke/kube-webhook-certgen:1.8.3` | ghcr.io | kube-prometheus-stack 86.2.3 |

## Upstreams the mirror pipeline must copy from

**Five**, not the four originally anticipated:

| Registry | Needed by |
|---|---|
| `docker.io` | 5 platform images + grafana |
| `ghcr.io` | 4 Blockscout images + kube-webhook-certgen |
| `quay.io` | 5 kube-prometheus-stack images |
| `registry.k8s.io` | 5 CSI + kube-state-metrics |
| `public.ecr.aws` | 3 AWS controller images |

`ghcr.io` was already required for Blockscout, so the charts add three new upstreams:
`quay.io`, `registry.k8s.io`, `public.ecr.aws`. All five are copied into private ECR
repositories by `scripts/supply-chain/` — digest-preserving (`crane copy`), never
`docker pull`/`tag`/`push`, which re-manifests and changes the digest.

## Three things the enumeration turned up

### 1. `public.ecr.aws` is a different service from the EKS addons' registry

The EKS addons (vpc-cni / coredns / kube-proxy) come from an AWS-managed **private**
ECR reached through the `ecr.api` + `ecr.dkr` endpoints. `public.ecr.aws` is a
different service on a different hostname, and it is **not** reachable that way.

Observed via `describe-vpc-endpoint-services`:

- `us-east-1` offers `com.amazonaws.us-east-1.ecr-public.api` — **and no
  `ecr-public.dkr`**. The API endpoint covers auth/describe; image *layers* are
  served from a CloudFront distribution over the internet. An endpoint alone does
  not make the pull work.
- `af-south-1` — the go-live region — offers **no `ecr-public` endpoint at all**.

So images 5, 6 and 7 must be mirrored like any other public image. Assuming "it's AWS,
it will work like the addons" is a hang in af-south-1.

**Under ECR this stops being a problem entirely** — they become ordinary private ECR
repositories reached over the endpoints we already own.

### 2. The obvious enumeration command silently fails on one chart

`aws-load-balancer-controller` will not template with default values:

```
Error: Chart cannot be installed without a valid clusterName!
```

Running the enumeration verbatim yields an error and no image list — easy to skim past
and conclude the chart carries nothing. It needs `--set clusterName=x`.

### 3. `ghcr.io/jkroepke/kube-webhook-certgen` is a personal namespace

Not an org — a single maintainer's GitHub account, pulled by the
prometheus-operator admission-webhook patch job. Mirrorable like anything else,
but a bank supply-chain review will ask about it. It can be removed entirely by
disabling the admission webhook patch job, or replaced by cert-manager. That is a
platform-side decision, independent of the registry.

## Values-dependence (why the list is what it is)

The image set depends on the values the platform passes, not chart defaults:

- `secrets-store-csi-driver-provider-aws` is installed with
  `secrets-store-csi-driver.install=false` (`modules/secrets/main.tf:337`), so it
  contributes only image 5. Its default rendering also emits images 1–4; they are
  on the list anyway because the standalone driver chart is installed separately
  (`modules/storage-csi/main.tf:170`).
- `kube-prometheus-stack` values (`modules/observability/main.tf:274`) disable
  only the EKS-hidden control-plane *monitors* (kubeEtcd, kubeControllerManager,
  kubeScheduler, kubeProxy) — no images. Grafana, node-exporter,
  kube-state-metrics and the operator all stay enabled. All 8 are live.

## Appendix — reproduce

```bash
helm template x secrets-store-csi-driver              --version 1.6.0  --repo https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm template x secrets-store-csi-driver-provider-aws --version 3.1.1  --repo https://aws.github.io/secrets-store-csi-driver-provider-aws
helm template x aws-for-fluent-bit                    --version 0.2.0  --repo https://aws.github.io/eks-charts
helm template x aws-load-balancer-controller          --version 3.4.0  --repo https://aws.github.io/eks-charts --set clusterName=x
helm template x kube-prometheus-stack                 --version 86.2.3 --repo https://prometheus-community.github.io/helm-charts
# ... | grep -oE 'image: *"?[^"]+' | sort -u
```

All five chart versions resolved and templated successfully, which confirms each
pinned version exists in its repository.

# Build findings — the SBSA port (B-series)

Defects found while porting `besu-aws` onto the cloud team's VPC. Numbered `B1..`
to avoid colliding with the inherited series: **F1–F33** (deploy-test findings),
**H1–H39** (production hardening), **C1–C12** (app backlog).

Every entry records **how it was found**, because the pattern matters more than
the individual bugs: *four of these passed silently and were only caught by
deliberately testing the failure path, not the success path.*

**Provenance** distinguishes three kinds:

- **inherited** — pre-existing in `besu-aws`, surfaced here
- **port-induced** — created by, or invalidated by, moving to the new design
- **tooling** — bugs in the verification scripts written for this project

The last category is the worrying one. A broken check does not fail loudly; it
reports success.

---

## Open

> **2026-10-11 — B13 and B44–B50 are fixed in code and not yet proven live.** The first
> `besu-workloads` in-cluster run proves them; they move to Closed with that run's evidence.

### B50 — the runner's plan refreshed AWS APIs that have no endpoint in the VPC, and hung
**Provenance:** port-induced (one root and one state hold both layers; CD-53 split who applies them, not what a plan touches) · **Found:** 2026-10-11, `ServerTasks-1537` · **Fixed:** same day

With B49 fixed, `besu-workloads`' in-cluster plan got past `init`, issued the F19 cert, and then
printed nothing for 17 minutes. On the runner, `ss` showed the AWS provider in `SYN-SENT` to a
public IP that the runner's own DNS resolves for `resource-groups.af-south-1.amazonaws.com`. A
plan **refreshes every managed resource in state**, and the chain root's state holds the resource
group, the CloudTrail trail and a dozen IAM roles and policies. From the air-gapped VPC:
`resource-groups`, `cloudtrail` and `iam` (global) resolve to public addresses — no endpoint, so
a hang (prime directive 2); everything else the root uses (sts, ec2, eks, kms, logs, monitoring,
sns, sqs, secretsmanager, elasticloadbalancing, ecr) resolves to 10.60.11.x. One **data source**
had the same problem and would hang even without a refresh: `modules/eks`
`data "tls_certificate" "oidc"` fetched the OIDC issuer over public HTTPS on every plan.

**Fixed — the runner touches only the in-cluster layer, and that is enforced:**
1. `workloads-incluster.sh` plans with **`-refresh=false`**. `besu-infra` refreshes and applies
   the AWS layer immediately before `besu-workloads` runs, from a host that can reach it.
2. A **CD-53 plan gate**: any managed change other than `helm_release` / `kubernetes_*` refuses
   the step. Tested both ways on synthetic plans (and the CD-5 gate three ways: create passes,
   update and replace refuse).
3. `modules/eks` drops the `tls_certificate` data source and the thumbprint. Provider 5.100.0
   has `thumbprint_list` optional + computed; IAM does not use it for EKS issuers. **Proven no-op**
   before release: a laptop plan of the live SIT chain (af-south-1 state, Octopus's vars) →
   `No changes`.

**Residual, accepted for now:** with `-refresh=false` the runner cannot see AWS-layer drift
between the two projects; the gate catches only drift Terraform's config would correct. The
proper end state is a separate in-cluster root with its own state reading the chain's outputs —
which is also the CT-5 shape (one namespace, no AWS layer of ours in that cluster).

### B49 — the Terraform state bucket was in us-east-1; the runner, air-gapped in af-south-1, cannot reach it
**Provenance:** port-induced (the 2026-09-04 move of every environment to af-south-1 left the state bucket behind) · **Found:** 2026-10-11, `ServerTasks-1535` · **Fixed:** same day

The first Terraform run ever made **inside the VPC** — `besu-workloads`' in-cluster step on the
runner — died at `terraform init` after three minutes:
`retrieving caller identity from STS … Post "https://sts.us-east-1.amazonaws.com/": i/o timeout`.
`besu-tfstate-867728055761` is a us-east-1 bucket. From the air-gapped VPC the S3 gateway endpoint
serves **same-region buckets only** and STS is reachable only through the region's own interface
endpoint, so a bucket in any other region is unreachable — and, per prime directive 2, a hang
rather than an error. Every earlier run used a hosted worker or the laptop, both with internet, so
nothing exposed it. **It is also a residency defect:** the chain state carries the CA private key
and node-key material of an af-south-1 ledger.

**Fixed:** SIT's platform state (`besu/sit/{shared,chain,runner}.tfstate`) moved to
`besu-tfstate-867728055761-afs1` in af-south-1 (versioning, AES256, SSE-C blocked, public access
blocked — as the old bucket); the originals parked under `MOVED-2026-10-11/`. Two guards so it
cannot recur silently: the Octopus root's `state_region` must equal `aws_region` (validation,
negative-tested: the old SIT values are refused at plan), and `lib.sh init_root` — every Octopus
step — dies in a second on a mismatch (tested both ways). The mimic, registry and Octopus states
stay in us-east-1: only the laptop and hosted workers use them. **For the bank:** the state bucket
is an af-south-1 bucket; add it to the R-10 asks if it is theirs to create.

### B44 — `CHART_IMAGES.md` missed `prometheus-config-reloader`, so the mirror never copied it
**Provenance:** tooling · **Found:** 2026-10-11, rendering the ECR-mirrored charts before the first in-cluster apply · **Fixed in code:** same day

The 08-30 enumeration grepped `helm template` output for `image:` lines. The Prometheus
operator receives the config-reloader image as a **command-line flag**
(`--prometheus-config-reloader=quay.io/…:v0.91.0`) and injects it into the Prometheus and
Alertmanager pods at runtime, so it never appears as an `image:` line, and so it was never
mirrored. Both pods would have sat in `ImagePullBackOff` on a registry that "had everything".

**Found by** grepping the rendered charts for *any* upstream registry reference
(`quay.io/…`, `registry.k8s.io/…`, …) rather than `image:` lines, then checking every
resulting reference against ECR with `describe-images`. `thanos/thanos` turns up the same
way but is only an operator default for Thanos Ruler, which is not deployed; nothing pulls it.

**Fixed:** a `config-reloader` row in `mirror.manifest` (digest resolved from quay.io with the
full Accept header — the same request reproduces the operator's recorded `9e53e131…`), a
`config-reloader` key in `var.chart_images`, and the override in `modules/observability`.
`CHART_IMAGES.md` now lists 16 and says how to enumerate.

### B45 — node-exporter would have pulled `v1.11.1-distroless-distroless`
**Provenance:** port-induced · **Found:** 2026-10-11, same render · **Fixed in code:** same day

kube-prometheus-stack sets `prometheus-node-exporter.image.distroless=true`, and the subchart
**appends** `-distroless` to whatever tag it is given. The mirror holds `v1.11.1-distroless`,
so overriding the tag with the mirror's tag doubles the suffix. Fixed by setting
`distroless=false` whenever node-exporter is overridden — the tag in `chart_images` is then
exactly the tag pulled. A real boolean, so it goes in a `values` entry: the image `set`s are
`type = "string"`, and the chart's `ternary` would read the string `"false"` as true.

### B46 — D-20 (Terraform providers from a filesystem mirror) was decided and never built
**Provenance:** port-induced · **Found:** 2026-10-11, planning the first in-cluster apply from the runner · **Fixed in code:** same day

The runner bundle shipped `terraform` but no providers, and nothing configured a mirror. Every
runner-side `terraform init` so far was never run (the AWS layer is applied by hosted workers),
so nothing exposed it. The first in-cluster apply would have reached for `registry.terraform.io`
and **hung** (prime directive 2).

**Fixed:** `push-runner-bundle.sh` runs `terraform providers mirror -platform=linux_amd64` for the
chain root (against the committed lock file, in a scratch copy so no `.terraform/` reaches the
source bundle) into `tools/providers`, and writes `tools/terraformrc` with **only** a
`filesystem_mirror` — no `direct` fallback, so a missing provider fails init instead of hanging.
The runner's profile exports `TF_CLI_CONFIG_FILE`; `workloads-incluster.sh` sets it and refuses
to run without it. Tested on the laptop: 5 providers, 194 MB, offline init from the mirror alone.

### B47 — Octopus looked for the validators in `besu-ledger`; the chain deploys them to `besu`
**Provenance:** port-induced · **Found:** 2026-10-11, wiring the in-cluster step · **Fixed in code:** same day

`Besu.LedgerNamespace` defaulted to `besu-ledger`; the chain root's `besu_namespace` defaults to
`besu`, and the scripts all assume it. Once validators existed, `besu-validators` would have
found none in `besu-ledger`, printed "nothing to roll" and **gone green** with the change
unapplied. The 10-10 run's "nothing to roll" was true only because no chain existed. Fixed: the
Octopus default is `besu`; the in-cluster step reads the namespace and cluster from the chain
root's outputs (new `besu_namespace` output), not from Octopus variables.

### B48 — the node-secrets IRSA trust named the literal namespace `"besu"`
**Provenance:** inherited · **Found:** 2026-10-11, the B47 search · **Fixed in code:** same day

`module "iam"` got `namespace = "besu"` while every release used `var.besu_namespace`. Set the
variable to anything else and the pods could not assume the role that reads their own node keys.
Now `var.besu_namespace` — a no-op at the default.

### B13 — the five upstream Helm charts carry their own images
**Provenance:** port-induced · **Status:** FIXED IN CODE 2026-10-11 (`PORTING.md` item 4), live proof pending

**The fix:** the charts come from the mirror as OCI (`oci://<registry_host>/<registry_chart_path>`,
helm provider `registry` block fed by `aws_ecr_authorization_token`), and every chart-carried
image is declared once in `var.chart_images` and rewritten exactly like `container_images`.
Each module maps Helm value paths to those keys and emits only the keys present, so an absent
key keeps the chart default. Verified before any deploy: each mirrored chart rendered with the
exact `set` entries Terraform produces (evaluated in a scratch root, not hand-copied) has **no**
upstream reference left except the unused `thanos` default, and every image it names exists in
ECR — which is how B44 and B45 were found. `mirror.sh --check-drift` now compares the chart
images too (tag-pinned: host/repository/tag), negative-tested.

*The original finding:*

`var.container_images` covers the eight images this repository names directly. It
does **not** cover the images the five pinned upstream charts pull themselves:
Prometheus, Grafana, Alertmanager, kube-state-metrics, node-exporter and the
operator (`kube-prometheus-stack`), the CSI node-driver-registrar and
livenessprobe, and each AWS controller's own image — from `quay.io`,
`registry.k8s.io`, `public.ecr.aws` and `docker.io`.

In a VPC with no egress every one of them hangs. Each chart needs its image
values overridden, and the key differs per chart (`image.repository`,
`global.imageRegistry`, `prometheus.image`, …).

**Found by:** enumerating the chart list for the air-gapped supply chain
— not by any test. Nothing in the build would have caught it before a deploy-test.

**Not in scope:** the EKS addons (VPC CNI, kube-proxy, CoreDNS, EBS CSI) reach an
AWS-managed ECR in-region through the cluster's `ecr.api`/`ecr.dkr` endpoints.

---


### B34 — `mimic_eks` teardown leaks a VPC CNI ENI, which pins the EKS cluster SG and blocks the VPC delete
**Provenance:** tooling (fixture teardown) · **Found:** 2026-10-10, B27 live run · **Status:** OPEN

After the `mimic_eks` destroy (20 destroyed, state empty), one VPC CNI secondary ENI from a
terminated node stayed `available` in its subnet (`eks:eni:owner=amazon-vpc-cni`,
`cluster.k8s.amazonaws.com/name=<cluster>`), and the EKS-managed cluster security group
(`eks-cluster-sg-<cluster>-*`, tag `aws:eks:cluster-name`) was never deleted — most likely
because that ENI still referenced it when EKS deleted the cluster, and EKS does not retry.
Neither is in Terraform state, so `terraform destroy` reports success. The `mimic_vpc`
destroy then deleted every subnet and **retried `DeleteVpc` for 10 minutes** against the
orphaned group (≈ 1 min on 10-09, which did not leak — the leak is intermittent).

Both were deleted by hand after confirming ownership (tags, creation time, instance
terminated, no remaining references). **Open work:** a read-only-then-delete sweep by the
cluster tag between the `mimic_eks` destroy and the `mimic_vpc` destroy — RUNBOOK §E.2
step 8 now carries the commands; it belongs in a `mimic_eks` teardown script. It is the
same class as CLAUDE.md §9's leaked-ENI sweep, which the platform's own teardown already
requires: the platform will hit it on the shared cluster's subnets too, where a leaked ENI
is the cloud team's scarce address space.

**Found by:** the destroy taking ten times as long as the last one, and asking why.

---

### B32 — F-7 (runner → cluster API) was blocked by the mimic and never checked
**Provenance:** tooling (fixture + checker) · **Found:** 2026-10-10, while fixing B27 · **Status:** FIXED IN CODE · NACL half **proven live** 2026-10-10 (the az3 node used the C-1 ingress 443 rule F-7 shares) · **runner half open** — no runner has exercised F-7 yet

Two halves of one omission. `nacl.tf` gave the runner's subnet an **egress** 443 rule for
F-7, but no node subnet had an **ingress** 443 rule, so the control-plane ENIs could never
answer it. And `verify-subnet-rules.sh` had **no F-7 section** — it took `--runner` and used
it only for F-5 and F-8. Every run with a runner used `permissive` NACLs, so it never
showed; under `flows` the runner could not have reached a private API endpoint at all,
and nothing would have named a rule.

Fix: the C-1 ingress rule's sources include the runner's (ledger) subnets, and the F-7
egress rule targets every cluster subnet, the ledger ones too when #28 is granted. The
checker has an F-7 section driven by `--runner` + `--control-plane`; against the 10-09
rules it reports all three runner → control-plane pairs BLOCKED.

**Found by:** reading the checker for a B27 test and noticing `--runner` drove no F-7 check
— the B27 shape again: a check built from a list cannot see what the list leaves out.

---

### B30 — `mimic_eks` strict claims add-ons it never installs, and `verify-contract.sh` misjudges access entries
**Provenance:** tooling (fixture) · **Found:** 2026-10-09 · **Status:** OPEN

1. The strict hand-over says `cluster_provides_lbc = true` (and the other add-ons), but the
   mimic installs no add-on and no CRD. `verify-cluster.sh` and `verify-admission.sh`
   correctly reported the hand-over disagreeing with the live cluster — the gap is in the
   fixture. Strict should install at least the four CRDs (#30).
2. `verify-contract.sh` judges **every** cluster-scoped access entry, so strict FAILs on the
   creator (`tfuser`) and the AWS service-linked role. It should judge only
   `runner_role_arn`'s entry.
3. It reports `nodes=` from the node group's **desired** size, so a `CREATE_FAILED` group
   with two of three nodes joined (B27) still read as three.

**Found by:** the first strict run. Detail: `docs/deploy-run-2026-10-09-ct5-gates-and-regression.md` §A4, §A8.

---

## Closed

### B43 — the EKS nodes' CNI warm pool took the runner's pinned IP
**Provenance:** port-induced (CD-60 pin + CT-5 shared subnets) · **Found:** 2026-10-10, `ServerTasks-1517` · **Fixed:** same day; the bank-side half is an R-10 ask

`terraform: runner` failed at apply with `InvalidIPAddress.InUse` for `10.60.0.250`. The chain,
the shared root and the runner bundle had all succeeded. The address is the one /32 the
egress proxy allowlists (CD-60), so the runner is pinned to it. It sits in a **ledger subnet the
EKS nodes share**, and the VPC CNI keeps a warm pool of secondary IPs on every node ENI, drawn
from the subnet at random. `eni-0f3a9de898fbcc343` (an `aws-K8S-i-…` node ENI) was holding it.
On 09-17 the node group happened not to pick it, so the race was there all along. **It can
happen in the bank** whenever the runner is (re)created after nodes have scaled.

Unblocked live: `create-subnet-cidr-reservation --reservation-type explicit` on the /32
(`scr-00405fb7285c2d5bf`), `unassign-private-ip-addresses` from the node ENI, and re-deploy
the same release: `ServerTasks-1518` Success.

Fixed in two layers:
1. **The cause: an explicit reservation, owned by the subnet owner.** AWS then assigns the
   address only on explicit request, which is how the runner asks for it. In production this
   is the cloud team's: added to the R-10 asks (`CICD_DESIGN_NOTES.md`). In the mimic:
   `mimic_vpc` `pinned_ip_reservations` (`reservations.tf`), with gates that the AZ is a
   ledger AZ and the address sits in its subnet.
2. **The symptom, at plan: `terraform/runner/ip-guard.tf`.** A precondition fails the plan
   when any interface other than the runner holds the pinned IP. It names the ENI and prints the two
   commands that free it. It can't see the reservation (the provider has no data source for one),
   so it catches what actually breaks the apply. Proven both ways against the live VPC,
   read-only: with the runner holding its IP, the plan passes (+1 `terraform_data`); with
   `runner_private_ip` set to a CNI-held address (`10.60.0.120`) it fails, naming the node ENI.

A third layer, a persistent ENI that owns the address independently of the instance, would
also keep the Tentacle's identity across a re-create. Not done: it changes the runner module,
and the reservation already removes the race.

**Found by:** the first Octopus deployment of `besu-infra`.

---

### B42 — `release.yml` could not find the deployment it had just started
**Provenance:** tooling (CD-68) · **Found:** 2026-10-10, run `38059442057` · **Fixed:** same day

"Find the SIT deployment" asked for `projects/<slug>/releases/<version>`. That route answers
**404 "not found in the current space context" when given a slug**, even though the project
route itself accepts one. The release existed (`Releases-61`), and the step died with a
bare `curl -f` exit 22 that the run page could not explain. Fixed: the step now resolves
the slug to a project ID first, and every API call reports its HTTP status and Octopus's
message when it fails. That reporting is how the 404 was found. Re-run against the real
release: it finds `ServerTasks-1516`.

**Found by:** the first real release. My earlier route check had used the project ID.

---

### B41 — `terraform version | head -1` killed the first `besu-infra` step (exit 141)
**Provenance:** port-induced (B38's `lib.sh`) · **Found:** 2026-10-10, `ServerTasks-1516` · **Fixed:** same day

`head` exits after one line. Terraform, still writing its five-line version banner, takes
SIGPIPE, and under `set -o pipefail` the step fails with **141** right after printing
`Terraform v1.16.1`. It failed before any AWS call, so nothing was created and nothing
billed. Intermittent by nature: in the worker-tools image, `head` failed 1 time in 30 and
`sed -n 1p` 0 times. The local container test had passed by luck. Now `sed -n 1p`, which
reads all its input.

**Found by:** the first real deployment, at zero cost.

---

### B40 — the F-8 proxy reply had no NACL rule of its own; `egress_proxy_cidr` was unset in SIT
**Provenance:** tooling + mimic · **Found:** 2026-10-10, preparing the first Octopus run · **Fixed:** same day, offline-proven

Three faults, all on the In-VPC EC2 Runner → egress proxy path (F-8) the Octopus Tentacle
depends on. None of them could show on 09-17, which ran before the `flows` NACLs existed:
1. **SIT's `mimic_vpc` tfvars left `egress_proxy_cidr` empty**, which *omits* the outbound
   F-8 rule. Under `flows` the Tentacle could not have polled. Now `10.61.0.0/24`.
2. **There was no inbound rule for the proxy's reply.** NACLs are stateless, and the reply
   comes from outside the VPC, so none of the VPC-CIDR return rules cover it. It got
   through only because empty `s3_cidrs` falls back to an any-source S3 return rule (150).
   Enumerate S3's prefixes, as a real cloud team will, and the handshake dies. There is now
   a dedicated inbound rule (band 190). Budget: 17/19, or 18/20 with two S3 ranges.
3. **`verify-subnet-rules.sh` checked only the outbound half of F-8**, so it would have
   passed fault 2. It now checks the return too, and warns when that return only passes
   through a `0.0.0.0/0` rule.

Fixture matrix from real plans (`b40/`): SIT settings PASS with the new warning;
enumerated S3 PASS through rule 190; `nacl_break_flow = "F-8"` FAILs both halves.

**Found by:** reading the NACL flow table against the one path the Octopus run needs. The
B12/B27 lesson again: a check that only looks at the forward half passes a dead flow.

---

### B39 — `besu-infra` created the runner before its S3 bundle existed
**Provenance:** port-induced (CD-67) · **Found:** 2026-10-10, preparing the first Octopus run · **Fixed:** same day, not yet run

The runner's bootstrap is FATAL without `tools/` and `source/` in the artefacts bucket,
and the only fix it offers is recreating the instance. The bucket is created by `chain`.
By hand, the bundle went up between the two applies (RUNBOOK E.1 step 4); `besu-infra`
ran `shared → chain → runner` back to back, so its first deployment would have built a
dead runner. Fixed with a new step between `chain` and `runner`,
`octopus/steps/runner-bundle.sh`. It pushes the pinned toolchain and *this release
package* as the source (`push-runner-bundle.sh --source-dir`, no git needed), and fills
the runner's own deploy-config secret. Exercised in the worker-tools image with a stub
`aws`: all five digests verified, 294 MB tools and 320 KB source staged.

**Found by:** reading the runner's bootstrap against the step order, before a billable run.

---

### B38 — every `besu-infra` step needed an AWS CLI that Octopus's hosted worker does not have
**Provenance:** port-induced (CD-67) · **Found:** 2026-10-10 · **Fixed:** same day, not yet run

All three steps are `Octopus.AwsRunScript` on the Hosted Ubuntu pool. A Script Console
probe (`ServerTasks-1515`) found Ubuntu 24.04 with curl, python3, unzip, git, jq, kubectl,
helm and Docker, but **no `aws` and no `terraform`**. The steps now run in an execution
container, `octopusdeploy/worker-tools:6.6.5-ubuntu.24.04` (pinned tag, digest recorded),
from Besu's own Docker feed. Running the image locally confirmed aws-cli 2.34 and the
other tools. Its own Terraform 1.15.8 is replaced by the manifest's pinned 1.16.1
(`octopus/steps/lib.sh`).

**Found by:** asking the worker what it has before any deployment depended on it. This
cost nothing, against a failed billable run.

---

### B37 — `hardening-validation.sh --dry-run` mis-reported four planned tests
**Provenance:** inherited (`besu-aws`) · **Found:** 2026-10-10, writing `release.yml` · **Fixed:** same day

The dry-run plan printed `$( is_true \"$NODE_CMK\" … )` and `$( [ -n \"$DATA_CMK\" ] … )`.
Inside `$( … )` the escaped quotes reach the test as literal `"` characters, so
`[ -n '""' ]` is always true and `is_true '"true"'` is always false. As a result:
**H20 was always listed**, even with no `data_cmk_arn`; **mTLS always read "off"**; and
**H7-cmk and H16 never appeared**. The tests themselves were unaffected; only the plan
was wrong. The backslashes are gone, and all four branches were exercised.

**Found by:** `shellcheck -S error` (SC2070/SC2157), its only error-level finding in the
36 scripts, while choosing what `release.yml` could gate on from day one.

---

### B36 — `verify-pull-canary.sh --check-policy` failed a same-account registry the canary proved pullable
**Provenance:** tooling · **Found:** 2026-10-10, pull-canary run · **Fixed:** same day

"`mirror/alpine/k8s` has NO repository policy — their node role cannot pull", printed seconds
after the canary pulled that image as that role. A same-account pull needs no repository
policy; the node role's identity policy alone decides. The check now compares the
repository's `registryId` with the node role's account and passes same-account with that
explanation; cross-account — the bank's case (CD-27) — it still demands the policy. Both
branches exercised.

**Found by:** running the check beside the canary, so the verdicts could contradict.

---

### B35 — the pull canary could never reach the registry in a namespace with a quota
**Provenance:** tooling · **Found:** 2026-10-10, reading it before its first live run · **Fixed:** same day

`verify-pull-canary.sh` created its pod with a bare `kubectl run` — no resources, no
securityContext. Any `ResourceQuota` naming requests (exactly what #27 asks for) refuses
that pod at admission, and so does `restricted` Pod Security; the script then reports "the
API server refused … NOT a registry failure" and never tests a pull. P-1's lesson, in the
check itself. Shown live: the old shape → `failed quota: must specify limits.cpu …
requests.cpu …`. Fix: small explicit requests/limits and a restricted-compliant
securityContext (uid 65534, drop ALL, `RuntimeDefault`). The fixed canary then **passed**
for `alpine/k8s` and `hyperledger/besu` by digest — **#38 proven live** (same-account).

**Found by:** asking, before the first run, whether the pod could be admitted where it runs.

---


### B27 — the restrictive NACLs model only OUR flows, so a node in one AZ never joined
**Provenance:** tooling (fixture) · **Found:** 2026-10-09, first `mimic_eks` apply · **Fixed:** 2026-10-10 (`862f6c2`) · **Proven live:** 2026-10-10

`mimic_vpc`'s `nacl_mode = "flows"` (D-32) permits exactly #34's F-1..F-10 — the flows *we*
listed. It permits none of the **cluster's own**: nodes → API server (443) across node
subnets, pods → CoreDNS (53 tcp/udp) across AZs, control plane → kubelet/webhooks. EKS put
its control-plane ENIs in two of the three app subnets; the node in the third reached them
only across a NACL with no ingress 443, and `NodeCreationFailure` followed. The other two
nodes worked only because traffic inside one subnet is not NACL-evaluated.

`verify-subnet-rules.sh` passed 28/28 against those NACLs, because it checks the flows we
listed — the omission is in the flow table, so no checker built from it can see it.
Requirements #34 now has a table of the cluster's own flows (2026-10-09).

**Fix (2026-10-10):** `nacl.tf` carries the cluster's own flows, now numbered in #34's
second table — **C-1** nodes → API 443, **C-2** pods → CoreDNS 53 udp+tcp (and the UDP
reply, which needed the workload NACLs' first-ever egress rule for udp/1024-65535), **C-3**
control plane → kubelet/webhooks, **C-4** pod ↔ pod. In `summarised` mode C-1 and C-2 get
VPC-CIDR rules on their low ports, and C-3/C-4 ride the existing VPC-CIDR ephemeral rules,
whose labels now say so. It **fits the 20-rule default** — workload NACLs at 16 in / 19 out
with the F-8 proxy rule, 17 / 20 with two enumerated S3 ranges — only because B33 freed a
rule in each direction. `narrow` is 39 / 32 against a quota of 40. `verify-subnet-rules.sh`
gained `--control-plane` and C-1..C-3 sections, so the omission is now checkable.

**Proven offline**, by serving the real checker each plan's rules through a fake `aws`
(no apply): the 10-09 rules → **21 FAIL** (C-1 ×6, C-2 ×12, F-7 ×3); the fixed rules →
exit 0; `nacl_break_flow = "C-1"` → exactly C-1 ×6 + F-7 ×3; `"C-2 CoreDNS replies"` → the
six UDP pairs, each naming `RETURN DENIED … egress rule 32767`. **Proven live 2026-10-10** (`docs/deploy-run-2026-10-10-b27-live.md`), repeating the
10-09 failure exactly — hostile, nodes in the app subnets, `flows`: checker live =
the offline prediction (46/0/12/4; C-1 broken → C-1 ×6 + F-7 ×3); **3/3 nodes joined**,
with control-plane ENIs in az1 and az2 only, so the az3 node registered across a NACL;
logs fetched from pods on the az3 node (C-3); and with C-1 removed on the live cluster
**only the az3 node went NotReady** (~54 s), back to Ready ~10 s after the restore.
**C-2 proven live 2026-10-10 (2nd run)** with the mirrored `alpine/k8s`: 20/20 UDP + 20/20
TCP from a CoreDNS-less node across a NACL; C-2's UDP rule cut → UDP 0/20, TCP 20/20;
restored → 20/20 (`docs/deploy-run-2026-10-10-pull-canary-c2.md`).

**Found by:** the first apply of anything that needed nodes in all three AZs. Detail: `docs/deploy-run-2026-10-09-ct5-gates-and-regression.md` §A3.

---


### B33 — `summarised` NACLs carried duplicate rules, so `nacl_break_flow` could not break a flow
**Provenance:** tooling (fixture) · **Found:** 2026-10-10, offline B27 proof · **Fixed:** same day

In `summarised` mode several flows reduce to the same AWS rule — F-3's and F-4's replies
are both tcp/1024-65535 to the VPC CIDR, and so are the F-5 and F-9 returns inbound — and
each was authored separately. Two costs: a wasted rule per direction on NACLs that B27's
cluster flows filled to exactly 20 (with two enumerated S3 ranges, 21 — over); and a
fixture knob that lied: `nacl_break_flow = "C-3"` removed one twin, the other carried the
traffic, and the checker reported **0 FAIL** for a flow that was supposedly broken. A
break that breaks nothing would have "proven" any checker correct.

Fix: `nacl_flows_merged` collapses rules with identical (protocol, ports, CIDR) into one
whose label names every flow it carries; the first occurrence keeps its band and number.
Breaking any of those flows now removes the shared rule, as it would on a real subnet —
`"C-3"` now fails C-1, C-2, C-3, F-1, F-2, F-5, F-7 and F-9, because in `summarised` mode
they really do share one return rule. That is the header's point about stateless return
rules, now visible in the checker's output.

**Found by:** the B27 offline matrix — a deliberate break that produced a pass.

---

> **2026-10-09 run** (`docs/deploy-run-2026-10-09-ct5-gates-and-regression.md`): B25, B28, B29, B31 and P-1 fixed in `6d12b47`; B30 is
> under **Open**. **B27** was fixed 2026-10-10 and **proven live** the same day
> (`docs/deploy-run-2026-10-10-b27-live.md`), which also found **B34** (Open). **B26 was withdrawn** the same day — tracked `*.plan` files are the
> recorded `c0717ec` decision, and all nine pass its `PRIVATE KEY` check.

### P-1 — under the quota we ask for, every validator pod was refused at admission
**Provenance:** inherited · **Found:** 2026-10-09, first run against a namespace with a `ResourceQuota` · **Fixed:** same day

The `besu-node` init containers (`wait-peer-dns`, `build-config`) declared **no resources**.
A `ResourceQuota` that names a resource makes Kubernetes refuse any pod with a container —
init containers included — that does not declare it. Under the exact quota requirements #27
asks for, `verify-admission.sh` got `failed quota: must specify limits.memory for:
build-config,wait-peer-dns`. Our own clusters never had a quota, so it never showed.

Fix: an `initResources` value (requests 50m / 64Mi, memory limit 256Mi, no CPU limit)
on both init containers. The requirements now also ask for **no `limits.cpu`** in the
quota: our charts set none, so such a quota would refuse every pod regardless.

**Not done:** the same audit of the other charts' init containers (`besu-blockscout`
backend and stats have them).

**Found by:** a fixture namespace with a quota — `mimic_eks`'s, then one shaped exactly like
our own request, to separate the two causes.

---

### B31 — `verify-cluster.sh` failed a cluster that DOES enforce NetworkPolicy
**Provenance:** tooling · **Found:** 2026-10-09, first live run · **Fixed:** same day

#35 read only the `aws-node` container's env. On current VPC CNI add-ons (here
`v1.22.4-eksbuild.3`, `enableNetworkPolicy: "true"`) the switch is the
**`aws-eks-nodeagent`** container's argument `--enable-network-policy=true`; `aws-node`'s
env carries only `NETWORK_POLICY_ENFORCING_MODE`, present whether policy is on or off.
Fixed to accept either form; an explicit `=false` still fails. The same blind spot was in
the requirements' §4 command 2, which now prints the node agent's argument too.

**Found by:** the strict (compliant) profile — the positive control. Against hostile
(policy off) the FAIL was the right answer, so nothing there looked wrong.

---

### B29 — `verify-admission.sh` never reached Pod Security, and blamed RBAC for it
**Provenance:** tooling · **Found:** 2026-10-09, first live run · **Fixed:** same day

Three layers, each hiding the next:

1. `classify` was a `case`, so it named only the **first** matching cause. A manifest
   refused for Pod Security *and* a missing CRD was reported as Pod Security only, and the
   CRD pattern did not match `kubectl apply`'s wording (`resource mapping not found`).
2. The bare-Pod probe kept the chart's ServiceAccount, which does not exist before the
   first apply. The ServiceAccount admission plugin runs **before** Pod Security, so the
   probe never got a PSA verdict — and a catch-all `*[Ff]orbidden*` reported it as **#32
   RBAC**, a grant problem that did not exist.
3. A StatefulSet's `volumeClaimTemplates` only become volumes when the controller makes the
   pod, so the bare Pod was invalid before PSA ran.

Fixed: every matching cause is named; RBAC only on a real `forbidden: User … cannot`; a
missing SA is "not a cluster finding"; the probe runs as `default` with no token and an
`emptyDir` per claim template (allowed at every PSA level, so the verdict cannot change).
Now it reaches the hard `violates PodSecurity "restricted"` refusal D-40 asks for.

**Found by:** the hostile profile, then reading *why* each refusal happened, not just that it did.

---

### B28 — `cluster-contract` refused a correct OIDC issuer as "a DIFFERENT cluster"
**Provenance:** port-induced · **Found:** 2026-10-09, first run against a live cluster · **Fixed:** same day

CG-4 trimmed only a trailing `/`. EKS reports the issuer as `https://oidc.eks…`; IRSA trust
conditions, and so the hand-over, use the bare `oidc.eks…` form, and the cloud team may paste
either. Now compared without the scheme on both sides. Proven both ways: the correct issuer
passes, a `…/id/DEADBEEF…` issuer is refused with the same message.

**Found by:** the first plan of the gates against a live cluster, whose issuer came back in
the form EKS reports rather than the form the hand-over carried.

---

### B25 — `mimic_eks` built in us-east-1, and its region gate passed
**Provenance:** tooling (fixture) · **Found:** 2026-10-09, first `mimic_eks` apply · **Fixed:** same day

There was no `provider "aws"` block, so the provider used the laptop profile's default region.
IAM roles, the KMS key, the log group and the launch template were created in **us-east-1**,
then the first VPC-scoped resource failed with `InvalidVpcID.NotFound`. `region_agreement`
passed throughout: it compared `var.region` with `var.network_region`, two variables that were
both right, and never asked the provider. Fixed: a provider block like the sibling mimics',
and a precondition on `data.aws_region.current.name == var.region`. The 13 strays were
destroyed with the **unfixed** config first, so Terraform could still find them.

**Found by:** the apply failing. Same shape as B19–B24: a gate that checks what it was told
rather than what is real.

---

### B24 — Tentacle's instance index lives in `/etc/octopus`, which the service user could not create
**Provenance:** tooling · **Found:** 2026-09-17, first live `install-tentacle.sh` run · **Fixed:** same day

Step 2 (`create-instance` as the unprivileged `tentacle` user, CD-62) died with
`Access to the path '/etc/octopus' is denied`. The script's comment assumed the CLI records
the instance under `$HOME/.octopus`; on Linux Tentacle keeps a **machine-wide** index in
`/etc/octopus/Tentacle/instances/`, and an unprivileged user cannot create `/etc/octopus`.
Two fixes: step 1 now creates `/etc/octopus` owned by the service user (it holds only a
pointer file); and step 2 decides "instance exists" from **Tentacle's own index** (the
`/etc/octopus/Tentacle/instances/<name>.config` pointer, or `list-instances`), not from
the presence of `tentacle.config`. The first attempt at this fix treated only an *empty*
config as residue — but the failed `create-instance` had already written a full XML
skeleton, so the re-run still skipped step 2 and step 3 failed with "Instance besu-worker
has not been configured on this machine. Available instances: ." A leftover config whose
instance the index does not know is now removed before `create-instance`.

**Found by:** the first run. The step-0 probe, the user, and the directories all passed;
the failure was in the first Tentacle CLI call, i.e. the first line of this script that
could only be tested against the real binary. Nothing before today had run it.

---

### B23 — probe 8 asked the one host that cannot traverse the VIP to traverse it
**Provenance:** tooling · **Found:** 2026-09-17, first full `verify-egress.sh` run with a runner present · **Fixed:** `mimic_egress` (verify-egress.sh), same day

Probes 1–7 passed from the runner through the VIP (`proxy.egress.mimic.internal` →
NLB → Squid). Probe 8 — "a non-allowed source is refused" — ran on the **proxy host**
and sent its CONNECT **through the same VIP**: `000`, `Connection timed out after 15003
milliseconds`. Not the ACL: an NLB target cannot connect to itself through its own NLB
when client-IP preservation is on — the packet arrives with source == destination ==
its own address and is dropped (AWS's documented hairpin/loopback restriction for
`preserve_client_ip`). The probe would have failed on any correctly configured proxy.

What probe 8 must prove is only that a *different* source is refused; the VIP's
client-IP preservation is already proven by probe 2 (Squid allowed `10.60.0.250` — had
the NLB NATed, Squid would have seen the NLB's address and refused). So probe 8 now
talks to Squid directly on the proxy host's own private address, which Squid sees as a
non-allowlisted source and refuses with 403.

**Found by:** the probe failing and the runner's passes contradicting it. On 2026-09-14
probe 8 had only ever been exercised by hand from the proxy host *directly* to Squid
(where it correctly showed `TCP_DENIED/403`); the through-the-VIP form in the script was
never run before today — a third instance of a check that had not met its real input.

---

### B22 — the deploy-config bundle looked for a tfvars file this repo does not have
**Provenance:** port-induced · **Found:** 2026-09-17, reading `push-deploy-config.sh` before the first bundle push · **Fixed:** same day

`scripts/runner/push-deploy-config.sh` bundled `terraform/environments/<env>/primary.tfvars`
— the single-file convention inherited from besu-aws. Phase D (2026-08-30) split this repo's
tfvars into `common.tfvars` + `chain.tfvars` and no `primary.tfvars` exists under
`environments/`. The script tolerates a missing candidate (it bundles "whichever exist"), so
it would have exited 0 having shipped **only the two hand-over files**, and the first
`terraform plan` run from the In-VPC EC2 Runner would have failed with "No value for required
variable" on all six `common.tfvars` values. Fixed by listing `common.tfvars` and
`chain.tfvars` as the always-shipped candidates; `fetch-deploy-config.sh`'s usage comment
updated to the split form.

**Found by:** reading the script's candidate list against the environment directory before
running it — not by the R-9 mock, which never runs Terraform on the runner and would have
passed. A tolerant "bundle what exists" is the right behaviour for optional files and the
wrong one for the file every root needs; the fix keeps the tolerance and corrects the list.

---

### B21 — the NAT gate crashed on the first route table that carried a non-local route
**Provenance:** port-induced · **Found:** 2026-09-17, first `shared` plan of the R-9 mock · **Fixed:** same day

`modules/network-contract` asserts "no NAT" with
`coalesce(r.nat_gateway_id, "") != ""`. Terraform's `coalesce` treats `""` as *absent*
and **errors** when every argument is absent — and the `aws_route_table` data source
reports `nat_gateway_id = ""` (not `null`) for any route that is not a NAT route. So the
gate could only evaluate cleanly on a route list with **zero** routes, which is exactly
what the ledger tables had until now: the data source omits the `local` route, and Phase C
(2026-08-30) proved the gates against a mimic whose ledger tables had nothing else. The
first `shared` plan after `mimic_egress` added the peering route (`10.61.0.0/24 → pcx-…`,
CD-60) hit three identical errors — one per ledger table — with the message
`Call to function "coalesce" failed: no non-null, non-empty-string arguments`.

The fix is the idiom the neighbouring IGW check already used: a non-empty sentinel,
`coalesce(r.nat_gateway_id, "-") != "-"`. Swept the roots for the same pattern; none.

**Found by:** the plan failing. Not by Phase C — which passed for the wrong reason (an empty
list), the same shape as B19 and B20: a check that "passes" on the input it was written
against is not evidence it works on the input it will meet.

---

### B20 — curl reports a REFUSED CONNECT as `000`, so the egress probes scored allow and deny alike
**Provenance:** tooling · **Found:** 2026-09-14, first live run against the egress mimic · **Fixed:** same day

`verify-egress-proxy.sh` (and the mimic's probe 8) read `-w '%{http_code}'` and expected
`403` when the proxy refused a tunnel. But when a proxy answers `CONNECT` with 403, curl
exits 56 and reports **`http_code=000`** — the proxy's status is a *different* variable,
**`%{http_connect}`**. Verified live from the proxy host: `connect=403 000` for every
refused tunnel, `connect=000 403` for the one plain-HTTP request (no CONNECT involved).
With the old logic probe 4 (deny) would have FAILED on a correctly-configured proxy, and
probe 2 (allow) could not distinguish "refused" from "unreachable".

Now every https probe reads both numbers and scores on `http_connect` (200 = tunnel
accepted, 403 = refused, 000 = no connection); the plain-HTTP probe scores on
`http_code`, which is the proxy's own answer there.

**Found by:** running the four requests by hand from the proxy host while checking the
bootstrap, and noticing `000` where the Squid access log said `TCP_DENIED/403`. Not by
the probe script — which is the point: a verification tool must be tested against the
failure it is meant to detect before it is trusted.

---

### B19 — a failed hand-over render left a 0-byte file and a STALE hand-over in the platform
**Provenance:** tooling · **Found:** 2026-09-14, first live run of the R-9 mock · **Fixed:** `mimic_vpc` (emit-handover.sh)

`emit-handover.sh` rendered with `cat > "$OUT" <<TFVARS … $(terraform output …) … TFVARS`.
The shell **truncates `$OUT` before** evaluating the substitutions, and `set -e` does not
propagate out of a heredoc's command substitutions. On the first run after the af-south-1
apply, the first `terraform output` call failed transiently; the result was a **0-byte**
`network-handover.auto.tfvars`, the copy-into-platform step never ran, and `sbsa_besu`
kept the **Aug-30 us-east-1 hand-over** — internally consistent, well-formed, and pointing
at a VPC that no longer existed. The operator saw only the "rendering…" line and no error.

Now: render to a `mktemp` beside the target, `die` on any failed or empty output read,
assert the render is non-empty and carries `vpc_id` and `network_region`, then `mv` into
place. The same shape belongs in `mimic_egress/scripts/emit-handover.sh` (applied there
too).

**Found by:** the operator pasting the last lines of the run — which ended at
"rendering…" — and a 0-byte file where a 3 KB one should have been. Not by any check: the
platform's network-contract gate would have caught the region mismatch, but only after
`mimic_egress` had tried to peer with a dead VPC ID.

---

### B17 — the runner root read a chain output that does not exist
**Provenance:** port-induced · **Fixed:** 2026-09-14 (R-9 build)

`terraform/runner/main.tf` placed the instance with `local.chain.private_subnet_ids[0]`.
The chain root has never exported `private_subnet_ids`; since the port it exports
**`ledger_subnet_ids`, a map keyed by AZ ID** (#5). Reading a missing attribute from
`terraform_remote_state` is a plan-time error, so the runner root could not have been
planned since the hand-over landed.

Now `runner_subnet_az_id` (default: first AZ in sorted order — deterministic, so a re-apply
never moves the runner) selects the subnet from the map, and the same choice fixes the
address the egress allowlist depends on (CD-60): the AZ, the subnet and the pinned IP are
one decision, not three.

**Found by:** reading the line while wiring `runner_private_ip`, not by a test — the runner
root had not been planned since `ledger_subnet_ids` replaced the list.

---

### B18 — the hand-over never reached the runner, and the config script looked in a root that no longer exists
**Provenance:** port-induced · **Fixed:** 2026-09-14 (R-9 build)

Two halves of one gap. `push-deploy-config.sh` defaulted its secret name from
`terraform -chdir=terraform output …` — the monolithic root that split into
`shared/chain/runner/contract` on 2026-08-30 — so the default never resolved and the
script died with "secret name not given". And its file list carried the env tfvars only:
**`network-handover.auto.tfvars` was never delivered.** It is `*.auto.tfvars`, therefore
gitignored, therefore absent from the `git archive` source bundle (D-21) — so every root
on the runner would have failed with *No value for required variable "vpc_id"*. B14 fixed
the symlinks on the laptop; nothing fixed the file on the runner.

The secret lookup now targets `terraform/chain`; both hand-over files
(`network-handover`, and the new `egress-handover`) ride in the deploy-config bundle;
`fetch-deploy-config.sh` recreates the per-root symlinks after extracting.

**Found by:** asking where `install-tentacle.sh` would read the proxy address from on the
runner, and following the file backwards to the laptop.

---

### B1 — `cidrcontains` does not exist in Terraform
**Provenance:** tooling · **Fixed:** commit `a35c883`

The service-CIDR overlap gate (#9) and a `check` block were written against a
function Terraform does not have. Replaced with integer CIDR arithmetic
(`split`/`tonumber`/`min`/`pow`/`floor`).

The gate matters because the EKS service CIDR is **immutable after cluster
creation** — an overlap discovered later cannot be corrected without rebuilding
the cluster.

**Found by:** `terraform validate`. The only one of these caught for free.

---

### B2 — instance-type offerings compared AZ *name* against AZ *ID*
**Provenance:** tooling · **Fixed:** commit `619acea`

`describe-instance-type-offerings --location-type availability-zone` returns
`us-east-1a`; the script compared it against `use1-az1`. Result:
`m6i.xlarge is NOT offered anywhere in us-east-1`, which is false.

**Found by:** the human reading output that contradicted itself — the summary
said "not offered anywhere" while the table beside it listed availability.

---

### B3 — a jq `index()` inside a pipe made every AZ report "yes"
**Provenance:** tooling · **Fixed:** commit `619acea`

In `$off | index(.[1])`, the `.` inside `index()` refers to *that pipe's input*
(`$off`), not the AZ row — so it evaluated `offers[1]` and was **always truthy**.
Every AZ printed `yes`.

**This is the one worth remembering.** B2 and B3 were both live at once and
**masked each other in opposite directions**: B3 said every AZ had the instance
type, B2 said none did. Fixing either alone would have produced a confidently
wrong answer. The AZ selection they feed decides where validators are placed.

**Found by:** re-reading the script after B2, rather than trusting that one fix
had resolved the contradiction.

---

### B4 — a subshell discarded the verification counters
**Provenance:** tooling · **Fixed:** during Phase B

`jq ... | while read` runs the loop in a subshell, so `PASS`/`FAIL` increments
were lost. The script reported **12 passed** while running **27** checks.

Not cosmetic. A capacity **failure** would have printed its message, been dropped
from the count, and **exited 0** — a broken network reported as contract-clean.
Fixed with process substitution (`done < <(jq ...)`).

**Found by:** the count not matching the number of checks in the file.

---

### B5 — requirements numbered `#14b` with no `#14a`
**Provenance:** tooling · **Fixed:** during Phase A

`NETWORK_REQUIREMENTS_CLOUD_TEAM.md` had a `#14b` with no `#14a`, and worse, it
sat in the Tier 2 section while the summary table marked it Tier 1 — a
priority contradiction in a document being sent to another team.

Renumbered throughout. **One reference, `(see #18)`, was initially missed**: the
fix-up regex covered `(#N)`, `#N `, `#N,`, `#N.` and `#N\n` but not `#N)`.

**Found by:** the human asking "where are points 14a and 14b?", then by dumping
every reference and reading them rather than trusting the regex.

---

### B6 — `Environment = "prod"` hardcoded in `default_tags`
**Provenance:** inherited assumption, invalidated by the port · **Fixed:** `f7ec3ae`

`besu-aws` was prod-only, so a literal `"prod"` in the provider's `default_tags`
was harmless. This project has `test` and `prod`, so **every test resource was
tagged as production** — corrupting cost allocation and making a deploy-test
indistinguishable from the real deployment in the console and the bill.

Now `var.environment`, with **no default** and a validation restricting it to
`prod|test`.

**Found by:** reading `tags_all` in a plan, not by any check.

---

### B7 — the eight gates ran against the wrong region
**Provenance:** port-induced · **Fixed:** commit `d8c2592`

`module "network_contract"` was the **only** module in the repository not passed
`providers = { aws = aws.primary }`. It therefore inherited the *default*
provider, whose region comes from the shell (`AWS_REGION` / profile) rather than
from `var.primary_region`.

Both were `us-east-1` throughout Phase C, so every gate passed either way. At
go-live with `primary_region = "af-south-1"` the gates would have validated a
**different region's network** than the one being deployed into.

**Gate 8 could not have caught it** — it compares two variables, not the
provider's actual region. The gate designed for region portability was itself
region-blind.

**Found by:** noticing the missing `providers` argument while adding a new root
that needed the same wiring — not by testing.

---

### B8 — `output "vpc_cidr"` reported a VPC that does not exist
**Provenance:** port-induced · **Fixed:** commit `b658b62`

The output returned `var.primary_vpc_cidr`, orphaned when `modules/network` was
deleted. The plan reported **`10.0.0.0/16` for a VPC that is `10.60.0.0/20`** —
the variable's stale default, with nothing left in this project able to set it
correctly.

Latent, because no root consumed the output yet. It would have activated the
moment the `app` root read it, and anything scoping a security group or NACL to
that value would have been silently wrong — and wrong in the permissive
direction.

**Found by:** reading the plan output the human pasted. It was visible in an
earlier plan too, and not noticed.

---

### B9 — three images were never parameterised at all
**Provenance:** inherited · **Fixed:** commit `de60ad1`

`stats`, `visualizer` and the `nginx` proxy came straight from the Blockscout
chart's `values.yaml`, hardcoded to `ghcr.io` and `docker.io`. No Terraform
variable reached them.

In an air-gapped VPC those three pods hang on `ImagePullBackOff` while every
other component pulls from the mirror — the worst shape of this failure, because the
working majority makes it look like a Blockscout problem rather than a registry
one.

**Found by:** grepping every chart for image references while designing the
registry indirection, rather than assuming the existing variables covered it.

---

### B10 — `tools_image` was declared but never passed
**Provenance:** inherited · **Fixed:** commit `de60ad1`

`modules/besu` declared `tools_image`; the root never set it. It silently used
the module default, so `alpine/k8s` would have come from `docker.io` regardless
of configuration. A quieter shape of B9: the seam existed and was simply not
connected.

**Found by:** the same grep as B9.

---

### B11 — the Besu version was written down twice
**Provenance:** inherited · **Fixed:** commit `de60ad1`

`26.6.1` appeared both as the fallback in `local.besu_pinned_version` and in the
image reference, free to disagree. Now the image list is the single source and
the fallback reads from it.

---

### B12 — AL2023 requires MIME multipart user data
**Provenance:** port-induced · **Fixed:** commit `3a97ee4`

Installing the private-registry CA needs `user_data` on the node launch template.
EKS 1.35 means AL2023, where user data **must** be MIME multipart: EKS appends
its own `application/node.eks.aws` NodeConfig part, and a bare shell script is
not merged. The node never finishes bootstrapping and the node group rolls back
after ~15 minutes with no useful message.

`ami_type` had never been set — it was left to the API default — so the contract
the user_data had to satisfy was undefined. Now explicit
(`AL2023_x86_64_STANDARD`) and validated.

**Found by:** checking the AMI family before writing the bootstrap, then
**rendering the MIME and parsing it** rather than reasoning about it. The `<<-`
heredoc stripping interacts with a multi-line interpolated PEM, so the column
alignment was verified with Python's `email` parser and `bash -n`, not by eye.

---

### B14 — the hand-over symlinks were gitignored
**Provenance:** port-induced · **Fixed:** commit `d8c2592`

Each root reads one hand-over file through a symlink, so the roots cannot drift.
But `*.auto.tfvars` in `.gitignore` matches the **symlinks** by name, so a fresh
clone would have had every root unwired, failing with missing required variables.

`emit-handover.sh` now recreates them, so a fresh clone plus one script run is
fully wired — no manual step to forget.

**Found by:** checking what `.gitignore` matched before committing.

---

### B15 — the runbook's mimic resource count was wrong
**Provenance:** tooling · **Fixed:** commit `3db725e`

Documented as ~40; the real plan was **65**. The gap was per-subnet route tables
and associations (15 each) and the NACL rules. A count in a runbook is a check —
if the human sees 65 where the doc says 40, they cannot tell a correct plan from
a wrong one.

---

### B16 — the tag API reports deleted resources, so it is the wrong zero-check
**Provenance:** operations · **Found:** 2026-09-04, tearing down the us-east-1 mimic

`terraform destroy` reported **65 destroyed** and `describe-vpcs` returned nothing.
But `resourcegroupstaggingapi get-resources` on the same `DeletionGroup` still
listed **3 ARNs** — two VPC endpoints and a flow log. Describing each one directly
returned `InvalidVpcEndpointId.NotFound` and an empty flow-log list: all three were
already gone. The Resource Groups Tagging API is **eventually consistent and keeps
indexing deleted resources for a while.**

This matters because the teardown discipline (`CLAUDE.md` §9, `docs/test-run-log.md`)
says "sweep by `DeletionGroup` tag, then zero-check", and
`scripts/maintenance/full-delete.sh` is keyed on that same API. Two failure modes:

- **False positive.** A clean teardown looks like a leak. Harmless once, corrosive
  repeatedly — it trains the operator to ignore the zero-check, which is the one
  control standing between a stalled test and an overnight bill.
- **False negative — the dangerous one.** The lag runs in both directions. A
  resource created moments earlier may not be indexed yet, so a tag-API sweep can
  *miss* a live resource and report zero.

**Rule:** the tag API is fine for *discovery* (finding what to delete). The
**zero-check must be a direct service-API describe** — `describe-vpcs`,
`describe-volumes`, `describe-network-interfaces`, `describe-nat-gateways` — filtered
by tag. If a tag-API entry persists after a direct describe says the resource is
gone, re-check in a few minutes rather than chasing it.

---

## The pattern

Twenty-four findings; **four (B2, B3, B4, B7) would have passed silently**, two more (B17, B18) would have failed only on the runner, on the day, B19 *did* pass silently on the first live run, B20 was a verification tool that would have contradicted a correct proxy, B21 was a gate that had only ever been evaluated against an empty list, B22 was a bundle that would have shipped without the one file every root needs, B23 was a negative probe that could not physically reach what it tested, and B24 was a documented assumption about where a third-party binary keeps its state. None of
those four was caught by a test — they were caught by reading output that
contradicted itself, by re-reading a script after a related fix, and by noticing a
missing argument while doing unrelated work.

Two consequences shaped the rest of the build:

1. **The negative test is the test.** Phase C was not considered done when the
   gates passed against a correct network — only when a tag was deliberately
   deleted and the plan was observed to **fail**, citing the right requirement.
   Until then, four gate bugs had been found and two had passed silently, so
   "it passed" was not evidence the gate worked. See `docs/RUNBOOK.md` Phase C.

2. **Render and parse; do not reason about format.** B12's MIME payload was
   verified by rendering it with a sample certificate and parsing the result,
   because the failure mode (node never joins, rollback after 15 minutes, no
   useful message) is expensive and arrives late.

Both practices carry into the deploy-test phases.

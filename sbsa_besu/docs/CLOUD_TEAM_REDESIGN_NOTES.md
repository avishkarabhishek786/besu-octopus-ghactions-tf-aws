# Cloud-Team Redesign — Discussion Record & Design Decisions

**Date:** 2026-08-18 (design discussion) · updated 2026-08-29 · **2026-09-21: §12 added (CT-5, shared EKS — namespace tenancy)**
**Status:** Discussion complete; `CLAUDE.md` written and the platform built against CT-1..CT-4. **2026-09-21: CT-5 recorded from a verbal update — the cluster is no longer ours to build. §12 is the design record; the platform brief is NOT yet rewritten against it** (deliberately — the asks in `NETWORK_REQUIREMENTS_CLOUD_TEAM.md` §9 must be answered first).
**Scope:** This document seeds a **NEW, SEPARATE git project**. The current
`besu-aws` repository is **unchanged** and remains the record of the existing
design. Nothing here is to be applied to this repo.

---

## 0. Why this document exists

After a meeting with the bank's cloud team, four architectural changes were
mandated. They are significant enough that the resulting system is a different
build, not a patch — hence a new project with its own `CLAUDE.md` that inherits
this project's *design principles* (cost guardrails, continuous documentation,
resolve-then-pin versions, no-hardcoding, validator rolling-upgrade safety) while
implementing the cloud team's constraints.

This file is the full record of the analysis and the decisions taken, so the new
project's `CLAUDE.md` can be written from it without re-deriving anything.

---

## 1. The four changes requested by the cloud team

| # | Change |
|---|---|
| CT-1 | **One VPC only.** Besu and the applications share a single VPC. The **cloud team creates the VPC and subnets**; our Terraform is limited to what we build *inside* those subnets (EKS and above). |
| CT-2 | **Private subnets only.** No public subnets, therefore no Internet Gateway. |
| CT-3 | **All container images from a private registry**, not public ones. Settled as **Amazon ECR** 2026-09-04 — see §11. |
| CT-4 | **VPC CIDR may be smaller than /16.** Determine the ideal size, accounting for a future estate of ~a dozen applications competing for IPs with Besu at peak. |
| CT-1a | **2026-09-21.** The cloud team's VPC has **separate subnets per role** (application, data, …), each with **security rules the cloud team defines**. A refinement of CT-1: we no longer choose or size subnets, and our flows must pass rules we did not write. See §12.4. |
| CT-5 | **2026-09-21. We do not build EKS.** A **shared EKS cluster** exists; we are allotted a **namespace** and the cloud team runs the cluster and its maintenance. See §12. |

### Risk ranking (highest first)

1. **CT-2** — by far the biggest. It does not merely remove a resource; it removes
   the entire software supply chain. This is a new workstream, not a config flip.
2. **CT-4** — has a defensible quantitative answer, but depends on a decision the
   cloud team must take with us.
3. **CT-1** — technically easy; the risk is *contract drift* with another team, not code.
4. **CT-3** — mostly mechanical. One genuine trap, and a supply chain that must be
   deliberately mirrored rather than proxied.

Three of the four changes make our Terraform **smaller**. Only CT-2 makes the
system harder.

**2026-09-21:** CT-5 outranks all four. It makes the Terraform smaller again, but it
moves node maintenance — the one operation that can halt a QBFT chain — to another
team's schedule (§12.3), and it turns four cluster-scoped add-ons we install into
dependencies on what the cloud team happens to run (§12.2).

---

## 2. CT-1 — Single VPC, cloud-team-owned VPC and subnets

### 2.1 What gets simpler

`terraform/modules/network` collapses almost entirely. Deleted: Internet Gateway,
NAT Gateways, Elastic IPs, public subnets, public route tables, and the root
variables `primary_vpc_cidr` and `single_nat_gateway`.

### 2.2 Design pushback (raised, and resolved)

PrivateLink between the app and the chain was not only plumbing — it was the
**isolation boundary**. In a single VPC, that boundary must be rebuilt at L3/L4,
and doing it properly is *more* work than the PrivateLink version was:

- NetworkPolicy default-deny (H6 exists in the current repo but ships opt-in — it
  becomes **mandatory**)
- dedicated node group + taints for validators
- separate namespaces + `ResourceQuota`
- security groups scoped per-tier, not per-VPC

**Recommendation made:** run the chain in its **own EKS cluster** inside the shared
VPC rather than co-tenanting with a dozen applications. A second control plane is
~$73/mo — trivial next to a bank ledger sharing a kube-apiserver, CNI and node pool
with unrelated workloads. A shared VPC does not imply a shared cluster.

**→ ACCEPTED (see D-4).**

### 2.3 PrivateLink is RETAINED

**→ DECIDED (D-1):** PrivateLink stays, even within the single VPC.

**Validation required before committing the design.** The AWS endpoint-service
[considerations](https://docs.aws.amazon.com/vpc/latest/privatelink/create-endpoint-service.html)
neither prohibit nor explicitly bless a consumer interface endpoint in the *same*
VPC as the provider NLB, and there is a known sharp edge around placing endpoint
ENIs in the **same subnet** as NLB nodes.

- **Mitigation (already implied by the subnet plan in §5):** endpoint ENIs live in
  dedicated *endpoint subnets*, separate from the *LB subnets* carrying the NLB nodes.
- **Action:** an explicit 10-minute same-VPC PrivateLink smoke test in the **first**
  deploy-test, not during the SWIFT rehearsal.

### 2.4 The thing that will actually bite us: the subnet contract

EKS requires `kubernetes.io/role/internal-elb=1` on subnets for load-balancer
auto-discovery. If the cloud team owns the subnets and their tag policy or
landing-zone guardrail strips or blocks tags, **LB provisioning fails silently and
late** — mid-apply, after budget has been burned. The same exposure applies to:
reachability and Private DNS for the registry endpoints, free-IP headroom, and having >= 3 distinct AZs
for validator topology spread.

**→ DECIDED (D-2): replace `modules/network` with `modules/network-contract`.**
A module that **creates nothing** and **asserts everything**, using `data` sources
plus `precondition` / `check` blocks:

- VPC exists and is the expected one
- N subnets across N distinct AZs (derive AZs from the given subnet IDs — never
  hardcode AZ *names*, which map to different physical AZs per account; use AZ IDs
  where a name is unavoidable)
- required tags present on the right subnets
- free IPs above a threshold
- required VPC endpoints reachable
- no CIDR collision with the EKS service CIDR

Fail in 10 seconds with an actionable message instead of 20 minutes into an apply.
This is the same preflight pattern the current repo already uses for permissioning seeds.

### 2.5 `full-delete.sh` changes (three edits)

Current script is tag-keyed via `resourcegroupstaggingapi` on `DeletionGroup`, and
sweeps NAT/EIP/secrets/volumes.

1. **Drop the NAT and EIP sweep** (`scripts/maintenance/full-delete.sh` lines ~111-118)
   — neither resource exists without an IGW.
2. **Add a resource-type denylist enforced on the tag-API results.** *(The important one.)*
   In a shared VPC, a tag collision on the cloud team's side means we delete **their
   network**. Hard-**abort** if any returned ARN is a `vpc`, `subnet`, `route-table`,
   `internet-gateway`, `transit-gateway*`, `vpc-peering-connection`, or `dhcp-options`.
   **Abort, never skip-and-continue** — a collision means the tagging assumption is
   broken and nothing after it is trustworthy.
3. **Add a leaked-ENI sweep** (and add it to zero-check). Orphaned load-balancer and
   endpoint ENIs used to be cosmetic; against a scarce shared block they silently
   consume the cloud team's addresses and become a cross-team incident.

### 2.6 State boundary

Unchanged in principle: keep **chain state and app state separate**, with the app
reading chain outputs via `terraform_remote_state`. A single VPC does not force
merging state, and the "don't mix" rule still earns its keep.

---

## 3. CT-2 — Private subnets only, no Internet Gateway

### 3.1 The fork

No IGW means **no NAT Gateway is even possible** (NAT requires a public subnet).
So either:

- **(a) Centralised egress** — TGW to an inspection / shared-services VPC and a
  corporate proxy. Internet exists, but every layer needs `HTTP_PROXY`/`NO_PROXY`:
  containerd, kubelet, the Terraform providers, AWS CLI, Helm, the Besu JVM.
  Annoying but bounded.
- **(b) True air-gap** — nothing leaves. Everything in §3.2 and §3.3 becomes mandatory.

**→ DECIDED (D-3): design for (b); treat (a) as a bonus.** A centralised TGW is
permitted if it solves a specific problem, but the build must not *depend* on egress.

### 3.2 AWS APIs need VPC endpoints

The current repo has **zero** VPC endpoints — every AWS call today egresses via NAT.

- **Gateway endpoints (free):** `s3` (also required for ECR layer pulls), `dynamodb`.
- **Interface endpoints (~16):** `ec2`, `ec2messages`, `ssm`, `ssmmessages`
  (**without these three there is no way to reach the runner at all**), `ecr.api`,
  `ecr.dkr`, `sts` (IRSA), `eks`, `eks-auth`, `elasticloadbalancing`, `autoscaling`,
  `secretsmanager`, `kms` (C12 node-key custody), `logs` (Fluent Bit), `monitoring`, `sns`
  (Alertmanager).

**Cost:** ~16 interface endpoints x 3 AZ = **48 ENIs, roughly $350/mo** — which
*exceeds* the ~$100-140/mo of NAT being deleted. This must be stated plainly to the
cloud team: **the change increases cost** unless centralised endpoints already exist
and are shared via a Route 53 private hosted zone. **Ask that question first**; if
shared endpoints exist, the $350 disappears.

### 3.3 The supply chain breaks in four places

| Today | Air-gapped replacement |
|---|---|
| Runner `git clone` from GitHub (`runner_repo_url`) | **→ S3-delivered source bundle (D-21)** |
| `terraform init` -> registry.terraform.io | `terraform providers mirror` -> S3, `.terraformrc` **filesystem_mirror** (D-20) |
| 5 remote Helm repos (kube-prometheus-stack, aws-for-fluent-bit, aws-load-balancer-controller, secrets-store-csi driver + AWS provider) | **OCI charts pushed to ECR (D-22)** — CT-3 must cover charts, not only images |
| OS packages on the runner and nodes | **Static tools in the S3 bundle — no package manager at all (D-21)**, or a golden AMI |

This is a distinct new build stage: **"air-gapped supply chain."**

### 3.4 What keeps working (so nobody over-engineers)

- **Besu needs no internet** — closed network, no public bootnodes.
- **NTP works** via Amazon Time Sync at `169.254.169.123`. Matters for QBFT block timing.
- **Self-managed CA** means no OCSP/CRL fetch. (If SWIFT ever mandates a *public* CA
  for our server cert, revocation checking would need egress — flag at that time.)
- **SWIFT is unaffected** — it arrives over SIPN, which was never internet-facing.
- **To check:** the Blockscout frontend may reach external price/CDN endpoints; disable.

---

## 4. CT-3 — All images from a private registry

Correct call, and it aligns with **H38** (digest pinning) already on the hardening backlog.

> **The registry is Amazon ECR** (decided 2026-09-04). The cloud team's original
> instrument for this was a third-party artefact repository; they subsequently
> preferred ECR, and the analysis agreed. **§11 is the live design record** — read it
> for the mechanism, the blockers and decisions D-16..D-22. This section states the
> constraint and the two traps that pre-date the registry choice.

### 4.1 Current state is worse than it looks

- **Parameterised (good):** Besu, via `besu_image_repository` (`terraform/variables.tf:264`).
- **Hardcoded (must change):** `alpine/k8s:1.30.13` in the besu-node values; and in
  `helm/charts/besu-blockscout/values.yaml` — four `ghcr.io/blockscout/*` images plus
  `nginx:1.27-alpine` and `postgres:16-alpine`.
- **Plus** every image inside the five upstream Helm charts.

Under the project's **no-hardcoding rule**, all of these become
`registry_host` + `repository` + `digest` variables, with a single registry root
threaded from the root module.

### 4.2 The trap that will cost a deploy-test

**Whatever the registry, containerd on every node must be able to reach and trust it
before the first node joins**, and that is node launch-template user-data. The failure
presents as a generic `ImagePullBackOff` with no obvious cause.

With ECR the *certificate* half of this trap disappears — it is publicly trusted, and
kubelet's credential provider authenticates from the node role, so there is no private
CA to install and no pull secret to store or rotate. What replaces it is a set of
**endpoint-policy** traps of the same shape and the same silence: the S3 gateway
endpoint policy must allow the ECR layer bucket, Private DNS must be enabled on
`ecr.api`/`ecr.dkr`, and the ECR endpoint policy must not be scoped to one account.
See §11.3.

### 4.3 The exception that no longer exists

**EKS managed addons** (`vpc-cni`, `coredns`, `kube-proxy` — `terraform/modules/eks/main.tf:388`
onward) pull from **AWS's own ECR account**, not Docker Hub.

Under the original third-party-repository plan this needed a written policy exception,
because those three could not be repointed. **With ECR there is no exception**: they
arrive over the same `ecr.api` / `ecr.dkr` / `s3` endpoints as everything else, so
"all images from ECR" holds without carve-out. Requirement #19 was withdrawn on that
basis. Self-managing the three addons remains rejected — it forfeits EKS-managed
patching and now buys nothing at all.

### 4.4 New preflight

`scripts/preflight/verify-images.sh` — resolve every image reference in the repo and
confirm each **digest** exists in the registry **before** apply. Cheap, and converts a 2am

## 5. CT-4 — CIDR sizing

### 5.1 Why EKS eats IP space

With the AWS VPC CNI, **a pod gets a real VPC IP** — an actual routable address from
the subnet, attached as a secondary IP on an ENI on the worker node. That is what makes
AWS-native networking pleasant (security groups apply to pods, no encapsulation, Flow
Logs see pod traffic) and it is why EKS consumes addresses faster than people expect.

Worse, the CNI does not allocate one at a time. It grabs **whole-ENI chunks** and keeps
a warm pool so pod start-up is not gated on an EC2 API call. On an `m6i.xlarge`
(4 ENIs x 15 IPs) a node running ~20 pods typically **holds ~45 IPs** — ~25 of them
used by nothing, reserved purely to keep scheduling fast.

**So the arithmetic that matters is not "how many pods" but "how many IPs does the CNI hoard."**

### 5.2 Per-node consumption model (`m6i.xlarge`)

| CNI mode | IPs per node | Max pods |
|---|---|---|
| Default (`WARM_ENI_TARGET=1`) | ~45-60 | 58 |
| Tuned (`WARM_IP_TARGET` + `MINIMUM_IP_TARGET`) | ~25-30 | 58 |
| Prefix delegation (`WARM_PREFIX_TARGET=1`) | ~32-48 (rounds to /28s) | 110 |

Planning figures used below: **50 IPs/node default, 30 IPs/node tuned.**

### 5.3 Demand estimate

- **Besu**: 4-6 nodes. (the `besu-aws` load test showed 4x `m6i.xlarge` is the right-size; see `cost-estimate.md` in the frozen reference repo.)
- **A dozen apps**: 6-15 pods each plus their own scaling -> another 10-20 nodes.
- **Total ~26 nodes ≈ 1,300 IPs.**
- **Fixed overhead ≈ 155 IPs:** 16 interface endpoints x 3 AZ (48), 2 shared scaling
  ALBs (60), 3 internal NLBs x 3 AZ (9), EKS control-plane cross-account ENIs (4),
  runner + future RDS/cache (~35).
- **Planning target ≈ 1,455 usable IPs.**

### 5.4 Capacity by prefix (one subnet per AZ, 3 AZs; AWS reserves 5 per subnet)

| VPC CIDR | Total | Per-AZ subnet | Usable/subnet | Total usable | Nodes @50 | Nodes @30 |
|---|---|---|---|---|---|---|
| /20 | 4096 | /22 | 1019 | 3057 | ~58 | ~97 |
| /21 | 2048 | /23 | 507 | 1521 | ~27 | ~46 |
| /22 | 1024 | /24 | 251 | 753 | ~12 | ~20 |
| /23 | 512  | /25 | 123 | 369 | ~4 | ~8 |

**Reading:** Besu alone fits a /22. **A dozen apps changes everything** — /21 lands
*exactly* on the ceiling with zero headroom, which is not a place to be. **/22 flat is
not acceptable** for the target estate and that should be said in writing.

### 5.5 DECISION — the ask

> **Primary ask: one contiguous `/20`, carved from a larger reserved range in their IPAM.**
> **Documented fallback: `/21` + `100.64.0.0/16` secondary CIDR** (see §5.6) if the /20 is refused.

**With a /20, a secondary CIDR is NOT required.** Layout:

| Purpose | Layout | Usable |
|---|---|---|
| Node + pod subnets | 3 x /22 | 3,057 |
| LB / endpoint / data subnets | 12 x /26 | 768 |
| **Total** | **3,840 of 4,096** | 256 spare |

Against a planning target of ~1,455 that is **2.3x headroom on the flat design with
no CNI tricks at all** — no `ENIConfig` CRDs, no `--max-pods` bootstrap argument, no
node recycle, no SG rules spanning two blocks, one less preflight assertion. Given the
build already carries air-gap + a mirrored registry + a shared-VPC contract, **removing a moving part
has real value.**

#### 5.5.1 Two things to keep from the secondary-CIDR design anyway

**1. Dedicated subnets for the chain.** The starvation risk does not vanish with more
addresses — a runaway app HPA can still consume IPs the validators need, and a
dedicated cluster (D-4) was chosen precisely to avoid that coupling. A /20 is large
enough to solve it with subnet boundaries instead:

| Purpose | Layout | Usable | Capacity |
|---|---|---|---|
| Chain nodes+pods | 3 x /24 | 753 | ~15 nodes (need 4-6) |
| App nodes+pods | 3 x /23 | 1,521 | ~30 nodes |
| Shared LB / endpoint / data | 9 x /26 | 576 | — |
| **Total** | **2,880 of 4,096** | **1,216 spare** | |

The chain now has a **hard IP floor no app team can eat into** — the same guarantee
the secondary CIDR would have given, achieved with subnets.

**2. Pod subnets as a variable separate from node subnets**, even when both are set to
the same IDs. Costs nothing now; makes the §5.6 retrofit a tfvars change rather than a
module refactor. Consistent with the no-hardcoding rule.

#### 5.5.2 What to watch

Headroom is 2.3x, not 10x, and "a dozen apps" is an estimate.

- CloudWatch **alarm on free IPs per subnet**.
- Tune `WARM_IP_TARGET` / `MINIMUM_IP_TARGET` — drops per-node consumption ~50 -> ~30
  and takes headroom to **~3.9x**. Cheap insurance, no structural change.
- **Revisit trigger:** app-estate forecast exceeding ~2 dozen nodes, or any single app
  needing its own high-density node group.

### 5.6 Secondary CIDR — reference (the documented fallback)

Retained in full because it is the fallback if the /20 is refused, and the retrofit path
if the estate outgrows the /20.

#### What it is

A VPC is not limited to its original CIDR. You can **associate up to 5 IPv4 CIDR blocks**
with an existing VPC (raisable to 50 by quota). These are not separate VPCs and not
peered — it is the **same VPC**:

- same route tables, with a `local` route added automatically for the new block
- same security groups, same NACLs, same Flow Logs
- subnets from the new block sit alongside existing ones; instances talk to everything
  else in the VPC with no gateway in between

Rules: blocks may not overlap, a block cannot be resized after association, and the
**primary** block cannot be removed.

#### Why `100.64.0.0/10` specifically

`100.64.0.0/10` is **carrier-grade NAT space (RFC 6598)** — not RFC 1918. It was set
aside for ISPs to number customer equipment behind their own NAT. Practically:

- almost never present in a corporate routing table, so it will not collide
- **not part of the enterprise IPAM allocation** — granting `100.64.0.0/16` costs the
  cloud team *nothing*; they are not giving away addresses another team could use
- AWS explicitly recommends it. From the EKS Best Practices Guide: *"AWS recommends
  using CIDRs (/16) from the CG-NAT space, i.e. 100.64.0.0/10 or 198.19.0.0/16 as those
  are less likely to be used in a corporate setting."*

`198.19.0.0/16` is the fallback if the bank already uses CG-NAT space (some do, for VPN
concentrators or F5 tiers — worth asking).

#### How pods are moved onto it

Associating the CIDR is not enough; the CNI must be told to use it. Two mechanisms:

- **Custom networking (`ENIConfig`)** — the established path. One `ENIConfig` custom
  resource per AZ, each naming a subnet from the secondary CIDR plus the security
  groups pods should receive. Set `AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true` and
  `ENI_CONFIG_LABEL_DEF=topology.kubernetes.io/zone`; the CNI then auto-selects the
  right `ENIConfig` per node by AZ label. Every secondary ENI lands in the 100.64
  subnet and **all pod IPs come from there**.
- **Enhanced Subnet Discovery** — newer (VPC CNI 1.18.0+, EKS 1.25+): tag the extra
  subnets `kubernetes.io/role/cni=1` and the CNI discovers and uses them automatically,
  no CRDs. Custom networking takes precedence if both are configured.

**If the fallback is ever taken, use custom networking, not Enhanced Subnet Discovery** —
the opposite of what "newer and simpler" suggests. ESD treats the extra subnets as a
*relief valve*: the node's own subnet is still used for pods, with discovered subnets
consumed when it runs short. That helps if you already have a comfortable RFC 1918 block.
Our goal in the fallback is the reverse — **shrink the RFC 1918 ask**. Only custom
networking guarantees that *zero* pod IPs come from the scarce block, and that guarantee
is what makes a small primary ask credible.

#### Does anything break? (verified, not assumed)

- **On-prem reachability: preserved.** With the CNI default
  `AWS_VPC_K8S_CNI_EXTERNALSNAT=false`, pod traffic to destinations *outside* the VPC's
  CIDR blocks is **SNAT'd through the node's primary ENI** — the node subnet and node
  security group govern that egress, not the pod's. On-prem, the TGW and the registry all see
  an ordinary RFC 1918 node address. **The cloud team never routes `100.64.x` anywhere
  outside the VPC.**
- **Bonus for the firewall team:** allowlists get *shorter*, not longer — three small
  node subnets instead of a sprawling pod range, and the entries stay stable as we scale.
- **On-prem cannot initiate to a pod.** Irrelevant here: SWIFT arrives at an NLB, the
  app reaches the chain via PrivateLink, the operator uses SSM port-forward. Nothing
  dials a pod IP directly.
- **Image pulls unaffected.** Pulls are performed by **containerd on the node**, not by
  the pod. The registry only ever sees node IPs. Pod addressing is irrelevant to CT-3.

#### What it costs

1. **Reduced max-pods.** The primary ENI stops serving pods: `4 x 14 + 2 = 58` becomes
   `3 x 14 + 2 = 44` on an `m6i.xlarge`. Fix with **prefix delegation** (110-pod cap).
2. **`--max-pods` must be set on the node bootstrap to match.** If kubelet advertises 58
   while the CNI can only deliver 44, pods wedge in `ContainerCreating` with no obvious
   cause. Classic trap — belongs in the preflight.
3. **Only new ENIs are affected** — enabling it does not re-IP running pods, so nodes
   must be recycled.
4. **Security groups hardcoding "the VPC CIDR"** stop covering pods. Any rule written as
   a literal primary-CIDR reference must gain the secondary block. Grep for this as an
   explicit migration step.

#### Retrofit path (if the /20 is later outgrown)

Genuinely retrofittable: associate `100.64.0.0/16`, add subnets, enable custom networking.
It affects only newly-created ENIs, so the cost is a **rolling node replacement** — for
the chain, one validator at a time, using the existing H1 rolling-apply tooling. A
controlled maintenance window on a live ledger, not a rebuild. That asymmetry is mild
enough that taking the simpler flat design now is correct.

#### Worked example (fallback layout, for reference)

Primary `10.x.y.0/22` (1024): node 3x/26 (177, = 177 nodes at 1 IP each under custom
networking), endpoint 3x/26, LB 3x/26, data 3x/26 = 768 of 1024, one spare /26 per AZ.
Secondary `100.64.0.0/16` -> 3 x /19 = **8,190 pod IPs per AZ (~24,500 total)**, ~223
nodes of capacity at 110 pods/node, with a spare /18 for a fourth AZ.

### 5.7 Asks to put to the cloud team regardless of which path

- one **contiguous** block, ideally carved from a larger **reserved** range in their
  IPAM so growth never means re-IP
- six subnets from the primary per the §5.5.1 plan (chain / app / LB / endpoint / data)
- subnet tags: `kubernetes.io/role/internal-elb=1` on the LB subnets, plus the EKS
  cluster-ownership tags
- confirmation that the **EKS service CIDR** (default `172.20.0.0/16`) collides with
  nothing reachable over the TGW. **This is immutable after cluster creation** —
  getting it wrong means rebuilding the cluster.

---

## 6. Decisions log

| ID | Decision | Status |
|---|---|---|
| D-1 | **PrivateLink is retained** even within the single VPC; `full-delete.sh` updated per §2.5. Same-VPC endpoint behaviour to be smoke-tested in the first deploy-test. | DECIDED |
| D-2 | `modules/network` becomes **`modules/network-contract`** — creates nothing, asserts everything (§2.4). | DECIDED |
| D-3 | **Design for a true air-gap (b)**; centralised TGW egress permitted as a bonus, never a dependency. | DECIDED |
| D-4 | **Dedicated EKS cluster for the chain** inside the shared VPC; apps run in their own cluster. | DECIDED |
| D-5 | ~~Split registry: ECR endpoints for AWS-owned addon images, a third-party repository for everything else.~~ | **SUPERSEDED by D-16** — one registry (ECR), no carve-out |
| D-6 | ~~Runner source comes from a third-party mirror.~~ | **SUPERSEDED by D-21** — S3 source bundle |
| D-7 | **CIDR ask = contiguous /20, no secondary CIDR.** Chain gets dedicated subnets (§5.5.1). Fallback `/21 + 100.64.0.0/16` documented in §5.6. | DECIDED |
| D-8 | Pod subnets parameterised **separately** from node subnets from day one, even when identical. | DECIDED |
| D-9 | NetworkPolicy default-deny becomes **mandatory** (currently H6, opt-in). | DECIDED |

---

## 7. Open questions — pending cloud-team reply

| # | Question | Impact if unanswered |
|---|---|---|
| Q-1 | Egress model: TGW-proxied, or true air-gap? | Determines proxy plumbing vs full offline bootstrap. Mitigated by D-3 (design for air-gap). |
| Q-2 | Do **centralised VPC endpoints** already exist in a shared-services VPC we can consume? | ~$350/mo. |
| Q-3 | May we **create VPC endpoints** in their subnets, or is that their side of the line? | Ownership of ~16 endpoints. |
| Q-4 | Is `100.64.0.0/10` free on the bank's network? | Only matters if the /20 is refused (fallback path). |
| Q-5 | ~~Third-party repository specifics.~~ **Replaced by Q-4a..Q-4e** (§11 / `NETWORK_REQUIREMENTS_CLOUD_TEAM.md` §8.4): ECR account topology, CVE gating, and who owns the mirror pipeline. | Blocks the supply-chain stage. |

**None of these block drafting the new `CLAUDE.md`** — they are parameters, not
structural forks. Write it with the air-gapped assumption as the default and capture each
unknown as an explicit variable plus a preflight assertion.

---

## 8. What the new project's `CLAUDE.md` must contain

### 8.1 Carried over unchanged from this project

Cost guardrail + mandatory same-day teardown; the continuous documentation mandate;
resolve-then-pin version policy; the H1 validator rolling-upgrade rule (`ignore_changes`
+ `OnDelete` + one-at-a-time); the no-hardcoding rule; the no-deletion-protection rule;
advise-only deployment mode; per-environment state; tag-everything via `default_tags`.

### 8.2 New sections required

| Section | Purpose |
|---|---|
| **Shared-responsibility matrix** | The single highest-value new document. Who owns VPC / subnets / tags / routes / DNS / endpoints / SG rules, and what we are forbidden to touch. Every one of CT-1..CT-4 routes through this table. |
| **Network contract + preflight** | The §2.4 assertions, as a gate before any apply. |
| **Air-gapped supply chain** | New build stage: the ECR mirror pipeline (images **and** Helm charts), the Terraform provider `filesystem_mirror`, the three endpoint-policy traps (§11.3), and `verify-images.sh` run from the runner. |
| **IP budget** | §5 tables kept current, plus the free-IP CloudWatch alarm, so exhaustion is noticed before a validator fails to schedule. |
| **Isolation model** | Replaces "PrivateLink is the boundary" with the NetworkPolicy / taint / namespace / SG model, and records D-4. |

---

## 9. Sources

- [EKS Best Practices — Custom Networking](https://aws.github.io/aws-eks-best-practices/networking/custom-networking/)
- [Amazon VPC CNI introduces Enhanced Subnet Discovery](https://aws.amazon.com/blogs/containers/amazon-vpc-cni-introduces-enhanced-subnet-discovery/)
- [EKS Workshop — Custom Networking](https://www.eksworkshop.com/docs/networking/vpc-cni/custom-networking/)
- [AWS PrivateLink — Create an endpoint service](https://docs.aws.amazon.com/vpc/latest/privatelink/create-endpoint-service.html)

---

## 10. Requirements put back to the cloud team (added 2026-08-29)

The cloud team is an **internal** bank team, so constraints are negotiable where a
change genuinely degrades the architecture. §§2-5 above were re-reviewed to separate
*genuine improvements* from *concessions made only because ownership moved*. The
concessions are now formal asks, written up for sending as
**`NETWORK_REQUIREMENTS_CLOUD_TEAM.md`** (root).

**Framing that matters:** the single-VPC decision (CT-1) is **not** being reversed.
The Tier-2 asks rebuild the equivalent isolation boundary *inside* the shared VPC at
no additional address cost. Presenting it that way keeps the conversation on
engineering rather than on their landing-zone standard.

### 10.1 Additional decisions

| ID | Decision | Status |
|---|---|---|
| D-10 | **Restore in-VPC isolation by ask, not by concession:** dedicated ledger subnets, dedicated route tables, NACL rule management on ledger subnets, and subnet-level flow logs delivered to us. | DECIDED |
| D-11 | **We own the 8 critical interface endpoints** (`kms`, `secretsmanager`, `sts`, `ecr.api`, `ecr.dkr`, `ssm`, `ssmmessages`, `ec2messages`). Rationale: `kms` is on the validator-startup critical path (C12) and the SSM trio is the only runner access path — neither may depend on another team's change queue. | DECIDED |
| D-12 | **Request `100.64.0.0/16` associated at VPC creation but held UNUSED.** Free, consumes no RFC 1918, and converts a future rolling node replacement into a config change. Supersedes the §5.6 framing of the secondary CIDR as fallback-only. | DECIDED |
| D-13 | **Private ECR mirror in our account** (~$1-2/mo). Rationale: validator node replacement must not depend on any service outside AWS. | **PROMOTED by D-16** from fallback to the primary registry |
| D-14 | **Interface endpoint count trimmed 16 → 14.** `eks-auth` dropped (we use IRSA, not Pod Identity); `autoscaling` dropped (no Cluster Autoscaler or Karpenter deployed). `monitoring` retained as insurance — in an air-gapped VPC a missing endpoint hangs rather than errors. | DECIDED |
| D-15 | **VPC `instance_tenancy` must be `default`** — asserted in the network-contract preflight (D-2) *and* stated as a provisioning requirement. Forced dedicated tenancy is irreversible on an existing VPC and adds ~$1,460/mo. | DECIDED |

### 10.2 Additional open questions

| # | Question | Impact |
|---|---|---|
| ~~Q-0~~ | **ANSWERED 2026-08-29: `af-south-1` (Africa, Cape Town).** Follow-ups: it is an **opt-in region** (enable on the account first), and it has **exactly 3 AZs** — the 3-AZ design consumes all of them, so there is no fourth zone to grow into. | RESOLVED |
| ~~Q-6~~ | **ANSWERED (assumed) 2026-08-29: our own account, NOT RAM-shared.** D-1 (retain PrivateLink) therefore stands unconstrained, and the mimic is fully faithful on this axis. **⚠️ RE-SCOPED 2026-09-09 — this assumption is load-bearing for far more than D-1.** AWS assigns interface endpoints, gateway endpoints, route tables, NACLs, subnet attributes and subnet flow logs to the VPC **owner**; participants in a RAM-shared VPC simply cannot create them. If the assumption is wrong: **D-11 becomes impossible** (we cannot own the eight critical endpoints — it is not permitted, not merely discouraged), and requirements **#4, #10, #13, #14** all move to the cloud team. Security groups (#6) stay ours. Whether a participant may create a **VPC endpoint service** is not documented either way, so D-1 still needs its own check. Now asked as **#24** in `CLOUD_TEAM_REQUEST_REGISTRY_AND_CICD.md`, phrased as "which account owns the VPC?" — because "is it shared?" invites the CT-1 answer (shared *usage*, already true) rather than the RAM answer. | RESOLVED (assumption) |
| Q-7 | Are **TGW attachment** and **IPAM** charges cross-charged to consuming teams? | Cost model only, not a design constraint. |

### 10.3 Deliberately NOT asked back

- **NAT / IGW.** Besu needs no internet by design; endpoints plus TGW cover everything real. Asking for NAT back would weaken our own position on the items that matter.
- **A mandated private registry for images.** A genuine improvement, aligned with H38
  (digest pinning). We asked only that it be ECR (D-16), which the cloud team preferred anyway.

---

## 11. CT-3a — The registry design: private ECR, mirrored from outside (2026-09-04)

### 11.0 Status

**DECIDED 2026-09-04.** The cloud team preferred Amazon ECR and the analysis agreed;
the registry is ECR, and the third-party-artefact-repository option is closed. This
section is the live design record for CT-3. §4 states the constraint; §11 states the
mechanism, the blockers and the operational commitments.

Open items are Q-4a..Q-4e in `NETWORK_REQUIREMENTS_CLOUD_TEAM.md` §8.4 — account
topology, CVE gating and pipeline ownership. None of them is a structural fork.

### 11.1 The design

The VPC is unchanged — private subnets only, no IGW, no NAT. Container images and Helm
charts live in a **private Amazon ECR registry**, reached over the `ecr.api` /
`ecr.dkr` interface endpoints plus the `s3` gateway endpoint. Third-party artefacts are
**built, packaged and pushed from outside the VPC**, then only ever pulled from inside.

The endpoints it needs **already existed in the `shared` root** — the AWS-owned addon
images required them regardless — so the marginal infrastructure is approximately zero.

### 11.2 The thing that must not be glossed over

**ECR is a registry, not a proxy.** Nothing appears in it on demand; it serves only what
someone deliberately put there.

Its proxy-equivalent is **pull-through cache (PTC)**, and PTC **cannot work in this
VPC**. AWS documents it plainly:

> When an image is pulled using a pull through cache rule for the first time, if
> you've configured Amazon ECR to use an interface VPC endpoint using AWS PrivateLink
> then you need to create a public subnet in the same VPC, with a NAT gateway, and
> then route all outbound traffic to the internet from their private subnet to the
> NAT gateway in order for the pull to work.
>
> — *Amazon ECR User Guide, "Considerations for using pull through cache rules"*

CT-2 forbids exactly that. Therefore the model is **explicit replication**, and
**somebody owns a mirror pipeline for the life of the platform**.

For a bank this is arguably a feature rather than a cost: every third-party artefact
crosses the boundary through a deliberate, logged, scannable promotion step instead of
an on-demand pass-through. But it must be an accepted commitment, not a surprise.
"ECR will just cache Docker Hub for us" is the single most likely thing to be assumed
in a meeting and discovered during a deploy-test.

Two PTC behaviours we avoid entirely by not using it: it re-validates mutable tags
against upstream every 24 hours, and enabling tag immutability then **blocks** that
update — a combination that would fight H38 rather than support it.

### 11.3 Blockers — will break a deploy-test if missed

#### B-1. The S3 gateway endpoint policy must allow the ECR layer bucket

ECR serves image **manifests** over `ecr.dkr`, but image **layers** come from S3:

```
arn:aws:s3:::prod-<region>-starport-layer-bucket/*
```

The cloud team owns the endpoints (Q-2/Q-3). A least-privilege S3 endpoint policy
scoped to bank-owned buckets — entirely plausible for a bank landing zone — makes
**every image pull fail partway through the layer download**. It presents as a
transient network error mid-pull, not as an authorization failure, so it is diagnosed
slowly and expensively.

This already affects the EKS addons today under D-5. Going all-in on ECR makes it
total: nothing in either cluster starts.

#### B-2. `ecr.dkr` requires Private DNS, and the VPC must use AWS-provided DNS

The ECR guide states that VPC endpoints support **only** AWS-provided DNS via Route 53,
and that the `ecr.dkr` endpoint **must** have Private DNS enabled.

A bank VPC whose DHCP option set points at on-premises AD DNS is common, and it breaks
endpoint resolution silently. Requirement #3 already covers the DHCP option set; it must
now be stated in ECR terms, and `modules/network-contract` should gain a gate asserting
Private DNS is enabled on both ECR endpoints.

#### B-3. Digest preservation across the mirror

`docker pull && docker tag && docker push` **changes the image digest** — Docker
re-manifests on push. H38 (digest pinning), `var.container_images[*].digest` and
`scripts/preflight/verify-images.sh` all depend on the digest being stable from
upstream through to ECR.

**The mirror must use `crane copy` or `skopeo copy --all`**, which copy manifest bytes
verbatim. This is easy to get wrong, it silently invalidates every pinned digest, and
nothing surfaces it until somebody compares by hand.

#### B-4. Cross-account ECR and the endpoint policy

If ECR lives in a central shared-services account — likely, since this is the cloud
team's proposal — then repository policies must grant the workload account's node roles,
and **the ECR endpoint policy must not scope `Principal` or `Resource` to the local
account**. The EKS addons already pull cross-account from AWS's own registry
(`877085696533.dkr.ecr.af-south-1.amazonaws.com` — the addon registry account is
REGION-SPECIFIC; af-south-1 is not the commonly-quoted `602401143452`) through that same
endpoint, so an
"our account only" endpoint policy breaks `vpc-cni`, `coredns` and `kube-proxy`.

Same failure class as B-1: a policy written for good reasons, on a resource we do not
own, that stops container images moving.

#### B-5. A RAM-shared VPC cannot host endpoints we create

> You can't create, describe, modify, or delete VPC endpoints in subnets that are
> shared with you. However, you can use the VPC endpoints in subnets that are shared
> with you.
>
> — *Amazon ECR User Guide, "Shared subnets"*

Q-1/Q-6 records "our own account, not RAM-shared" as an **assumption**. If it breaks,
the `shared` root cannot create the ECR endpoints and the cloud team must own them —
which also negates D-11 for the two endpoints that now carry the entire supply chain.
Cheap to confirm; expensive to discover.

> **Mitigation already in hand.** B-1, B-2 and B-4 are all caught empirically by running
> `scripts/preflight/verify-images.sh` **from the in-VPC runner** before the chain apply.
> That preflight is the gate. It must never be run from the laptop, which would pass
> while the cluster still cannot pull.

### 11.4 What ECR cannot host at all

These need a different answer, not a different registry.

| Artefact | Replacement |
|---|---|
| **Terraform providers** | `terraform providers mirror` → sync directory to S3 → `aws s3 sync` onto the runner → `.terraformrc` **`filesystem_mirror`**. Filesystem, **not** network mirror: a network mirror needs an HTTPS service; a filesystem mirror needs only a directory. Runs entirely over the existing S3 gateway endpoint. |
| **OS packages / runner tooling** | See §11.4.1. |
| **Runner source (GitHub clone)** | S3 bundle. Already the plan (D-6 becomes moot). |

#### 11.4.1 The runner bootstrap

`terraform/modules/runner/main.tf:166-181` reaches `dnf` repositories, `dl.k8s.io`,
`raw.githubusercontent.com`, `rpm.releases.hashicorp.com` and `awscli.amazonaws.com`.
All five hang in an air-gapped VPC.

**This was broken before the registry decision and is unrelated to it** — an unavoidable
item, not a cost of choosing ECR. Two paths:

- **Make `dnf` work.** AL2023 repositories are hosted in S3 (`al2023-repos-<region>-de612dc2`),
  so that bucket joins the starport bucket in the S3 endpoint policy. Caveat: the AL2023
  mirrorlist uses an `s3.dualstack.` URL which has historically not resolved through an
  IPv4-only gateway endpoint (amazonlinux/amazon-linux-2023 issue #535). Verify current
  behaviour, pin the mirrorlist to the non-dualstack URL, or make the endpoint dual-stack.
- **Remove the package-manager dependency entirely — RECOMMENDED.** `kubectl`, `helm`,
  `terraform` and the AWS CLI are all static tarballs; ship them in the same S3 bundle as
  the source. `tar` and `openssl` are in the AL2023 base image, and `git` is unnecessary
  once source arrives as a bundle. The runner then needs **zero** package repositories,
  which is also one fewer thing for the cloud team to whitelist.
- Or Q-5's golden AMI, which the bank may mandate regardless.

### 11.5 Helm charts — a conversion, not a configuration line

ECR stores Helm charts as OCI artefacts (Helm ≥ 3.8; the pinned `hashicorp/helm ~> 2.14`
provider supports `oci://` repositories). But the five upstream charts are served from
**classic HTTP repositories**, so the work is:

1. `helm pull` each pinned chart from upstream, on the build host.
2. `helm push oci://<acct>.dkr.ecr.<region>.amazonaws.com/charts`.
3. Rewrite five `helm_release` blocks from `repository = "https://…"` to `oci://…`:
   - `terraform/modules/rpc-access/main.tf:75`
   - `terraform/modules/secrets/main.tf:330`
   - `terraform/modules/observability/main.tf:278`
   - `terraform/modules/observability/main.tf:344`
   - `terraform/modules/storage-csi/main.tf:174`
4. Supply `repository_username` / `repository_password` from
   `data.aws_ecr_authorization_token`.

Two wrinkles: the ECR authorization token is valid for **12 hours** (fine for an apply,
awkward for a resumed one), and the packaged `.tgz` must carry its subcharts.
`kube-prometheus-stack` vendors grafana, kube-state-metrics and prometheus-node-exporter
under `charts/`, but a chart that resolved dependencies at install time would reach for
the internet — verify on pull rather than assume.

**This is the one place ECR costs more than a chart-proxying repository would have** —
there, a Helm proxy repo is a single configuration line. Recorded honestly so the trade
is not overstated: it is roughly a day, against four risks that each end a deploy-test
(§11.7).

The **per-chart image overrides remain required either way.** The 15 chart-carried images
enumerated in `../../CHART_IMAGES.md` are registry-independent; that document
stays valid verbatim, and PORTING item 4's gap is unchanged.

### 11.6 Operational obligations we inherit

| # | Obligation | Why |
|---|---|---|
| O-1 | **We own freshness.** No proxy means no auto-fetch. | Any `besu_version`, chart or addon bump not mirrored first reproduces exactly the `ImagePullBackOff` hang the design exists to prevent. Make `verify-images.sh` a hard precondition of the chain apply **and** of `scripts/maintenance/rolling-besu-upgrade.sh`. |
| O-2 | **No aggressive lifecycle policy.** | A validator replaced eight months later must still find its exact digest. No conflict with the no-deletion-protection rule — that rule forbids *blocking* deletion, not auto-expiry. |
| O-3 | **Tag immutability ON** (off by default). | Cheap, and it reinforces H38 at the registry rather than only at plan time. |
| O-4 | **Node role vs. the H5 permissions boundary.** | Pulling from ECR requires IAM: nodes need `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`, `ecr:BatchCheckLayerAvailability`. The boundary added in commit `6648bae` is static-validated only — this is precisely what it will catch at an inconvenient hour. |
| O-5 | **Decide who builds and pushes.** | The laptop with `crane` is adequate now. For go-live, **CodeBuild not attached to a VPC** is the shaped answer: it has internet, it is in-account and auditable, costs pennies, and does not violate "no egress from the VPC" because it is not in the VPC. |
| O-6 | **Region.** | ECR is regional. Deploy-tests in `us-east-1`, production in `af-south-1` → either mirror twice, or use ECR **cross-region replication** and keep one source of truth. |
| O-7 | **CMK encryption**, if the bank wants C12-consistent posture. | Node role plus the existing `kms` endpoint cover it. |

### 11.7 What the design gets to delete

This is the substance of the case for ECR — five open risks and work items disappear:

| Removed | Was |
|---|---|
| **The containerd private-CA trap** | `CLAUDE.md` §5.2: "the single most likely cause of a lost deploy-test". ECR presents a publicly-trusted certificate → `registry_ca_cert_pem = ""`, `registry_cert_publicly_trusted = true`. The AL2023 MIME-multipart user-data work stays built but is no longer load-bearing for image pulls. |
| **`dockerconfigjson` pull secret + rotation** | Was still open in PORTING item 4. Kubelet's ECR credential provider authenticates from the node role. No secret, no rotation, no ServiceAccount attachment. |
| **The network path to an off-AWS registry** | Route, DNS, firewall and security-group work in another team's queue — the longest-lead item in the whole supply chain. ECR is an AWS service on an endpoint we already own. |
| **`public.ecr.aws` has no usable endpoint** | `../../CHART_IMAGES.md` finding #1: no `ecr-public.dkr` anywhere, and no `ecr-public` at all in `af-south-1`. Those three images become ordinary private ECR repositories. |
| **The D-5 carve-out** | One registry, no exception to defend, and requirement #19 (written exception for AWS addon images) can be withdrawn. |

Gained for free: Amazon Inspector scanning, registry-enforced tag immutability, IAM-native
authentication, and CloudTrail coverage. And **no service outside AWS sits on the
validator-restart critical path** — which is the reason D-13 already wanted an ECR mirror
as a fallback. CT-3a simply promotes that fallback to the primary.

### 11.8 Cost

23 images (8 platform + 15 chart-carried), roughly 10–20 GB → **USD 1–2/month** at
$0.10/GB-month. In-region data transfer to EC2 is $0.00/GB. The `ecr.api` / `ecr.dkr`
endpoints are already provisioned and already paid for under D-5.

CodeBuild for the mirror pipeline (O-5), if adopted, is a few cents per run.

### 11.9 What changes in the repository

Deliberately small — the registry abstraction built on 2026-08-30 already covers this.

**No code change required to point at ECR.** Only tfvars:

```hcl
registry_host                  = "<acct>.dkr.ecr.<region>.amazonaws.com"
registry_repo_prefixes         = { "docker.io"       = "docker-hub",
                                   "ghcr.io"         = "ghcr",
                                   "quay.io"         = "quay",
                                   "registry.k8s.io" = "k8s",
                                   "public.ecr.aws"  = "ecr-public" }
registry_ca_cert_pem           = ""
registry_cert_publicly_trusted = true
```

ECR repository names permit `/`, so the prefix scheme in `terraform/chain/main.tf:42-44`
maps one-to-one.

New or changed work:

| Item | Effort |
|---|---|
| `modules/registry` — ECR repositories, `for_each` over the image list, tag immutability, no lifecycle expiry, optional CMK | small |
| `scripts/supply-chain/mirror-images.sh` — `crane copy` by digest (B-3), reading the list from Terraform the way `verify-images.sh` does | small |
| Five `helm_release` blocks → `oci://` + `aws_ecr_authorization_token` (§11.5) | medium |
| Runner bootstrap → S3 bundle of static tools, no `dnf` (§11.4.1) | medium |
| `.terraformrc` `filesystem_mirror` + provider bundle in S3 (§11.4) | small |
| `network-contract` gate: Private DNS on both ECR endpoints (B-2) | small |
| Guard rewrite: make the prod-time "registry_host must be set" message in `terraform/chain/main.tf` registry-accurate | ✅ done 2026-09-04 |
| `NETWORK_REQUIREMENTS_CLOUD_TEAM.md` addendum — requirements #20–#25 | done, see §8 of that document |

### 11.10 Decisions

| ID | Decision | Status |
|---|---|---|
| D-16 | **A private Amazon ECR registry is THE container registry** for this platform, with artefacts built and pushed from outside the VPC and pulled from inside over the existing endpoints. | **DECIDED** 2026-09-04 |
| D-17 | **Pull-through cache is NOT used.** It requires internet egress on first pull (§11.2). The supply chain is an explicit, curated replication pipeline. | DECIDED (technical, not negotiable) |
| D-18 | **The mirror preserves digests** — `crane copy` / `skopeo copy --all` only. Never `docker pull`/`tag`/`push`. | DECIDED |
| D-19 | **`verify-images.sh`, run from the in-VPC runner, is the gate** for B-1/B-2/B-4, and a hard precondition of both the chain apply and any validator image bump (O-1). | DECIDED |
| D-20 | **Terraform providers move to an S3 `filesystem_mirror`**, not a network mirror. | DECIDED |
| D-21 | **The runner drops its package-manager dependency** — static tools delivered by S3 bundle (§11.4.1). | DECIDED |
| D-22 | Helm charts are **converted to OCI artefacts in ECR**, accepting that this is more work than a chart-proxying repository would have been (§11.5). | DECIDED |

**Supersessions, effective 2026-09-04:**

- **D-5** (split registry: ECR for addons, another repository for everything else) →
  collapsed. One registry, no carve-out.
- **D-6** (runner source from a third-party mirror, PROVISIONAL) → resolved as an S3
  bundle (D-21).
- **D-13** (private ECR mirror as a fallback) → promoted from fallback to primary.
- **Q-5** (third-party repository specifics) → replaced by Q-4a..Q-4e.
- **Requirements #8 and #19** → withdrawn (§8.2 of the requirements document).
- The standing brief for provisioning a third-party artefact repository was **deleted**;
  its only registry-independent content — the 15 chart-carried images — lives on in
  `../../CHART_IMAGES.md`.

### 11.11 Sources

- [Amazon ECR — Sync an upstream registry with a private registry (pull through cache)](https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache.html)
- [Amazon ECR — Interface VPC endpoints (AWS PrivateLink)](https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html)
- [Amazon ECR — Pushing a Helm chart to a private repository](https://docs.aws.amazon.com/AmazonECR/latest/userguide/push-oci-artifact.html)
- [Amazon Linux 2023 — Managing repositories and OS updates](https://docs.aws.amazon.com/linux/al2023/ug/managing-repos-os-updates.html)
- [AWS re:Post — Update yum on an EC2 instance without internet access](https://repost.aws/knowledge-center/ec2-al1-al2-update-yum-without-internet)
- [amazonlinux/amazon-linux-2023 issue #535 — dnf resolves to the s3.dualstack URL](https://github.com/amazonlinux/amazon-linux-2023/issues/535)
- [Amazon ECR pricing](https://aws.amazon.com/ecr/pricing/)

---

## 12. CT-5 — Shared EKS cluster, namespace tenancy; role-separated subnets with cloud-team rules (2026-09-21)

### 12.0 Status

**RECORDED 2026-09-21 from a verbal update. Nothing below is confirmed in writing yet.**
The cloud team said two things:

1. **We do not build EKS.** A **shared EKS cluster** exists. We are allotted a
   **namespace** in it; the cloud team runs the cluster and all of its maintenance.
2. **Their VPC has separate subnets per role** — application subnets, data subnets,
   and so on — and each subnet carries **security rules the cloud team defines**.

Together these move the platform from *owner of two clusters inside someone else's
VPC* (CT-1) to **tenant of one namespace inside someone else's cluster**. It is a
larger change than CT-1 was, and it has the same shape as CT-1 and R-9 before it: a
**hand-over of plain values**, a **contract module that asserts it**, and a **mimic
that impersonates it**. This section is the design record. The sendable asks are
`NETWORK_REQUIREMENTS_CLOUD_TEAM.md` **§9 (#27–#38)**.

The work is on branch **`shared-eks-namespace`**; the own-cluster design is frozen on
**`own-eks-cluster-design`** at `3af66e8`. The platform brief (`CLAUDE.md`) is **not**
rewritten yet — §12.11's asks decide which files are deleted versus made conditional,
and guessing would be rework. `CLAUDE.md` carries a banner pointing here.

### 12.1 What was said, and what it means for us

| Said | Means |
|---|---|
| "A shared EKS cluster; you get a namespace" | We are a **Kubernetes tenant**. Everything cluster-scoped — the cluster, node groups, addons, CRDs, DaemonSets, StorageClasses, webhooks, cluster RBAC — is theirs. We own what lives inside our namespace(s) and the AWS resources beside the cluster (KMS, Secrets Manager, NLBs, IAM roles, SNS, buckets, the runner). |
| "We manage the maintenance" | **Node rotation and Kubernetes upgrades happen on their schedule**, with their tooling. This is the operation that can halt a QBFT chain (§12.3). |
| "Separate subnets for applications, data, …" | **Our pods land wherever their node groups are** — presumably the application subnets — beside every other tenant's pods. We no longer choose, size or route subnets. The 15-subnet plan and the `/20` ask (CT-4, CD-42..45) were sizing for a VPC we now merely occupy. |
| "Security rules defined on the subnets" | Every flow our design needs that crosses a subnet boundary must be permitted by rules **we did not write and cannot see without asking**. Subnets are per-AZ and validators are AZ-spread, so **every P2P connection crosses one** (§12.4). |
| (implied) "one namespace" | One namespace for the ledger **and** the application estate would share RBAC, `ResourceQuota` and Pod Security Admission between validators and application pods. We ask for **two** (§12.3, #27). |

### 12.2 What the platform owns today that a tenant cannot

Verified against the code on 2026-09-21, not from memory.

**Terraform — creates the cluster and everything cluster-scoped:**

| What | Where | Fate |
|---|---|---|
| EKS cluster, OIDC provider, managed node group, `vpc-cni` / `coredns` / `kube-proxy` addons, launch template + AL2023 MIME user data (B12), `ami_type` | `terraform/modules/eks/main.tf` | **Leaves `sbsa_besu`** → becomes the core of `mimic_eks` (§12.8) |
| Cluster IAM role, node IAM role | `terraform/modules/iam` | Leaves. **IRSA roles stay** but trust *their* OIDC provider (or Pod Identity — #31) |
| EBS CSI addon + `gp3` StorageClass (KMS-encrypted) | `terraform/modules/storage-csi/main.tf:88-116` | Leaves — a StorageClass is cluster-scoped. Asserted instead (#30) |
| Runner EKS access entry + **admin** policy association | `terraform/modules/runner/main.tf:110-126` | Leaves — the cloud team creates it, **namespace-scoped** (#32). `runner_scope = "in-cluster"` (CD-54) becomes the only mode that makes sense |
| `create_namespace = true` | `terraform/modules/besu/main.tf:153` (genesis), `terraform/modules/observability/main.tf:282` (kube-prometheus-stack) | Must be `false`; the namespace is an input |

**Four cluster-scoped add-ons we install as `helm_release`s — and the CRDs our own charts consume from them.** A tenant cannot install any of these (DaemonSets, CRDs, webhooks, cluster RBAC):

| Add-on | Installed at | Our charts consume its CRD | If the cluster does not provide it |
|---|---|---|---|
| aws-load-balancer-controller | `modules/rpc-access/main.tf:71` | `TargetGroupBinding` — `besu-rpc-edge`, `besu-app-rpc-edge` | No namespaced substitute binds pod IPs to a Terraform-made NLB target group. **Hard dependency** — #30 |
| secrets-store-csi-driver + AWS provider | `modules/storage-csi/main.tf:170`, `modules/secrets/main.tf:326` | `SecretProviderClass` — `besu-node` (how validator keys reach pods, C12) | Init container fetching from Secrets Manager via IRSA. Namespaced, no CRD; loses the CSI mount's tmpfs-only guarantee — a C12 note, not a blocker |
| kube-prometheus-stack | `modules/observability/main.tf:274` | `PodMonitor`, `PrometheusRule` — `besu-monitoring` | If the **operator** exists we run our own `Prometheus`/`Alertmanager` CRs in-namespace and keep Alertmanager→SNS. If nothing exists: a plain Prometheus StatefulSet with static scrape config — namespaced, CRD-free, uglier |
| aws-for-fluent-bit | `modules/observability/main.tf:340` | — | Their central shipper; we need our log group readable, or a sidecar per pod |

**What survives untouched** — and it is most of the platform's value: our six charts create
**zero** cluster-scoped kinds (checked); genesis, permissioning (C6), PKI, KMS custody
(C12), the mTLS NLB, the H1 rolling rule; the ECR mirror and `supply-chain.yml`; the
runner, the polling Tentacle and `mimic_egress` (the whole R-9 result, CD-55..CD-65);
`NetworkPolicy`, `PodDisruptionBudget`, and topology spread on both `zone` and
`hostname` (already in `besu-node/templates/statefulset.yaml:70-78`); and the
hand-over-as-plain-values pattern, now applied a third time.

### 12.3 The three things that are not mechanical

**1. Their node maintenance versus QBFT quorum — the dangerous one.** H1 holds today
because *we* control node rotation: the validator PDB (`maxUnavailable = 0`) blocks
drains, and the RUNBOOK says rotate one node at a time with a quorum check between.
In a shared cluster **they** rotate nodes and upgrade Kubernetes, on their schedule,
with their tooling. Our PDB will block their drain, and one of two things happens:
their tooling stalls and they escalate to us, or it **force-evicts** — a managed
node-group update with `--force` ignores PDBs by design — and if two validators share
a node, or two nodes are rotated in one pass, quorum is lost and **the chain halts.**
This cannot be fixed with configuration on our side alone. It needs a **written
operational contract** (#29): PDBs respected, never forced, one node at a time, notice
and a window; plus, on our side, pod anti-affinity by `hostname` promoted from
preferred to **required**, so no node ever carries two validators. Besu-versus-Kubernetes
compatibility is now tested on *their* upgrade cadence, not ours (#36).

**2. Node-level isolation is gone unless requested.** §6 of the platform brief relies
on a dedicated, tainted validator node group and per-tier security groups. Both need
node control. Without a dedicated node pool, validators share kernels with other
tenants' pods — a real security-posture regression for a payment ledger, to be raised
rather than absorbed. The ask (#28) is standard multi-tenant practice and, given CT-1a,
fits their own vocabulary: **a ledger node group in dedicated ledger subnets**, tainted,
with our namespace the only one tolerating it. That also restores #11, gives the
validators a NACL boundary, and makes subnet flow logs possible again. If refused, the
compensating control is `NetworkPolicy` default-deny (D-9, H6), which goes from
*mandatory-and-additive* to **load-bearing**, and the regression is stated in writing.

**3. Two clusters become one.** D-4 (a dedicated chain cluster), D-1 (PrivateLink
retained between the clusters), the PrivateLink consumer endpoint in the `app` root, and
the Stage 3.0 same-VPC smoke test (the `app` gate) all disappear. Ledger ↔ application
becomes in-cluster networking under `NetworkPolicy`, which is simpler. But it collapses
into one namespace unless we ask otherwise: **two namespaces** (ledger, app), because
RBAC, `ResourceQuota` and Pod Security Admission are namespace-granular and the event
listener (E-14) must not share any of them with validators. Whether the application
estate lands in this shared cluster at all is **Q-8**.

**One concrete trap, found in the chart.** `besu-node/templates/statefulset.yaml:174`
runs an init container as `runAsUser: 0` — the F32/F32b ownership fix for the
permissions file. If the namespace enforces Pod Security Admission at `restricted`, that
pod is **rejected at admission** (`restricted` forbids root explicitly). Either the
namespace is `baseline` (#27) or the fix is redone without root before anything is
applied. This is exactly the class of thing a mimic must reproduce (§12.8).

### 12.4 CT-1a — the subnet security rules are a gate, in the "hangs, does not error" class

Subnets are per-AZ; validators are spread across three AZs; so every validator-to-validator
packet crosses a subnet boundary and meets rules we did not write. A blocked P2P
rule does not fail an apply — the chain simply never reaches quorum, and the symptom is
`Peer count: 0` with nothing else wrong. The same is true of the NLB health check (targets
stay `unhealthy` forever) and of the runner's path to the control plane (`i/o timeout`).

**The flows the design needs**, from the charts and `modules/rpc-access` as of 2026-09-21:

| # | Flow | Port / proto | From → To |
|---|---|---|---|
| F-1 | QBFT P2P | **30303 TCP and UDP** | node subnet ↔ node subnet, all three AZs |
| F-2 | SWIFT RPC and app RPC, NLB **IP targets** | 8545, 8546 TCP | LB subnet → node subnet — plus the NLB **TCP health check** on the same port |
| F-3 | Return traffic for F-2 (only if the rules are **stateless** NACLs) | 1024–65535 TCP | node subnet → LB subnet |
| F-4 | Prometheus scrape | 9545 TCP | wherever their Prometheus runs → node subnet (or intra-namespace if we run our own) |
| F-5 | AWS APIs — ECR, STS, KMS, Secrets Manager, logs, SNS, SQS, ELB, SSM… | 443 TCP | node subnet and runner subnet → endpoint subnet (+ return if stateless) |
| F-6 | S3 gateway — image **layers**, state, the runner bundle | 443 TCP | node subnet and runner subnet → **the S3 prefix list**. NACLs cannot reference a prefix list; the rule must cover S3's published CIDRs for the region — a classic trap |
| F-7 | Runner → EKS private endpoint | 443 TCP | runner subnet → the control-plane ENIs in *their* cluster subnets |
| F-8 | Runner → egress proxy VIP (Octopus polling, CD-57) | the proxy port | runner subnet → the egress prefix, over their TGW route |
| F-9 | Blockscout → Postgres | 5432 TCP | intra-namespace if in-cluster; node subnet → **data subnet** if RDS (#37) |
| F-10 | DNS | 53 | to the VPC resolver — **NACLs do not apply** to the Amazon-provided resolver, so nothing to ask; SGs must still permit it if pods carry their own |

Two facts about the rules themselves decide the shape of the ask: whether they are
**NACLs** (stateless — F-3 and every "+ return" above are real rules) or **security
groups** (stateful), and whether the **node security group** — theirs, inherited by every
pod under the VPC CNI — admits our NLB on F-2. That last one is a rule *they* add, unless
Security Groups for Pods is enabled and we attach our own (#33).

**Decision (D-29):** the flow table is a numbered requirement (#34), and it is
**asserted, not assumed** — a read-only preflight in the spirit of
`verify-endpoints.sh` reads the NACLs and security groups on the node, LB and runner
subnets (`ec2:DescribeNetworkAcls`, `ec2:DescribeSecurityGroups`; free) and evaluates
them against F-1..F-9, citing the flow number on failure. It runs before anything
billable, and the same shift applies that CD-38 made for the ECR endpoint policy: **from
"configure this for us" to "here are the flows — confirm your rules permit them."**

### 12.5 The cluster hand-over — `eks-handover.auto.tfvars`

Consumed as plain variables, never via `terraform_remote_state` — the same rule as the
network and egress hand-overs, for the same reason. The shape (names indicative; fixed
when the contract module is written):

| Input | Why |
|---|---|
| `cluster_name`, `cluster_endpoint`, `cluster_ca_data`, `cluster_version` | kubeconfig for the runner and the `kubernetes`/`helm` providers; version for the Besu compatibility gate |
| `oidc_provider_arn` + issuer URL, **or** `pod_identity = true` | which IAM-to-service-account mechanism our roles trust (#31) |
| `namespace_ledger`, `namespace_app` | the two namespaces (#27) |
| `psa_level` | `baseline` or `restricted` — decides the F32 init-container question (§12.3) |
| `storage_class_name`, `storage_class_kms_key_arn` | the StorageClass we may use for chain data and Postgres (#30); whose key encrypts it |
| `cluster_provides_lbc`, `cluster_provides_secrets_store_csi`, `cluster_provides_prometheus_operator`, `cluster_provides_log_shipping` | the four add-on booleans; each gates an assertion and selects the fallback (§12.2) |
| `node_group_dedicated`, `node_taint`, `node_label` | whether #28 was granted, and the toleration/selector to use |
| `node_subnet_ids`, `node_sg_id`, `node_role_arn` | where our pods live (F-1..F-6); the SG that must admit the NLB (#33); the principal that pulls from our ECR repositories (#38) |
| `lb_subnet_ids`, `runner_subnet_id` | where our NLBs and the runner go (CT-1a) |
| `network_policy_enforced` | the CNI enforces `NetworkPolicy` (#35) — H6 is load-bearing now |
| `runner_access_entry_created` | they created the namespace-scoped access entry for the runner role (#32) |

**What the network hand-over loses** (it stays, smaller): `ledger_subnet_ids`,
`app_subnet_ids`, `endpoint_subnet_ids`, `data_subnet_ids`, the four route-table maps,
`ledger_nacl_ids`, `dhcp_options_id`, `gateway_endpoints_created_here`. **What it keeps:**
`vpc_id`, `vpc_cidr_primary` (security-group authoring), `az_ids` (gate 7 still catches a
stale hand-over), and the egress values. The subnet inputs move to the cluster hand-over
above because they are now facts *about the cluster's placement*, not about a VPC we lay
out.

**`modules/network-contract`** loses gates 2 (placement of *our* subnets), 3 (the
`internal-elb` tag — we bind pods to a Terraform-made NLB via `TargetGroupBinding`, so the
controller creates no load balancer and discovers no subnet), 5 (capacity of *our*
subnets) and 6 (the EKS service CIDR — theirs). It keeps 1, 4 (no default route — still
ours to refuse), 7 and 8. A new **`modules/cluster-contract`** carries the cluster-side
gates: version, private endpoint, OIDC/Pod Identity, the four add-on CRDs, the
StorageClass, the namespaces and their PSA labels, the access entry — AWS-side ones from
anywhere, Kubernetes-side ones **from the runner** (the endpoint is private; a laptop
cannot ask).

### 12.6 What changes in the repository

| File / area | Change |
|---|---|
| `terraform/modules/eks/` | Moves to `mimic_eks/terraform/modules/eks/` (§12.8). Deleted from the platform |
| `terraform/modules/iam/` | Cluster and node roles removed. IRSA roles parameterised on `oidc_provider_arn` from the hand-over (or Pod Identity associations if #31 says so) |
| `terraform/modules/storage-csi/` | Addon, StorageClass and the Secrets Store CSI `helm_release` removed. Becomes an assertion on `storage_class_name` |
| `terraform/modules/secrets/` | The AWS-provider `helm_release` removed; `SecretProviderClass` path kept behind `cluster_provides_secrets_store_csi`, init-container fetch as the alternative |
| `terraform/modules/rpc-access/` | LBC `helm_release` removed; `TargetGroupBinding` asserted available. NLB subnets = `lb_subnet_ids`; target ingress = a rule on *their* node SG (#33) or an SGP-attached SG of ours |
| `terraform/modules/observability/` | kube-prometheus-stack and fluent-bit `helm_release`s removed; `Prometheus`/`Alertmanager` CRs in-namespace behind `cluster_provides_prometheus_operator`; SNS, alarms, CloudTrail stay |
| `terraform/modules/besu/`, `blockscout/` | `create_namespace = false`; namespace from the hand-over; tolerations/selectors from `node_taint`/`node_label`; anti-affinity by hostname → `required` |
| `terraform/modules/runner/` | Access entry + policy association removed (they create it, #32). Cluster identity from the hand-over, not from `chain` state. `runner_scope = "in-cluster"` becomes the default |
| `terraform/modules/network-contract/` | Gates 2, 3, 5, 6 removed (§12.5) |
| **new** `terraform/modules/cluster-contract/` | The EKS analogue of `network-contract`: creates nothing, asserts everything, one requirement number per failure message |
| `terraform/contract/handover.tf` | Network inputs trimmed; new `eks-handover` contract file symlinked the same way |
| `terraform/chain/` | AWS layer shrinks to KMS, Secrets Manager, PKI, NLBs + target groups, IRSA roles, CloudTrail, buckets, SNS/alarms. The committed `chain.plan` (106 resources) is superseded |
| `terraform/app/` | Never created (PORTING item 5). Now: no cluster, no PrivateLink endpoint. SQS/SNS/S3 + IRSA roles + the app namespace's workloads |
| `terraform/shared/` | The PHZ stays ours. Interface endpoints: `central_interface_endpoints = true` was already the production setting (CD-39); their cluster needs the same endpoints, so **the shared root creates nothing in the bank** and `verify-endpoints.sh` is the check |
| `helm/charts/besu-node/` | `runAsUser: 0` init container (F32) — conditional on `psa_level`, or redone non-root (§12.3) |
| `helm/charts/besu-blockscout/` | Postgres StatefulSet kept, or replaced by an RDS reference, per #37 |
| `scripts/preflight/` | **new** `verify-subnet-rules.sh` (D-29); `verify-endpoints.sh` unchanged; `verify-images.sh` unchanged but the image list shrinks |
| `scripts/maintenance/full-delete.sh` | No cluster to delete; the abort-on-hit denylist (item 7) gains `eks:cluster`, `eks:nodegroup`, and anything in a namespace that is not ours |
| `scripts/supply-chain/mirror.manifest` | The four cluster-scoped charts and most of the 15 chart-carried images leave **if** #30 confirms they are provided. Prometheus / Alertmanager / Grafana images stay if we run our own instances. `../CHART_IMAGES.md` shrinks accordingly |
| `docs/CICD_DESIGN_NOTES.md` | `besu-infra` loses the EKS step; CD-23's Terraform container and CD-29's endpoint assertion stand; a CD-66 entry when the pipeline is touched |
| `CLAUDE.md` | §1 "Two EKS clusters", §2 layout, §4 phases, §6 isolation, §7 version policy, §9 teardown, §11 — all to be rewritten **after** §12.11 is answered. Banner in place meanwhile |

### 12.7 What the design gets to delete

- **The CIDR negotiation** — CD-42..CD-45, `CIDR_ALLOCATION_REVIEW.md`, Appendix A of the
  requirements document, D-7, D-8, D-12. We occupy their subnets; our IP demand is
  ~25–30 pod addresses plus NLB ENIs, which is a sizing note, not a request.
- **PrivateLink between the clusters** (D-1), the consumer endpoint, and **Stage 3.0**.
- **The EKS version ladder and its cost line** (§7 of the brief) — the version is theirs;
  what remains is a compatibility gate (#36).
- **Four `helm_release`s and their OCI conversion work** (D-22 still applies to whatever
  charts remain — at minimum our own six).
- **B13 mostly evaporates** — the 15 chart-carried images belong to charts we no longer
  install, if #30 confirms the cloud team provides them.
- **Requirements #4, #7, #9, #10, #11 (re-scoped into #28), #12, #15, #16, #17** — withdrawn
  in `NETWORK_REQUIREMENTS_CLOUD_TEAM.md` §9.2.

### 12.8 The mimic — `mimic_eks`, and one fidelity change to `mimic_vpc`

**`mimic_eks` — a third mimic project, sibling of the other two.** Not folded into
`mimic_vpc`, for the reason `mimic_egress` was not: different lifetime and cost. The VPC
mimic is free and stays up for weeks; a cluster bills $0.10/h plus nodes and comes up
per deploy-test. It is built from the **moved** `modules/eks` — so nothing is rewritten —
plus what the cloud team says they run: the add-on set from #30, a node group in the
"application" subnets (and a tainted ledger node group in ledger subnets if #28 is
granted, so both answers can be rehearsed), two namespaces with a `ResourceQuota`,
`LimitRange` and PSA labels, and a **namespace-scoped access entry** for the runner
role. It emits `eks-handover.auto.tfvars` (§12.5).

**The fidelity rule that matters:** the access entry the mimic gives our runner must
be the one the bank would give — `AmazonEKSEditPolicy` scoped to our namespaces, or a
custom `Role`, never cluster-admin. Then any cluster-scoped thing `sbsa_besu` attempts
**fails in the mimic exactly as it would in the bank**. That is the structural guard
against dilution, in the same spirit as the IAM deny on `ec2:CreateVpc` (§1 of the
RUNBOOK): the mimic's job is to make the platform unable to tell it from production.

**`mimic_vpc` — the NACL baseline flips from permissive to restrictive.** §3.5 of its
brief ships allow-all NACLs "because Phase 2/3 owns the rules". Under CT-1a the cloud
team owns the rules and ours is to conform, so an allow-all mimic hides precisely the
failure class they just described. The mimic must carry a plausible **deny-by-default**
ruleset that permits F-1..F-9 and nothing else — and `verify-subnet-rules.sh` must be
tested against a deliberately *broken* copy of it first (the B12 lesson; a check only
ever seen passing is not known to work). Its 15-subnet layout is kept: it already
models role-separated subnets, which is what the cloud team described.

### 12.9 Cost

| | Before (own clusters) | After (namespace tenant) |
|---|---|---|
| Production steady state | ~$1,140–1,596/mo chain-only (RUNBOOK §4) | **EKS control plane and node lines leave our bill** — whether the cloud team charges back for the node group is Q-9. What remains: KMS, Secrets Manager, NLBs, the runner (stopped between deployments), CloudWatch, S3 |
| Deploy-test | ~$2.40/h two clusters | **Unchanged in kind** — the mimic still bills a cluster and nodes. Slightly lower: one cluster, not two |
| Interface endpoints | ~$0.45/h in `shared` | **Zero** — theirs, and already there for their cluster (CD-39). Q-2's ~$400/mo question is answered by CT-5 |

### 12.10 Decisions

| ID | Decision | Status |
|---|---|---|
| **D-23** | **The cluster is consumed, not created.** `modules/eks` leaves the platform. Prime directive 1 of the brief extends to *EKS resources and every cluster-scoped Kubernetes kind* — if a plan or a chart would create one, it is a bug. A new `modules/cluster-contract` asserts the cluster the way `network-contract` asserts the VPC. | DECIDED 2026-09-21 |
| **D-24** | **Cluster-scoped add-ons are the cloud team's to provide; the platform asserts and never installs.** The four in §12.2 each carry a hand-over boolean, an assertion on the CRD, and a named namespaced fallback. The load-balancer controller has no fallback and is therefore a hard requirement (#30). | DECIDED |
| **D-25** | **The cluster arrives as `eks-handover.auto.tfvars`** — plain values, symlinked into each root, never `terraform_remote_state`. Third application of the rule (network, egress, cluster). | DECIDED |
| **D-26** | **Ask for a dedicated, tainted ledger node group in dedicated ledger subnets** (#28) — the multi-tenant-standard form of §6's node isolation, in the cloud team's own vocabulary. If refused: `NetworkPolicy` default-deny (D-9) is the compensating control and the posture regression is recorded in writing, not absorbed. | PROPOSED — needs the human's sign-off before sending |
| **D-27** | **Node maintenance needs a written operational contract, not a configuration** (#29): PDBs respected, never forced, one node at a time, notice and a window, Kubernetes-upgrade cadence shared in advance. On our side, validator anti-affinity by hostname becomes `required`. The failure this prevents is a chain halt (H1), and it is named as such in the ask. | DECIDED (the ask); its terms are the cloud team's to accept |
| **D-28** | **One cluster, two namespaces** (ledger, app) requested (#27). PrivateLink between clusters (D-1), the dedicated chain cluster (D-4), the `app` root's consumer endpoint and the Stage 3.0 gate are deleted; ledger ↔ application isolation is namespaces + `NetworkPolicy`. | DECIDED — supersedes D-1, D-4 |
| **D-29** | **The subnet security rules are a gate.** The flow table (§12.4) is requirement #34, asserted by a read-only preflight against the live NACLs and security groups, citing the flow number on failure. The mimic ships restrictive rules so the check is exercised. | DECIDED |
| **D-30** | **The network hand-over shrinks** (§12.5); `network-contract` loses gates 2, 3, 5, 6; the CIDR ask (CD-42..45, D-7, D-8, D-12) and Appendix A are withdrawn. | DECIDED — supersedes D-7, D-8, D-10 (partly: re-scoped into D-26), D-12 |
| **D-31** | **Blockscout's Postgres placement follows their data-subnet policy** (#37): in-cluster if permitted, RDS in a data subnet if not. Explorer-only; the lowest-stakes item here. | DECIDED (conditional) |
| **D-32** | **`mimic_eks` is a third mimic project** (§12.8), built from the moved `modules/eks`, giving the runner only the namespace-scoped access the bank would. **`mimic_vpc` NACLs become restrictive.** | DECIDED |
| **D-33** | **Pod Security Admission is a gate.** The F32 root init container is incompatible with `restricted`; before any apply the namespace's PSA level is known (#27) and the chart either conditions on it or the fix is redone without root. | DECIDED |
| **D-34** | **The runner stays** (CD-53 unchanged) and is more important, not less: it is the only host that can ask the Kubernetes-side questions in `cluster-contract`. Its cluster access is an access entry the cloud team creates, scoped to our namespaces (#32); `runner_scope = "in-cluster"` (CD-54) is the mode. | DECIDED |

### 12.11 Open questions — and where each is asked

| # | Question | Impact | Asked as |
|---|---|---|---|
| Q-8 | Does the **application estate** also land in this shared cluster, or only the ledger? | Decides whether `app` is a namespace or nothing; whether two namespaces are needed at all | #27 |
| Q-9 | Is the node group **charged back** to consuming teams? | Cost model only | §9.4 of the requirements addendum |
| Q-10 | **IRSA or Pod Identity?** | Which trust our IAM roles carry; whether `eks-auth` (excluded by D-14) is now needed — it is *their* endpoint either way | #31 |
| Q-11 | **NACLs, security groups, or both** on the role subnets? | Whether F-3 and the "+ return" rows are real | #34 |
| Q-12 | Will they **add a node-SG rule for our NLB**, or is **Security Groups for Pods** enabled? | F-2 is impossible without one of the two | #33 |
| Q-13 | **PSA level** on our namespaces | D-33 | #27 |
| Q-14 | Which of the **four add-ons** exist, at which versions | D-24 | #30 |
| Q-15 | **Node-rotation policy** — do they ever force past a PDB | D-27 | #29 |

All of these are answered by the three command outputs in §9.4 of the requirements
addendum, plus the questions listed there in words. **Ask for observable strings** (the
CD-31 → R-1 lesson); "does your cluster have the load-balancer controller?" produced
ambiguous answers elsewhere, `kubectl get crd targetgroupbindings.elbv2.k8s.aws` cannot.

### 12.12 Supersessions, effective 2026-09-21 (pending written confirmation)

- **D-1** (PrivateLink retained between the clusters) → deleted with the second cluster (D-28).
- **D-4** (dedicated EKS cluster for the chain) → superseded by D-23/D-28. The isolation
  it bought is re-requested as a node group (D-26).
- **D-7, D-8, D-12** (CIDR ask, pod-subnet parameterisation, secondary CIDR) → withdrawn (D-30).
- **D-10** (dedicated ledger subnets / route tables / NACL rules / flow logs by ask) →
  re-scoped into D-26; if #28 is granted most of it returns in their hands, not ours.
- **D-11, D-14** (we own the eight critical endpoints; the 16 → 14 trim) → moot. CD-39
  already made central endpoints the production setting; CT-5 removes the last reason to
  create any.
- **CD-42..CD-45** (the `/20` per environment, same size for all three) → withdrawn.
- **Requirements #4, #7, #9, #10, #11, #12, #15, #16, #17** → withdrawn or re-scoped in
  `NETWORK_REQUIREMENTS_CLOUD_TEAM.md` §9.2.
- **`CLAUDE.md` §1 "Two EKS clusters"**, §4 Stage 3.0, §6 (node group + per-tier SGs),
  §7 (EKS version ladder), §11 Q-2 / Q-2a → to be rewritten once §12.11 is answered.
- **`CICD_DESIGN_NOTES.md` §0.3** — `besu-infra` no longer deploys a cluster; the three-
  project shape, the Tentacle path and the validator gate are unchanged.

**Not superseded, worth saying:** CT-2 (air-gap), CT-3a (ECR mirror), D-3, D-9 (now
load-bearing), D-16..D-22, the whole of CD-55..CD-65, C6, C10, C12, H1, F19/F20/F32.

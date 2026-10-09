# CIDR allocations — request

> **⚠️ WITHDRAWN 2026-09-21 — DO NOT SEND (CT-5, D-30).** The cloud team provides a shared
> EKS cluster and a namespace, and their VPC already has role-separated subnets. We no
> longer request or lay out address space: our ask is a `ResourceQuota`, not a CIDR
> (`CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md` §1). CD-42..CD-45 are withdrawn with it.
>
> **Kept as the single surviving record of the sizing analysis** — the arithmetic here is
> still correct and still the best explanation of why EKS consumes addresses faster than
> pod count suggests. `CLOUD_TEAM_REDESIGN_NOTES.md` §5 and
> `NETWORK_REQUIREMENTS_CLOUD_TEAM.md` Appendix A are the other two copies, both also
> withdrawn.


**Date:** 2026-09-09 · **From:** Ledger Platform Team · **Region:** af-south-1

**What we are asking for: a `/20` (4,096 addresses) per environment — SIT, UAT and PROD.**

**Allocations offered, and what they are short by:**

| Environment | Offered | Addresses | Against a /20 |
|---|---|---|---|
| SIT | `10.103.53.0/24` | 256 | **1/16th** |
| UAT | `10.103.0.0/21` | 2,048 | 1/2 |
| PROD | `10.108.13.0/24` | 256 | **1/16th** |

We can build on less — §4 sets out exactly how much less, and what each reduction costs. But
a /20 per environment is the size this platform was designed against, and it is the only one
that needs no compensating complexity.

---

## 1. Where the number comes from

It is not a round number picked for comfort. Our network specification lays out **15 subnets**
across 3 availability zones, and they allocate **2,880 addresses**:

| Role | Subnets | Size | Usable each | Total usable | What lives there |
|---|---|---|---|---|---|
| ledger | 3 | /24 | 251 | 753 | Besu validator, bootnode and RPC nodes, and their pods |
| app | 3 | /23 | 507 | 1,521 | Application cluster nodes and pods |
| lb | 3 | /26 | 59 | 177 | Internal load balancers |
| endpoint | 3 | /26 | 59 | 177 | Interface VPC endpoint ENIs |
| data | 3 | /26 | 59 | 177 | Managed databases and caches |
| **Total** | **15** | | | **2,805** | |

**2,880 allocated inside a /20's 4,096 leaves 1,216 addresses — a 30% reserve.**

**The reserve is the part we are actually asking for**, and it is worth being explicit about
why. A VPC's primary CIDR **cannot be changed after the VPC is created**. Neither can the EKS
service CIDR after the cluster is created. So an allocation sized to today's exact footprint
has no answer to any of the following, all of which are ordinary events over a ledger's life:

- adding validators beyond the initial four,
- scaling the RPC pool for SWIFT traffic,
- a second node group during a Kubernetes version upgrade — the standard safe procedure runs
  old and new nodes side by side, which **doubles node address consumption for the duration**,
- the application layer growing beyond its first deployment.

A 30% reserve is not generous by enterprise standards. It is the difference between absorbing
those events and rebuilding the VPC.

---

## 2. Why the offered /24s do not work, in one paragraph

With the AWS VPC CNI — the default and the one EKS ships with — **every pod receives a real
VPC IP address**. Nodes do not request them one at a time; the CNI attaches a whole ENI's
worth in advance so that pods can start without waiting on an EC2 API call. On the instance
type we use, **a single idle node holds around 30 addresses, and up to about 50 under load**.
The ledger cluster alone runs 60–100 pods across several nodes. **A /24's 256 addresses are
exhausted before the cluster finishes starting**, and the failure is not a clean "out of
addresses" — it is pods stuck in `ContainerCreating` with an IP-allocation error, on a cluster
that looks healthy from every other angle.

There is a way to run on a /24. It is in Appendix A. We are not proposing it, and §3 explains
why.

---

## 3. What a /20 makes unnecessary

This is the strongest argument for the ask, so we want it stated plainly rather than buried:
**a /20 removes three separate pieces of complexity, each of which is otherwise a permanent
feature of the platform.**

| On a /20 | On a /24 |
|---|---|
| Default EKS networking | **VPC CNI custom networking** — pods moved onto a secondary CIDR, with a per-AZ `ENIConfig` custom resource that must be maintained and that fails in confusing ways when it drifts |
| Nothing further needed from you | **A second CIDR negotiation** — a `100.64.0.0/10` block per environment, plus confirmation it collides with nothing in the routed estate |
| The published subnet plan applies as written | **The subnet plan is re-derived from scratch**, and re-derived differently per environment |
| Our pre-production VPC is a faithful rehearsal | **It is not.** Ours is built for a /20; if production runs a different networking model, a successful rehearsal proves the platform *works*, not that it *fits* |

Every one of those is survivable. Together they are a standing tax on a system that is meant
to run for years with a small team, and they buy nothing except address space that — at /20
per environment — is not a large ask against a `10.0.0.0/8` plan.

---

## 4. If a /20 is not available everywhere

We would rather tell you our fallback ladder up front than have the conversation stall on
all-or-nothing. Each row is what we would actually do at that size:

| Size | Addresses | Verdict | What it costs |
|---|---|---|---|
| **/20** | 4,096 | **Requested.** Plan applies as published, 30% reserve | Nothing |
| **/21** | 2,048 | **Acceptable floor.** Plan re-derived: ledger stays 3 × /24, app drops to 3 × /25, the small subnets to /27. Uses 1,440, leaves 608 | Application-cluster headroom, and a tighter node-group upgrade path |
| **/22** | 1,024 | **Degraded.** Ledger subnets drop to /25 — about 2 nodes per AZ before tuning | We must tune the CNI to be frugal (`WARM_IP_TARGET`), which slows pod starts and risks EC2 API throttling during scale-up |
| **/24** | 256 | **Only with custom networking** — Appendix A | All four rows of §3 |

**UAT's /21 is already at the acceptable floor.** So the substance of this request is **SIT
and PROD**, which are currently at a sixteenth of the design size.

### 4a. Please make all three the same size

Whatever size is agreed, **we would like it applied uniformly.** SIT and UAT exist to
de-risk PROD, and they only do that if they are the same shape. If PROD ran default
networking on a /20 while SIT ran custom networking on a /24, a green SIT deployment would
tell us very little about PROD — and the differences would surface during the production
deployment, which is precisely the moment we build lower environments to avoid.

If space is genuinely constrained and only one environment can be enlarged, **it must be
PROD** — but we would then be explicit with you that SIT and UAT have stopped being faithful
rehearsals, and that some classes of failure will first be seen in production.

---

## 5. PROD is currently one eighth of UAT

| Environment | Addresses |
|---|---|
| SIT | 256 |
| **UAT** | **2,048** |
| PROD | 256 |

We assume this is not intended. PROD runs the most nodes, the most load balancers, and is the
only one of the three with a growth path.

If the /21 for UAT is instead a **shared block** that our slice will be carved from, please
tell us the actual sub-range — a /21 we do not wholly own tells us nothing we can size
against.

---

## 6. Two smaller confirmations

1. **Is each environment a separate VPC?** The three allocations suggest so, and it is what
   we have assumed. If SIT and UAT share a VPC, several things change.
2. **Is `172.20.0.0/16` free for the EKS service CIDR** in all three? It is cluster-internal
   and never routed, so it only has to avoid colliding with anything reachable over the
   Transit Gateway — but it is **immutable after cluster creation**, so it is worth thirty
   seconds now.

---

## 7. Summary

| # | Ask |
|---|---|
| **1** | **A `/20` per environment — SIT, UAT and PROD.** 2,880 allocated, 1,216 reserve |
| **2** | If not /20, then **the same size for all three**, and **`/21` is our floor** |
| **3** | **PROD must not be smaller than UAT.** It is currently one eighth |
| **4** | Confirm each environment is a separate VPC |
| **5** | Confirm `172.20.0.0/16` is free for the EKS service CIDR |

**None of this can be changed after the VPCs are created**, which is the only reason we are
pressing on it now rather than accepting what was offered and discovering the limit later.

---

## Appendix A — how we would run on a /24, if we had to

Recorded so the option is documented rather than rediscovered, and so §3's cost is not taken
on trust.

**VPC CNI custom networking.** A secondary CIDR is associated with the VPC from
**`100.64.0.0/10`** and pods are placed on it. That range is reserved by RFC 6598 for
carrier-grade NAT, so it is **not** part of the RFC 1918 space enterprises allocate from — it
costs nothing from the bank's address plan. Pod addresses do not need to be routable: pods
reach the outside through the node, and nothing outside the VPC addresses a pod directly.

The routable /24 would then carry:

| | Addresses |
|---|---|
| AWS reserves 5 per subnet × 9 subnets | 45 |
| Node primary IPs (~9 nodes across two clusters) | 9 |
| Internal NLB / ALB ENIs | 15 |
| Data subnets and spare | 10 |
| **Subtotal** | **79 of 256** |
| Interface endpoint ENIs, **if they sit inside our allocation** | +45 |
| **Total in that case** | **124 of 256** |

That last row is why we would need one more answer before committing to this path: **are the
15 interface endpoints' ENIs inside our allocation, or in shared endpoint subnets you operate
centrally?** Fifteen endpoints × 3 AZs = 45 addresses, and because all 15 ENIs in a zone must
sit in that zone's endpoint subnet, **that subnet cannot be smaller than a /27** — a /28's 11
usable addresses cannot hold 15 ENIs.

**One thing we would not do even here: prefix delegation.** It is the usual advice for pod
density, but it allocates addresses in **/28 blocks per ENI**, which makes consumption worse
on a small allocation, not better. It is the right tool for large subnets and the wrong one
for this problem.

# Network Requirements — Besu Ledger Platform on the Shared VPC

**To:** Cloud Platform Team
**From:** Ledger Platform Engineering
**Date:** 2026-08-29
**Status:** Request for provisioning parameters — response needed before VPC creation
**2026-09-21:** shared EKS cluster, namespace tenancy (#27–#39) — it withdraws nine of the requirements below and re-scopes two.
**2026-10-09:** **that addendum (formerly §9) now lives in [`CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md`](CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md)** — the document we send, which also restates every requirement below that is still live. Its sections keep the old numbering: former SCR.N is its §N, and #27–#39 are defined there. **Where the two differ, that document governs.** Below, "SCR" means that document.

---

## 1. Purpose

We are building a permissioned Hyperledger Besu (QBFT) ledger platform whose only
external consumer is **SWIFT**, reaching a JSON-RPC endpoint over SWIFT's private
MV-SIPN network. We have adopted your four architectural constraints in full:

1. a single shared VPC for the ledger and the application estate
2. private subnets only — no public subnets, no Internet Gateway
3. all container images sourced from a private registry — settled as **Amazon ECR** (§8)
4. a VPC CIDR smaller than /16

This document lists the **provisioning parameters we need you to set**, and the
**permissions we need within the VPC**. It exists because a number of these
settings are **immutable after VPC or cluster creation** — getting them wrong
means rebuilding, not reconfiguring.

Every requirement below states what breaks without it. The majority cost nothing
to provide.

### What we are deploying into the VPC

| | |
|---|---|
| Region | **`af-south-1` (Africa, Cape Town)** — CONFIRMED 2026-08-29 |
| Availability Zones | 3 |
| EKS clusters | ~~**2** — one for the ledger, one for the application estate~~ **2026-09-21: none — we are a namespace tenant of your shared cluster (SCR)** |
| Worker nodes at peak | ~~~26 (~6 ledger, ~20 applications)~~ **2026-09-21: your nodes; ~20 pods, ~6 vCPU / 20 GiB requested, 8 × 20 GiB volumes — SCR §3 #27** |
| Internet egress required | **None.** The ledger is a closed network. |

---

## 2. Summary checklist

| # | Requirement | Tier | Cost to provide |
|---|---|---|---|
| 1 | VPC `instance_tenancy = default` | 1 | none |
| 2 | `enableDnsSupport` **and** `enableDnsHostnames` = true | 1 | none |
| 3 | DHCP option set resolves AWS endpoint **Private DNS** (see also #22) | 1 | none |
| ~~4~~ | ~~Subnet tag `kubernetes.io/role/internal-elb=1`; permission to tag~~ **WITHDRAWN (SCR)** | — | none |
| 5 | 3 AZs, identified by **AZ ID** ~~; both clusters and endpoints co-located~~ — under SCR the cluster is yours; we still need our pods spread across 3 AZs for QBFT | 1 | none |
| 6 | Permission to create and manage security groups | 1 | none |
| ~~7~~ | ~~Contiguous **/20**, carved from a reserved /18~~ **WITHDRAWN (SCR)** — a quota, not address space (SCR §1) | — | none |
| 8 | **WITHDRAWN under §8** (was: route and DNS to an external registry host) | — | none |
| ~~9~~ | ~~Confirm EKS service CIDR (`172.20.0.0/16`) does not collide~~ **WITHDRAWN (SCR)** — your cluster | — | none |
| ~~10~~ | ~~Permission to associate **gateway** endpoints to the route tables~~ **WITHDRAWN (SCR)** — yours; but **#20 stands** (the S3 policy must admit the ECR layer bucket) | — | none |
| ~~11~~ | ~~Dedicated subnets for the ledger~~ **RE-SCOPED (SCR) → #28** (a dedicated node group) | 2 | none |
| ~~12~~ | ~~Dedicated route tables for the ledger subnets~~ **WITHDRAWN (SCR)** — folded into #28 | — | none |
| ~~13~~ | ~~Permission to manage NACL rules on the ledger subnets~~ **WITHDRAWN 2026-09-09** — security groups instead; SCR #34 verifies your rules | — | none |
| ~~14~~ | ~~Subnet-level VPC Flow Logs on ledger subnets~~ **WITHDRAWN 2026-09-09** — ENI-level instead | — | none |
| ~~15~~ | ~~Permission to create interface endpoints~~ **WITHDRAWN (SCR)** — yours; but **#22/#23 stand** as checks | — | none |
| ~~16~~ | ~~Dedicated endpoint subnets, separate from load-balancer subnets~~ **WITHDRAWN (SCR)** — the PrivateLink path it protected is gone | — | none |
| ~~17~~ | ~~Associate `100.64.0.0/16` as a secondary CIDR~~ **WITHDRAWN (SCR)** — your CNI configuration | — | none |
| ~~18~~ | ~~Private ECR registry **in-region**~~ **ANSWERED** — exists, af-south-1, your shared-services account (#25, CD-27/CD-28) | — | ~$1–2/mo |
| 19 | ~~Written exception for AWS-owned EKS addon images~~ — **WITHDRAWN under §8** | 3 | none |
| 20 | S3 gateway endpoint policy must allow `prod-<region>-starport-layer-bucket/*` | 1 | none |
| ~~21~~ | ~~S3 gateway endpoint policy must allow the AL2023 repo bucket~~ **NO LONGER NEEDED** — the instance ships static binaries, no package manager | — | none |
| 22 | **Private DNS enabled** on the `ecr.api` and `ecr.dkr` interface endpoints | 1 | none |
| 23 | ECR endpoint policy **not** scoped to a single AWS account | 1 | none |
| 24 | Confirm the VPC is **not RAM-shared** — **answered (assumed) 2026-09-09, defused by SCR; still open as R-3** for what we create *beside* the cluster | 1 | none |
| 25 | ECR account topology — **answered: central shared services, af-south-1.** The pull grant **re-scopes to #38** (your node role, not ours) | 1 | none |
| ~~26~~ | ~~An approved **build-and-push path outside the VPC**~~ **WITHDRAWN 2026-09-09** — your CI runners have egress | — | none |
| **27–39** | **Shared EKS cluster, namespace tenancy — see SCR (2026-09-21).** Withdraws #4, #7, #9, #10, #12, #15, #16, #17; re-scopes #11 → #28 and #25 → #38; **#39** is the surviving half of #7 (IP headroom) | see SCR | none |

---

## 3. Tier 1 — required for the platform to function

Each failure mode below is **slow and ambiguous to diagnose** rather than a clean
error: with no Internet Gateway, misrouted calls hang until timeout instead of
being refused.

### 1. VPC `instance_tenancy` must be `default`

If the VPC is created with `instance_tenancy = dedicated`, **every** instance
launched into it is forced to dedicated tenancy regardless of our launch template,
and **this cannot be reverted on an existing VPC**.

**Impact if not met:** ~USD 1,460/month in per-region dedicated fees plus ~10% on
every instance rate. EKS managed node groups do not support dedicated *host*
placement at all, so we would additionally be forced onto self-managed node
groups and lose EKS-managed AMI patching.

### 2. `enableDnsSupport` = true **and** `enableDnsHostnames` = true

AWS interface endpoints work by overriding the public service hostname (e.g.
`secretsmanager.af-south-1.amazonaws.com`) with the endpoint's private IP, via
Private DNS. Private DNS requires **both** attributes to be enabled.

**Impact if not met:** every AWS SDK call from either cluster resolves to a public
IP address that has no route out of the VPC. This breaks node bootstrap, IRSA role
assumption, KMS decryption of validator signing keys, secret retrieval, and log
shipping — all as hangs rather than errors.

### 3. DHCP option set must resolve AWS endpoint Private DNS

If the DHCP option set points only at on-premises DNS servers, endpoint Private
DNS stops resolving unless those servers forward appropriately to the Amazon
resolver at the VPC base + 2 address.

This now carries the entire container supply chain as well as the AWS APIs — see
**#22**, which states the ECR-specific form of the same requirement.

**Impact if not met:** identical symptoms to #2, from a different cause. This is
the most common failure mode in air-gapped enterprise VPCs.

### 4. ~~Subnet tag `kubernetes.io/role/internal-elb=1`, plus permission to tag~~ — **WITHDRAWN under the shared cluster (SCR)**

Withdrawn 2026-09-21: we are a namespace tenant of your shared EKS cluster, not the
builder of a cluster and 15 subnets. We bind our pods into NLB target groups we create ourselves (`TargetGroupBinding`), so the AWS Load Balancer Controller never creates a load balancer and never discovers a subnet. Nothing depends on the tag any more. *(Note: `modules/network-contract` still asserts it today — that assertion becomes conditional when the code is updated, which is why the requirement is withdrawn here rather than deleted.)*

The AWS Load Balancer Controller discovers eligible subnets **by tag**. This tag is
required on the load-balancer subnets.

**Impact if not met:** the controller cannot place the internal Network Load
Balancers that carry SWIFT mTLS traffic. The failure surfaces at Kubernetes
Service-creation time, not at infrastructure provisioning time, so it passes every
plan review and appears late.

If a tag policy or landing-zone guardrail would strip or block these tags, we need
to know now.

### 5. Three AZs, identified by AZ ID, with all components co-located

Please specify subnets by **AZ ID** (`afs1-az1`, `afs1-az2`, `afs1-az3`), not by AZ
name. AZ *names* map to different physical zones in different accounts.

Both EKS clusters and all VPC endpoints must be present in the **same three** AZs.

**Impact if not met:** PrivateLink endpoint services are only reachable from AZs
in which the service is present, so a mismatch silently breaks application-to-ledger
connectivity; mismatches also generate avoidable cross-AZ data transfer charges.
Three AZs are required for QBFT validator topology spread (4 validators, tolerating
one AZ loss).

### 6. Permission to create and manage security groups

**Impact if not met:** we cannot express the per-tier isolation model (validators,
SWIFT RPC pool, application RPC pool, explorer, application workloads) if every SG
change must route through an external change queue. Security group changes are a
routine part of ledger operations, not a one-time provisioning step.

### 7. ~~Contiguous /20, carved from a reserved /18~~ — **WITHDRAWN under the shared cluster (SCR)**

Withdrawn 2026-09-21: we are a namespace tenant of your shared EKS cluster, not the
builder of a cluster and 15 subnets. We no longer lay out subnets, so there is no address space for us to size. Our footprint is ~20 pods, 6 load-balancer interfaces and 1 In-VPC EC2 Runner, taken from **your** subnets — stated as a quota in SCR §1 and as a headroom question in SCR §3 **#39**. Appendix A is withdrawn with this, and so is the 2026-09-09 CIDR allocation review.

Full sizing calculation is in **Appendix A**. Summary: peak demand is ~1,455
addresses; a /20 provides 2,805 usable across the proposed subnet plan (~1.9x
headroom), while a /21 provides 1,521 — effectively zero headroom.

We ask that the /20 be allocated from a **reserved /18** in your IPAM so that future
growth never requires re-addressing a live payment system.

### 8. ~~Route and DNS resolution to an external registry host~~ — **WITHDRAWN**

Withdrawn 2026-09-04. The registry is **Amazon ECR** (§8), reached through the
`ecr.api` / `ecr.dkr` interface endpoints and the `s3` gateway endpoint — all of which
we already required. There is no external registry host to route to, no hostname for
your DNS to resolve, and no private CA certificate to distribute to our nodes.

This removes what would have been the longest-lead item in this document for your team.

**Replaced by** #20, #22 and #23, which are endpoint-policy and DNS settings rather
than network plumbing.

### 9. ~~Confirm the EKS service CIDR does not collide~~ — **WITHDRAWN under the shared cluster (SCR)**

Withdrawn 2026-09-21: we are a namespace tenant of your shared EKS cluster, not the
builder of a cluster and 15 subnets. Your cluster, your service CIDR. We ask only for the cluster's version and endpoint configuration (#32).

EKS assigns Kubernetes Service IPs from a CIDR that is **not** part of the VPC —
default `172.20.0.0/16`. It must not overlap with anything reachable over the
Transit Gateway.

**Impact if not met:** this value is **immutable after cluster creation**. A
collision discovered later requires rebuilding the cluster.

---

### 10. ~~Permission to associate gateway endpoints to the route tables~~ — **WITHDRAWN under the shared cluster (SCR)**

Withdrawn 2026-09-21: we are a namespace tenant of your shared EKS cluster, not the
builder of a cluster and 15 subnets. Your cluster's nodes already need S3 for image layers, so the endpoint exists and is associated. We create nothing and verify instead — **#20 still stands**, because the S3 endpoint *policy* must admit the ECR layer bucket or every image pull stalls part-way through.

Creating an S3 or DynamoDB **gateway** endpoint adds a prefix-list route to every
route table it is associated with. Because the route tables are yours (#12), we need
either permission to perform that association, or for you to create these two
endpoints and associate them to the ledger, application, load-balancer and endpoint
route tables.

**Impact if not met:** provisioning fails with an authorization error on the S3
endpoint. S3 is not optional — it carries **container image layer retrieval** for
every image pull, plus Terraform state. Nothing in either cluster starts without it.

Both endpoints are **free of charge**.

## 4. Tier 2 — required for the security and resilience posture

Consolidating the ledger and the application estate into one VPC removes the
VPC-level boundary that previously separated them. **We are not asking to reverse
that decision.** The requirements in this section rebuild the equivalent boundary
inside the shared VPC, at no additional address cost.

### 11. ~~Dedicated subnets for the ledger, separate from application subnets~~ — **RE-SCOPED under the shared cluster (SCR) into #28** (2026-09-21)

A tenant does not place its own subnets. The intent — validators not sharing infrastructure with application workloads — is now asked for as a **dedicated, tainted node group**, in dedicated ledger subnets if you can provide them. If that is refused, `NetworkPolicy` default-deny is the compensating control and we record the posture change.

The ledger's IP pool must not be consumable by application workloads.

**Impact if not met:** a single application autoscaler exhausting a shared subnet
means validator pods cannot be scheduled. With fewer than 3 of 4 validators
available, QBFT loses quorum and the ledger stops producing blocks — a payment-system
availability incident caused by an unrelated workload. Subnet-level separation makes
this structurally impossible rather than a matter of operational discipline.

This costs no additional address space: it is the same /20, divided differently.

### 12. ~~Dedicated route tables for the ledger subnets~~ — **WITHDRAWN under the shared cluster (SCR)**

Withdrawn 2026-09-21: we are a namespace tenant of your shared EKS cluster, not the
builder of a cluster and 15 subnets. Route tables are not a tenant's to own. The isolation this asked for is now part of #28 (a dedicated ledger node group, in dedicated subnets if you can) — and if you grant it, the route tables come with it, on your side.

**Impact if not met:** a routing change made on behalf of an application can alter
the ledger's reachability. The ledger subnets must never acquire a default route.

### 13. ~~Permission to manage NACL rules on the ledger subnets~~ — **WITHDRAWN 2026-09-09**

You told us we are a tenant in your account, and NACLs are not a tenant's to manage. We fall back to security groups, which cover the same ground with nothing needed from you. Under SCR (#34) what replaces this is a *verification*: we check that your subnet rules permit the nine flows our design needs, and cite the flow number if one is blocked.

**Rationale:** a NACL provides a **stateless L3 boundary that does not depend on
security-group correctness** — defence in depth for a system carrying SWIFT traffic,
and a control we expect to be asked about during audit. This is the closest
equivalent to the VPC boundary that consolidation removed.

We are asking to manage the **rules** on ledger subnets only; the NACLs themselves
can remain your resources.

### 14. ~~Subnet-level VPC Flow Logs on the ledger subnets, delivered to our destination~~ — **WITHDRAWN 2026-09-09**

Same reason as #13 — not a tenant's to configure. We self-serve at **ENI level** on the interfaces we own, needing nothing from you. If #28 grants a dedicated ledger node group in dedicated subnets, subnet-level logs become available again *on your side*, which would be a bonus rather than a request.

Either grant us permission to create subnet-level flow logs on the ledger subnets,
or deliver a copy of the relevant records to our log destination.

**Impact if not met:** network forensics on the ledger is a compliance artifact. If
flow logs exist only under another team's ownership, we cannot answer "which hosts
connected to the validators, and when" during a security investigation.

### 15. ~~Permission to create interface VPC endpoints~~ — **WITHDRAWN under the shared cluster (SCR)**

Withdrawn 2026-09-21: we are a namespace tenant of your shared EKS cluster, not the
builder of a cluster and 15 subnets. All 15 services are ones your cluster's tenants already need, so the endpoints exist and are yours. We create none and verify them read-only from inside the VPC. **#22 and #23 still stand** — they are checks on endpoints you already have, not requests to change them.

At minimum, for these services:
`kms`, `secretsmanager`, `sts`, `ecr.api`, `ecr.dkr`, `ssm`, `ssmmessages`, `ec2messages`

**Impact if not met:**
- **`kms` is on the critical path for validator startup.** Node signing keys are
  encrypted under a customer-managed CMK and decrypted at pod start. If that endpoint
  is centrally owned, a change in another team's queue can prevent the ledger from
  starting, and we cannot repair it during an incident.
- **`ssm`, `ssmmessages`, `ec2messages`** are the only access path to the deployment
  runner. Without them there is no way to reach it at all — no SSH, no public IP, by
  design.

If you operate **centralised endpoints** in a shared-services VPC, we would prefer to
consume those for the non-critical services. Please see Q-2.

### 16. ~~Dedicated endpoint subnets, separate from load-balancer subnets~~ — **WITHDRAWN under the shared cluster (SCR)**

Withdrawn 2026-09-21: we are a namespace tenant of your shared EKS cluster, not the
builder of a cluster and 15 subnets. This existed to keep endpoint interfaces away from the NLB nodes on a PrivateLink path between our two clusters. There is one cluster now and that path is gone, so the constraint has no subject.

Endpoint network interfaces must not share a subnet with the Network Load Balancer
nodes they front.

**Impact if not met:** the application-to-ledger PrivateLink path becomes unreliable
in a same-VPC configuration.

---

## 5. Tier 3 — zero-cost options we ask you to take now

### 17. ~~Associate `100.64.0.0/16` as a secondary VPC CIDR~~ — **WITHDRAWN under the shared cluster (SCR)**

Withdrawn 2026-09-21: we are a namespace tenant of your shared EKS cluster, not the
builder of a cluster and 15 subnets. Secondary CIDRs and VPC CNI custom networking are your configuration. If address headroom is tight (**#39**), this remains a good remedy — but it is yours to choose, not ours to request.

**We are not asking to use this now.** We are asking for it to be associated at VPC
creation and held in reserve.

- `100.64.0.0/10` is carrier-grade NAT space (RFC 6598), **not RFC 1918** — it
  consumes none of your enterprise IPAM allocation
- it is never routed outside the VPC; pod traffic leaving the VPC is source-NATed to
  the node's own address, so no Transit Gateway or on-premises route is ever required
- AWS recommends precisely this range for EKS address expansion

**Why now rather than later:** associating the CIDR later is straightforward, but
*using* it requires enabling VPC CNI custom networking, which affects only newly
created network interfaces — meaning every node must be recycled. On a live ledger
that is a controlled maintenance window, replacing one validator at a time. Taking
the association now converts a future maintenance operation into a configuration
change.

If `100.64.0.0/10` is already in use on the bank network, `198.19.0.0/16` is an
equivalent alternative.

### 18. ~~Private ECR registry in-region~~ — **ANSWERED 2026-09-09**

> **Answered:** the registry is ECR in your central shared-services account, in
> **af-south-1** (#25, CD-27; the region was confirmed when R-4 closed, CD-28). It is
> already the **only** image source: the CI mirror (`.github/workflows/supply-chain.yml`)
> copies every third-party image and chart in from outside the VPC, and nothing inside
> the VPC pulls from anywhere else. What remains live sits elsewhere — the pull grant for
> your node role (**#38**) and who creates our repositories (CD-27, SCR §7). Tag immutability
> and no lifecycle expiry are already enforced registry-wide (R-5, closed). The text below
> is kept as the original record.

**Upgraded from a Tier-3 fallback to the platform's registry** (§8). Approximately 23
images plus the Helm charts, in the deployment region.

**Rationale — business continuity:** node replacement must not depend on any service
outside AWS. A registry that is unreachable means no new node can pull images, which
means we cannot replace a failed validator — a single point of failure outside the
platform's own availability envelope, on a payment system. Approximate cost:
USD 1–2/month.

### 19. ~~Written exception for AWS-owned EKS addon images~~ — **WITHDRAWN**

Withdrawn 2026-09-04. The EKS managed addons `vpc-cni`, `coredns` and `kube-proxy` pull
from AWS's own ECR registry, over the **same** `ecr.api` / `ecr.dkr` / `s3` endpoints as
every image we mirror. With ECR as the platform registry there is one path and no
exception, so "all images from ECR" holds as written and needs no carve-out.

The one thing this does require is **#23** — the ECR endpoint policy must not be scoped
to a single AWS account, because those addon pulls are cross-account by construction.

---

## 6. Confirmations we need from you

| # | Question | Why it matters |
|---|---|---|
| ~~Q-0~~ | **ANSWERED: `af-south-1` (Africa, Cape Town).** Remaining action: `af-south-1` is an **opt-in region** and must be enabled on the account before anything provisions. | Resolved 2026-08-29. |
| ~~Q-1~~ | **ANSWERED (assumed): provisioned in our own account, not RAM-shared.** Please confirm — if it is in fact RAM-shared, participant restrictions on creating a **VPC endpoint service** would force us to redesign the application-to-ledger path. | Resolved (assumption) 2026-08-29. |
| Q-2 | Do **centralised interface endpoints** exist in a shared-services VPC that we can consume via Route 53 private hosted zones? | Determines whether we create ~15 endpoints ourselves or route to yours. Material cost difference. |
| Q-3 | Is there **internet egress** via Transit Gateway and a proxy, or is the VPC fully air-gapped? | We are building for a full air-gap and will treat any egress as a bonus, but proxy configuration would need to be threaded through containerd, kubelet and the AWS SDKs. |
| Q-4 | **Superseded by Q-4a..Q-4e in §8.4** — ECR account topology, CVE gating before promotion, and ownership of the mirror pipeline. | Charts and providers are as load-bearing as images in an air-gapped build. |
| Q-5 | Is a **golden AMI** mandated for EC2 instances, and if so which OS family? | EKS-optimised AMIs are Amazon Linux 2023. A RHEL mandate means custom AMI construction and the loss of EKS-managed AMI patching. |
| Q-6 | Are **Transit Gateway** attachment charges and **IPAM** charges cross-charged to consuming teams? | Needed for our cost model; not a design constraint. |

---

## 7. Shared responsibility — proposed split

> **SUPERSEDED 2026-09-21 — read SCR §5 instead.** This table was written when we would
> build two EKS clusters and the endpoint layer. Under SCR the cloud team owns the
> cluster, the node groups, every addon, all the endpoints and the subnet rules, and we
> own what is inside our namespaces plus the AWS resources beside the cluster. The rows
> that inverted are struck below; SCR §5 is the current split. (#13 and #14 were already
> withdrawn on 2026-09-09.)

| Resource | Cloud Platform Team | Ledger Platform Team |
|---|---|---|
| VPC, CIDR associations | Create, own | Read only |
| Subnets | Create, own | Consume ~~; request tags (#4)~~ — #4 withdrawn |
| Route tables | Create, own ~~— dedicated per tier (#12)~~ | Read only |
| NACLs (ledger subnets) | Own the resource | **Manage rules** (#13) |
| Security groups | — | **Create and manage** (#6) |
| Interface VPC endpoints | **Own — all of them** (Q-2 answered by SCR) | ~~Create in endpoint subnets (#15)~~ → **verify only** |
| Gateway endpoints (S3, DynamoDB) | **Own** | ~~Create~~ → **verify only; #20 is the live ask** |
| Transit Gateway + attachments | Own | Consume |
| DNS / Route 53 Resolver rules | Own | Consume; require AWS endpoint Private DNS (#3, #22) |
| VPC Flow Logs | VPC-level | **Subnet-level on ledger subnets** (#14) |
| Container registry (ECR) | See #25 / §8.5 | See #25 / §8.5 |
| IPAM | Own | — |
| EKS clusters, node groups, launch templates | **OWN — this is the CT-5 change** | ~~Own~~ → consume a **namespace**; assert via preflight (#30, #32) |
| Internal load balancers | Provide the **AWS Load Balancer Controller** (#30); add the node-SG rule (#33) | Own the NLBs and target groups; bind pods with `TargetGroupBinding` |
| ~~PrivateLink endpoint service~~ | — | ~~Own~~ → **deleted; one cluster, so no cross-cluster path** |
| Kubernetes workloads, secrets, KMS keys | — | Own |
| Namespaces, quotas, Pod Security labels, cluster access entries | **Own** (#27, #32) | Request; verify |
| Node maintenance on validator nodes | **Own the tooling — honour #29** | Provide the health check; attend the window |

---

## 8. Addendum — the registry is Amazon ECR (2026-09-04)

> **⇢ For sending, use `CLOUD_TEAM_REQUEST_REGISTRY_AND_CICD.md` (2026-09-07) instead.**
> That document is self-contained, folds this addendum together with the CI/CD questions
> (CQ-1..CQ-8), and explains the failure mode of each ask. This section is kept as the
> in-place record so the numbered requirements #20–#26 stay resolvable from this file.

**Please read this alongside §§2–7. Where they differ, this section governs.**

Following your preference for **Amazon ECR**, we re-analysed the supply chain against
that model and are proceeding with it. Our conclusion: **ECR is a good fit and, on
balance, the better choice for this platform.** Nothing about the network design
changes — private subnets only, no Internet Gateway, no NAT.

This addendum states the model we will build, the requirements it places on the network
you own, and the requirements it lets us **withdraw**.

### 8.1 The model

Third-party artefacts (container images and Helm charts) are **built, packaged and
pushed to ECR from outside the VPC**. Workloads inside the VPC only ever **pull**, over
the `ecr.api` and `ecr.dkr` interface endpoints plus the `s3` gateway endpoint. No
component in the VPC ever contacts a public registry.

**One point we want to be explicit about, because it is easy to assume otherwise.**
ECR is a registry, not a proxy. Its proxy-equivalent feature — *pull-through cache* —
**cannot be used here**. AWS documents that the first pull through a pull-through cache
rule requires a route to the internet when ECR is reached via an interface endpoint,
which this VPC deliberately does not have.

So the supply chain is an **explicit replication pipeline**, not an on-demand cache.
Somebody owns that pipeline for the life of the platform. We are content to own it, and
we think it is the better posture for a payment system — every third-party artefact
crosses the boundary through a deliberate, logged, scannable promotion step rather than
being fetched on demand from the internet. But it is a standing commitment rather than a
one-off configuration, and we would rather agree it now than discover it later.

### 8.2 What this lets us withdraw

| Withdrawn | Was |
|---|---|
| **#8** — route and DNS resolution to an external registry host | No longer applicable. ECR is an AWS service reached through endpoints we already need. This removes what would have been, for you, the longest-lead item. |
| **#19** — a written exception for AWS-owned EKS addon images | No longer needed. With ECR there is one registry and no carve-out: the addon images and our mirrored images arrive by the same path. "All images from ECR" holds without exception. |
| A registry **CA certificate** and its distribution into every node's trust store | ECR presents a publicly trusted certificate. Nothing to distribute, nothing to rotate. |
| A registry **service account / pull credentials** and their rotation | ECR authenticates from the node's IAM role. No registry credential exists to be issued, stored, or rotated. |
| The external-registry clause in **#3** | The DHCP requirement remains, but now only for AWS endpoint Private DNS — see #22. |

### 8.3 New requirements — Tier 1

These are all zero-cost, but each one, unmet, stops **every** container image pull in
both clusters. In an air-gapped VPC these failures do not produce clean errors: the
connection has nowhere to go, so it **hangs until timeout** and surfaces as a generic
`ImagePullBackOff` naming neither the registry nor the cause.

#### 20. The S3 gateway endpoint policy must allow the ECR layer bucket

ECR serves image **manifests** over the `ecr.dkr` endpoint, but the image **layers** —
the actual bytes — are served from an AWS-managed S3 bucket:

```
arn:aws:s3:::prod-<region>-starport-layer-bucket/*
```

If the S3 gateway endpoint carries a least-privilege policy scoped to bank-owned
buckets, image pulls fail **partway through the layer download**. This presents as an
intermittent network error mid-pull, not as an access-denied, so it is diagnosed slowly.

Minimum addition to the endpoint policy:

```json
{
  "Sid": "AllowEcrLayerRetrieval",
  "Effect": "Allow",
  "Principal": "*",
  "Action": "s3:GetObject",
  "Resource": "arn:aws:s3:::prod-<region>-starport-layer-bucket/*"
}
```

**Impact if not met:** no node in either cluster can pull any image, including the EKS
addons. Nothing starts.

> This requirement already applies today for the AWS-owned addon images. Moving to ECR
> makes it total rather than partial.

#### 21. ~~The S3 gateway endpoint policy must allow the AL2023 repository bucket~~ — **NO LONGER NEEDED (2026-09-07)**

We said below that we would prefer to remove this dependency, and we have: our
In-VPC EC2 Runner now receives **static tool binaries in an S3 bundle** and runs no
package manager at all. **Nothing to grant.** Kept because the dual-stack note at the end
is a real trap if anyone ever re-introduces `dnf` on an instance in this VPC.

*Was: conditional — only if we retain OS package installation on our instances.*

Amazon Linux 2023 serves its `dnf` repositories from a regional S3 bucket
(`al2023-repos-<region>-…`), reachable through the same gateway endpoint.

We would prefer to **remove this dependency entirely** by shipping static tool binaries
in an S3 bundle, and we intend to. We are listing it so that, if you would rather we keep
using `dnf`, the requirement is on the record rather than discovered during a build.

**If you do grant it, please note:** the AL2023 mirror list uses an `s3.dualstack.…`
hostname, which has historically not resolved through an IPv4-only gateway endpoint. It
needs either a dual-stack endpoint or a pinned non-dualstack mirror list.

**Impact if not met:** our In-VPC EC2 Runner cannot bootstrap; it is the only way we can reach
the private EKS API.

#### 22. Private DNS must be enabled on the `ecr.api` and `ecr.dkr` endpoints

AWS documents that ECR VPC endpoints support **only** AWS-provided DNS via Route 53, and
that the `ecr.dkr` endpoint requires Private DNS to be enabled.

If the VPC's DHCP option set points solely at on-premises DNS servers, the ECR service
hostnames resolve to public addresses that this VPC has no route to. That is the most
common failure mode we expect in an enterprise air-gapped VPC, and it is silent.

Either use the Amazon resolver (VPC base + 2), or ensure your resolvers **conditionally
forward** the AWS service domains to it.

**Impact if not met:** identical to #20 — every pull hangs.

#### 23. The ECR endpoint policy must not be scoped to a single AWS account

If a VPC endpoint policy on `ecr.api` / `ecr.dkr` restricts `Principal` or `Resource` to
one account, it will break the **EKS managed addons**, which pull cross-account from
AWS's own registry (`877085696533.dkr.ecr.af-south-1.amazonaws.com` — region-specific;
af-south-1 is NOT the commonly-quoted `602401143452`). It would also break
our own pulls if ECR is hosted in a shared-services account (#25).

We are not asking for an unrestricted policy — restricting to the **ECR actions** we
actually use is fine and welcome:

```
ecr:GetAuthorizationToken
ecr:BatchCheckLayerAvailability
ecr:BatchGetImage
ecr:GetDownloadUrlForLayer
```

**Impact if not met:** `vpc-cni`, `coredns` and `kube-proxy` fail to start; the cluster
never becomes ready.

#### 24. ~~Please confirm the VPC is not RAM-shared~~ — **ANSWERED (assumed) 2026-09-09; still open as R-3**

The working assumption is single-account tenancy: our credentials resolve to the account that owns the VPC. **SCR largely defuses this question** — we create no endpoints, route tables, NACLs or subnet flow logs either way, so the RAM restrictions have nothing left to forbid. What the answer still decides is what we may create *beside* the cluster: KMS keys, Secrets Manager secrets, NLBs, IAM roles and S3 buckets. One command settles it (`aws sts get-caller-identity`).

AWS: *"You can't create, describe, modify, or delete VPC endpoints in subnets that are
shared with you. However, you can use the VPC endpoints in subnets that are shared with
you."*

> **Superseded framing.** The live version of this question, with a ready-to-approve
> proposal for the RAM-shared case, is **#24 in `CLOUD_TEAM_REQUEST_REGISTRY_AND_CICD.md`
> (2026-09-09)**. A RAM-shared VPC is fine with us; we withdraw #13, self-serve #14, and
> ask only for an endpoint escalation path plus describe access.

Our design has us **preferring** to own the eight endpoints on the
critical path — `kms`, `secretsmanager`, `sts`, `ecr.api`, `ecr.dkr`, `ssm`,
`ssmmessages`, `ec2messages` — precisely so that a validator restart or an emergency
runner session never waits on another team's change queue.

If the VPC is shared to us via AWS RAM, **we cannot create them and you must**. That is
workable, but it changes the operational agreement and we need to know before we build.

**Impact if not met (i.e. if it is RAM-shared and undeclared):** our provisioning fails
with an authorization error, and the endpoint ownership model in §7 has to be renegotiated.

#### 25. ~~ECR account topology, and cross-account pull for our node roles~~ — **ANSWERED 2026-09-09; the pull grant is RE-SCOPED to #38**

Answered: a **central shared-services account**, in **af-south-1**, with tag immutability on and no lifecycle expiry — thank you, those are the right defaults and the last two were the ones we expected to have to argue for. What changes under SCR is *whose* role needs the pull grant: images are pulled by **your** cluster's nodes now, so the repository policies must admit **your node group's IAM role**, not ours. That is #38.

Please tell us which you intend:

- **(a) ECR in our workload account.** Simplest; nothing further needed from you.
- **(b) ECR in a central shared-services account.** Then we need repository policies
  granting `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer` and
  `ecr:BatchCheckLayerAvailability` to our EKS node roles and our runner role, and #23
  becomes mandatory rather than merely advisable.

Either works for us. (b) is probably what you want if other teams will share the mirror,
and we are happy to consume it that way.

We would also ask that the repositories are configured with **tag immutability enabled**
and **no lifecycle expiry policy**. A validator node replaced eight months from now must
still be able to pull the exact image digest the network was reviewed and approved on.

#### 26. ~~An approved build-and-push path outside the VPC~~ — **WITHDRAWN 2026-09-09**

You confirmed your self-hosted CI runners have internet egress, so the mirror runs there and we are not asking you to permit GitHub-hosted runners or to create an OIDC identity provider. Nothing inside the VPC ever contacts a public registry; this requirement existed only to establish that the push happens outside it.

Something must fetch upstream artefacts and push them to ECR. It cannot live in this VPC,
by design.

Our recommendation: **AWS CodeBuild, with no VPC configuration attached.** It runs inside
AWS, is auditable through CloudTrail, costs a few cents per run, and — because it is not
attached to the VPC — does not compromise the VPC's no-egress posture in any way. We are
happy for this to sit in a tooling account you control.

If your policy requires the mirroring to happen from a managed build estate instead, tell
us which, and we will target that.

**Impact if not met:** nothing can be published to ECR, and the platform cannot be built.

### 8.4 Revised confirmations

Replacing **Q-4**:

| # | Question | Why it matters |
|---|---|---|
| Q-4a | Please confirm **ECR is the registry** for this platform, in writing. | Recorded as decided on our side (D-16) and the code now assumes it. A written confirmation is what we cite if the "all images from an approved registry" policy is ever audited. |
| Q-4b | ECR account topology — (a) our account or (b) shared services? See #25. | Determines whether repository policies and cross-account grants are needed. |
| Q-4c | Do you require **image scanning / CVE gating** on the mirror before promotion, and to whose policy? | ECR integrates with Amazon Inspector at no extra design cost — but if there is a bank-standard gate, we should wire the pipeline into it rather than invent our own. |
| Q-4d | Who owns the **mirror pipeline** operationally — us, or a central platform team? | Per §8.1 this is a standing commitment. We are content to own it; we need it named. |
| Q-4e | If the bank retains a central artefact repository for other estates, should our mirror pull **from it** rather than from the public internet? | Our recommendation if such a repository is the institutional supply-chain gate: it stays the authority and scanning point, ECR becomes the in-region runtime pull surface. Costs nothing extra and satisfies both policies. Tell us and we will point the pipeline at it. |

Unchanged and still open: **Q-2** (centralised interface endpoints), **Q-3** (egress model),
**Q-5** (golden AMI), **Q-6** (TGW/IPAM cross-charging).

### 8.5 Shared responsibility — delta to §7

| Resource | Cloud Platform Team | Ledger Platform Team |
|---|---|---|
| ~~External registry host + its CA and credentials~~ | ~~Own~~ — withdrawn | ~~Consume~~ — withdrawn |
| ECR registry + repositories | Own, **if** hosted in shared services (#25b) | Own, **if** hosted in our account (#25a); consume otherwise |
| ECR repository policies / cross-account grants | Own under (#25b) | Request |
| S3 gateway endpoint policy | **Own** — must include #20 (and #21 if applicable) | Verify via preflight from inside the VPC |
| Interface endpoints incl. ECR + Private DNS (#22) | **Yours if the VPC is RAM-shared (#24)** — participants cannot create them. We then ask only for an escalation path and describe access | Ours if the VPC is in our account |
| NACL rules on ledger subnets (#13) | Yours if RAM-shared — **we withdraw the ask** and fall back to security groups | Ours if the VPC is in our account |
| Subnet-level flow logs (#14) | Yours if RAM-shared — **we self-serve at ENI level instead**, needing nothing from you | Ours if the VPC is in our account |
| Security groups (#6) | — | **Ours either way** — participants can own their own |
| Mirror pipeline (build + push, #26) | Approve the mechanism; host it if policy requires | Own the content and the schedule |

### 8.6 How we will prove it works before we spend anything

We run `scripts/preflight/verify-images.sh` **from the In-VPC EC2 Runner inside the VPC** — not
from a laptop, which would pass while the cluster still could not pull. It resolves the
image list from the Terraform configuration itself (so it cannot disagree with what will
actually be deployed), pulls every manifest, and prints the digests.

That single check exercises requirements **#20, #22 and #23** end-to-end, in about ten
seconds, before any billable cluster exists. If it passes, the supply chain is proven. If
it fails, we come back to you with a specific requirement number rather than a symptom.

> **Narrowed by SCR §6 (2026-10-09).** On a cluster we do not own, that check proves *our*
> instance can pull, not that your node role can — different principals, different
> policies, and it passes either way. #38 and SCR §6 carry the gates that close the
> difference. "The supply chain is proven" above should be read as "#20, #22 and #23 are
> proven".

---

## Appendix A — IP address sizing

> **WITHDRAWN 2026-09-21 by SCR §2 (shared cluster, namespace tenancy).** We no longer lay
> out subnets or request address space; SCR §1 states our footprint as a quota instead.
> Kept so the numbers behind the original /20 request remain auditable.


### Why EKS consumes addresses faster than pod count suggests

With the AWS VPC CNI, **each pod receives a routable VPC IP address** from the
subnet. The CNI does not allocate these individually — it reserves whole network
interfaces' worth at a time and maintains a warm pool so that pod scheduling is not
gated on an EC2 API call.

On an `m6i.xlarge` (4 interfaces x 15 addresses), a node running ~20 pods typically
**holds ~45 addresses**, of which ~25 are reserved but unused. The planning figure is
therefore **~50 addresses per node**, not ~20.

### Demand

| Component | Addresses |
|---|---|
| Ledger cluster — ~6 nodes | 300 |
| Application cluster — ~20 nodes | 1,000 |
| Interface endpoints (~15 x 3 AZ) | 45 |
| Load balancers (NLB + scaling ALBs) | 69 |
| EKS control-plane cross-account interfaces (x2 clusters) | 8 |
| Deployment runner, future managed databases | 35 |
| **Total peak demand** | **~1,455** |

### Capacity by prefix (3 AZs; AWS reserves 5 addresses per subnet)

| VPC CIDR | Total | Usable across subnet plan | Headroom vs demand |
|---|---|---|---|
| **/20** | 4,096 | **2,805** | **1.9x — requested** |
| /21 | 2,048 | ~1,400 | below demand |
| /22 | 1,024 | ~700 | less than half of demand |

### Proposed subnet plan for a /20

| Subnet purpose | Count | Size | Usable each | Usable total |
|---|---|---|---|---|
| Ledger nodes + pods | 3 (1 per AZ) | /24 | 251 | 753 |
| Application nodes + pods | 3 | /23 | 507 | 1,521 |
| Load balancers | 3 | /26 | 59 | 177 |
| VPC endpoints | 3 | /26 | 59 | 177 |
| Data services (managed databases, caches) | 3 | /26 | 59 | 177 |
| **Total** | **15 subnets** | | | **2,805** |

This allocates 2,880 of 4,096 addresses, leaving **1,216 in reserve** within the /20
for an additional workload tier. (`af-south-1` has exactly three AZs, so unlike a
larger region there is no fourth zone to grow into — the reserve exists for new
tiers, not new zones.)

Tag `kubernetes.io/role/internal-elb=1` is required on the **load-balancer** subnets
(#4).

---

## Appendix B — Interface endpoints required

**Gateway endpoints — no charge, no Transit Gateway dependency:** `s3` (also carries
container image layer retrieval), `dynamodb`.

**Interface endpoints, per AZ:**

| Service | Required by |
|---|---|
| `ssm`, `ssmmessages`, `ec2messages` | Session Manager access to the deployment runner — the only access path |
| `ec2` | EBS CSI driver (volume attachment), VPC CNI (interface management) |
| `ecr.api`, `ecr.dkr` | AWS-owned EKS addon images (see #19) |
| `sts` | IRSA — pod-level IAM role assumption |
| `eks` | Cluster authentication and description |
| `elasticloadbalancing` | AWS Load Balancer Controller |
| `secretsmanager` | Secrets Store CSI driver |
| `kms` | Validator signing key decryption at pod start |
| `logs` | Log shipping to CloudWatch |
| `monitoring` | CloudWatch metrics |
| `sns` | Alert delivery, and event-pipeline fan-out (SNS FIFO) |
| `sqs` | Event-pipeline consumers (SQS FIFO) |

Application workloads will require additional endpoints as the estate grows; each
new AWS service used by any workload in the VPC requires its own endpoint. This is
a further argument for centralised, shared endpoints if you operate them (Q-2).

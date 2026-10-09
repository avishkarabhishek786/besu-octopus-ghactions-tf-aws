# Network Requirements — Besu Ledger Platform on the Shared VPC

**To:** Cloud Platform Team
**From:** Ledger Platform Engineering
**Date:** 2026-08-29
**Status:** Request for provisioning parameters — response needed before VPC creation
**2026-09-21:** **§9 added — shared EKS cluster, namespace tenancy (#27–#39).** It withdraws nine of the requirements below and re-scopes two. **Where §9 and §§2–8 differ, §9 governs.**

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
| EKS clusters | ~~**2** — one for the ledger, one for the application estate~~ **2026-09-21: none — we are a namespace tenant of your shared cluster (§9)** |
| Worker nodes at peak | ~~~26 (~6 ledger, ~20 applications)~~ **2026-09-21: your nodes; ~20 pods, ~6 vCPU / 20 GiB requested, 8 × 20 GiB volumes — §9.3 #27** |
| Internet egress required | **None.** The ledger is a closed network. |

---

## 2. Summary checklist

| # | Requirement | Tier | Cost to provide |
|---|---|---|---|
| 1 | VPC `instance_tenancy = default` | 1 | none |
| 2 | `enableDnsSupport` **and** `enableDnsHostnames` = true | 1 | none |
| 3 | DHCP option set resolves AWS endpoint **Private DNS** (see also #22) | 1 | none |
| ~~4~~ | ~~Subnet tag `kubernetes.io/role/internal-elb=1`; permission to tag~~ **WITHDRAWN §9** | — | none |
| 5 | 3 AZs, identified by **AZ ID** ~~; both clusters and endpoints co-located~~ — under §9 the cluster is yours; we still need our pods spread across 3 AZs for QBFT | 1 | none |
| 6 | Permission to create and manage security groups | 1 | none |
| ~~7~~ | ~~Contiguous **/20**, carved from a reserved /18~~ **WITHDRAWN §9** — a quota, not address space (§9.1) | — | none |
| 8 | **WITHDRAWN under §8** (was: route and DNS to an external registry host) | — | none |
| ~~9~~ | ~~Confirm EKS service CIDR (`172.20.0.0/16`) does not collide~~ **WITHDRAWN §9** — your cluster | — | none |
| ~~10~~ | ~~Permission to associate **gateway** endpoints to the route tables~~ **WITHDRAWN §9** — yours; but **#20 stands** (the S3 policy must admit the ECR layer bucket) | — | none |
| ~~11~~ | ~~Dedicated subnets for the ledger~~ **RE-SCOPED §9 → #28** (a dedicated node group) | 2 | none |
| ~~12~~ | ~~Dedicated route tables for the ledger subnets~~ **WITHDRAWN §9** — folded into #28 | — | none |
| ~~13~~ | ~~Permission to manage NACL rules on the ledger subnets~~ **WITHDRAWN 2026-09-09** — security groups instead; §9 #34 verifies your rules | — | none |
| ~~14~~ | ~~Subnet-level VPC Flow Logs on ledger subnets~~ **WITHDRAWN 2026-09-09** — ENI-level instead | — | none |
| ~~15~~ | ~~Permission to create interface endpoints~~ **WITHDRAWN §9** — yours; but **#22/#23 stand** as checks | — | none |
| ~~16~~ | ~~Dedicated endpoint subnets, separate from load-balancer subnets~~ **WITHDRAWN §9** — the PrivateLink path it protected is gone | — | none |
| ~~17~~ | ~~Associate `100.64.0.0/16` as a secondary CIDR~~ **WITHDRAWN §9** — your CNI configuration | — | none |
| 18 | Private ECR registry **in-region** — the platform's primary registry (§8). *(Hosted in your central shared-services account, per #25 — not ours)* | 1 | ~$1–2/mo |
| 19 | ~~Written exception for AWS-owned EKS addon images~~ — **WITHDRAWN under §8** | 3 | none |
| 20 | S3 gateway endpoint policy must allow `prod-<region>-starport-layer-bucket/*` | 1 | none |
| ~~21~~ | ~~S3 gateway endpoint policy must allow the AL2023 repo bucket~~ **NO LONGER NEEDED** — the instance ships static binaries, no package manager | — | none |
| 22 | **Private DNS enabled** on the `ecr.api` and `ecr.dkr` interface endpoints | 1 | none |
| 23 | ECR endpoint policy **not** scoped to a single AWS account | 1 | none |
| 24 | Confirm the VPC is **not RAM-shared** — **answered (assumed) 2026-09-09, defused by §9; still open as R-3** for what we create *beside* the cluster | 1 | none |
| 25 | ECR account topology — **answered: central shared services, af-south-1.** The pull grant **re-scopes to #38** (your node role, not ours) | 1 | none |
| ~~26~~ | ~~An approved **build-and-push path outside the VPC**~~ **WITHDRAWN 2026-09-09** — your CI runners have egress | — | none |
| **27–39** | **Shared EKS cluster, namespace tenancy — see §9 (2026-09-21).** Withdraws #4, #7, #9, #10, #12, #15, #16, #17; re-scopes #11 → #28 and #25 → #38; **#39** is the surviving half of #7 (IP headroom) | see §9 | none |

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

### 4. ~~Subnet tag `kubernetes.io/role/internal-elb=1`, plus permission to tag~~ — **WITHDRAWN under §9**

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

### 7. ~~Contiguous /20, carved from a reserved /18~~ — **WITHDRAWN under §9**

Withdrawn 2026-09-21: we are a namespace tenant of your shared EKS cluster, not the
builder of a cluster and 15 subnets. We no longer lay out subnets, so there is no address space for us to size. Our footprint is ~20 pods, 6 load-balancer interfaces and 1 administrative instance, taken from **your** subnets — stated as a quota in §9.1 and as a headroom question in §9.3 **#39**. Appendix A is withdrawn with this, and so is the 2026-09-09 CIDR allocation review.

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

### 9. ~~Confirm the EKS service CIDR does not collide~~ — **WITHDRAWN under §9**

Withdrawn 2026-09-21: we are a namespace tenant of your shared EKS cluster, not the
builder of a cluster and 15 subnets. Your cluster, your service CIDR. We ask only for the cluster's version and endpoint configuration (#32).

EKS assigns Kubernetes Service IPs from a CIDR that is **not** part of the VPC —
default `172.20.0.0/16`. It must not overlap with anything reachable over the
Transit Gateway.

**Impact if not met:** this value is **immutable after cluster creation**. A
collision discovered later requires rebuilding the cluster.

---

### 10. ~~Permission to associate gateway endpoints to the route tables~~ — **WITHDRAWN under §9**

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

### 11. ~~Dedicated subnets for the ledger, separate from application subnets~~ — **RE-SCOPED under §9 into #28** (2026-09-21)

A tenant does not place its own subnets. The intent — validators not sharing infrastructure with application workloads — is now asked for as a **dedicated, tainted node group**, in dedicated ledger subnets if you can provide them. If that is refused, `NetworkPolicy` default-deny is the compensating control and we record the posture change.

The ledger's IP pool must not be consumable by application workloads.

**Impact if not met:** a single application autoscaler exhausting a shared subnet
means validator pods cannot be scheduled. With fewer than 3 of 4 validators
available, QBFT loses quorum and the ledger stops producing blocks — a payment-system
availability incident caused by an unrelated workload. Subnet-level separation makes
this structurally impossible rather than a matter of operational discipline.

This costs no additional address space: it is the same /20, divided differently.

### 12. ~~Dedicated route tables for the ledger subnets~~ — **WITHDRAWN under §9**

Withdrawn 2026-09-21: we are a namespace tenant of your shared EKS cluster, not the
builder of a cluster and 15 subnets. Route tables are not a tenant's to own. The isolation this asked for is now part of #28 (a dedicated ledger node group, in dedicated subnets if you can) — and if you grant it, the route tables come with it, on your side.

**Impact if not met:** a routing change made on behalf of an application can alter
the ledger's reachability. The ledger subnets must never acquire a default route.

### 13. ~~Permission to manage NACL rules on the ledger subnets~~ — **WITHDRAWN 2026-09-09**

You told us we are a tenant in your account, and NACLs are not a tenant's to manage. We fall back to security groups, which cover the same ground with nothing needed from you. Under §9 (#34) what replaces this is a *verification*: we check that your subnet rules permit the nine flows our design needs, and cite the flow number if one is blocked.

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

### 15. ~~Permission to create interface VPC endpoints~~ — **WITHDRAWN under §9**

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

### 16. ~~Dedicated endpoint subnets, separate from load-balancer subnets~~ — **WITHDRAWN under §9**

Withdrawn 2026-09-21: we are a namespace tenant of your shared EKS cluster, not the
builder of a cluster and 15 subnets. This existed to keep endpoint interfaces away from the NLB nodes on a PrivateLink path between our two clusters. There is one cluster now and that path is gone, so the constraint has no subject.

Endpoint network interfaces must not share a subnet with the Network Load Balancer
nodes they front.

**Impact if not met:** the application-to-ledger PrivateLink path becomes unreliable
in a same-VPC configuration.

---

## 5. Tier 3 — zero-cost options we ask you to take now

### 17. ~~Associate `100.64.0.0/16` as a secondary VPC CIDR~~ — **WITHDRAWN under §9**

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

### 18. Private ECR registry in-region — now the primary registry

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

> **SUPERSEDED 2026-09-21 — read §9.5 instead.** This table was written when we would
> build two EKS clusters and the endpoint layer. Under §9 the cloud team owns the
> cluster, the node groups, every addon, all the endpoints and the subnet rules, and we
> own what is inside our namespaces plus the AWS resources beside the cluster. The rows
> that inverted are struck below; §9.5 is the current split. (#13 and #14 were already
> withdrawn on 2026-09-09.)

| Resource | Cloud Platform Team | Ledger Platform Team |
|---|---|---|
| VPC, CIDR associations | Create, own | Read only |
| Subnets | Create, own | Consume ~~; request tags (#4)~~ — #4 withdrawn |
| Route tables | Create, own ~~— dedicated per tier (#12)~~ | Read only |
| NACLs (ledger subnets) | Own the resource | **Manage rules** (#13) |
| Security groups | — | **Create and manage** (#6) |
| Interface VPC endpoints | **Own — all of them** (Q-2 answered by §9) | ~~Create in endpoint subnets (#15)~~ → **verify only** |
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
administrative instance now receives **static tool binaries in an S3 bundle** and runs no
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

**Impact if not met:** our SSM runner cannot bootstrap; it is the only way we can reach
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

The working assumption is single-account tenancy: our credentials resolve to the account that owns the VPC. **§9 largely defuses this question** — we create no endpoints, route tables, NACLs or subnet flow logs either way, so the RAM restrictions have nothing left to forbid. What the answer still decides is what we may create *beside* the cluster: KMS keys, Secrets Manager secrets, NLBs, IAM roles and S3 buckets. One command settles it (`aws sts get-caller-identity`).

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

Answered: a **central shared-services account**, in **af-south-1**, with tag immutability on and no lifecycle expiry — thank you, those are the right defaults and the last two were the ones we expected to have to argue for. What changes under §9 is *whose* role needs the pull grant: images are pulled by **your** cluster's nodes now, so the repository policies must admit **your node group's IAM role**, not ours. That is #38.

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

We run `scripts/preflight/verify-images.sh` **from the SSM runner inside the VPC** — not
from a laptop, which would pass while the cluster still could not pull. It resolves the
image list from the Terraform configuration itself (so it cannot disagree with what will
actually be deployed), pulls every manifest, and prints the digests.

That single check exercises requirements **#20, #22 and #23** end-to-end, in about ten
seconds, before any billable cluster exists. If it passes, the supply chain is proven. If
it fails, we come back to you with a specific requirement number rather than a symptom.

> **Narrowed by §9.6 (2026-10-09).** On a cluster we do not own, that check proves *our*
> instance can pull, not that your node role can — different principals, different
> policies, and it passes either way. #38 and §9.6 carry the gates that close the
> difference. "The supply chain is proven" above should be read as "#20, #22 and #23 are
> proven".

---

## 9. Addendum — shared EKS cluster, namespace tenancy (2026-09-21)

> **⇢ This section is written to be sent on its own.** It assumes the reader has our
> 2026-08-29 document and the 2026-09-09 follow-up, and it supersedes both wherever they
> speak about clusters, subnets we would own, or address space.

**Please read this alongside §§2–8. Where they differ, this section governs.**

You told us on 2026-09-21 that we will **not build EKS**: a shared cluster exists, we
are allotted a **namespace** in it, and you run the cluster and its maintenance. You
also told us your VPC has **separate subnets per role** (application, data, …) with
**security rules you define**. We have adopted both. This section states what that
model needs from you, what it lets us **withdraw**, and — because the change moves one
specific operation onto your schedule — the one thing we need agreed in writing rather
than configured.

### 9.1 The model

We become a **Kubernetes tenant**. Everything cluster-scoped is yours: the cluster,
node groups, addons, CRDs, DaemonSets, StorageClasses, webhooks, cluster RBAC. We own
what lives inside our namespaces, and the AWS resources beside the cluster: KMS keys,
Secrets Manager secrets, two internal NLBs, IAM roles, SNS, S3, and one small EC2
administrative instance (the deployment worker — see the 2026-09-14 R-10 ticket, which
is unchanged by this).

**What we will run in the namespace(s)** — from our chart values, so these are real
numbers, not estimates. Production may grow modestly; we will send final figures before
each environment is built.

| Workload | Pods | CPU requested | Memory requested / limit | Persistent volumes |
|---|---|---|---|---|
| Validators (QBFT, one per node — see #28/#29) | 4 | 4 × 500m | 4 × 2 GiB / 4 GiB | 4 × 20 GiB, grows with the chain |
| Bootnodes | 2 | 2 × 250m | 2 × 1 GiB / 2 GiB | 2 × 20 GiB |
| RPC pool (SWIFT, mTLS) | 2 | 2 × 500m | 2 × 2 GiB / 4 GiB | 2 × 20 GiB |
| Explorer (Blockscout: backend, frontend, stats, visualizer, proxy, database) | 6 | ~0.6 vCPU | ~1.8 GiB / ~5.7 GiB | 1 × database (see #37) |
| Monitoring (Prometheus, Alertmanager, Grafana — only if we run our own, #30) | 3 | ~0.4 vCPU | ~0.9 GiB / ~1.9 GiB | 1 × Prometheus |
| **Total, ledger namespace** | **~20** | **~4.5 vCPU** | **~17 GiB / ~36 GiB** | **~10 volumes, ~200 GiB** |

**We would ask for a `ResourceQuota` of roughly 8 vCPU / 24 GiB requests, 48 GiB limits,
40 pods, 12 PVCs / 300 GiB** — the table plus ~30 % headroom, so a routine change does
not hit the ceiling. An application namespace (#27) is sized separately, later.

**Two settled points that do not change:** (1) **no internet egress** — nothing in our
namespaces reaches the internet; images come from ECR over your endpoints (§8); (2) the
**deployment path** — Octopus drives our administrative instance through your shared
egress (R-10). The instance now needs *namespace-scoped* access to your cluster instead
of admin access to ours (#32).

### 9.2 What this lets us withdraw

Nine requirements from the 2026-08-29 document are withdrawn outright, two are
re-scoped. Please treat the originals as closed.

| Withdrawn | Was | Why |
|---|---|---|
| **#4** | Subnet tag `kubernetes.io/role/internal-elb=1` | We bind pods to NLBs we create in Terraform (`TargetGroupBinding`); the controller creates no load balancer and discovers no subnet |
| **#7** | Contiguous /20 from a reserved /18 — and the whole **2026-09-09 CIDR review** (SIT/UAT/PROD /20 each) | We no longer lay out subnets. Our demand is ~20 pod addresses plus NLB interfaces in *your* application subnets — a sizing note for you (#34), not a request |
| **#9** | EKS service CIDR confirmation | Your cluster, your service CIDR |
| **#10** | Gateway-endpoint association | Your cluster's nodes already need S3; the endpoint exists and we verify it (#20 still stands) |
| **#12** | Dedicated route tables for ledger subnets | Folds into #28 if a dedicated node group is granted; otherwise moot |
| **#15** | Permission to create interface endpoints | All 15 services your cluster already needs; we verify (`verify-endpoints.sh`), we create none |
| **#16** | Endpoint subnets distinct from load-balancer subnets | Existed for a PrivateLink path between our two clusters. There is one cluster now; that path is gone |
| **#17** | `100.64.0.0/16` secondary CIDR | Your CNI configuration, not ours |
| — | **Appendix A** (subnet plan) | Superseded in full |

| Re-scoped | Was | Now |
|---|---|---|
| **#11** | Dedicated ledger *subnets* | **#28** — a dedicated ledger *node group*, in dedicated subnets if you can |
| **#25** | Cross-account ECR pull for *our* node roles | **#38** — pull for *your* cluster's node role on our repositories |

**What is still live, and it is a short list:** **#1** (`instance_tenancy = default`), **#2**
(both DNS attributes), **#3** (DHCP resolves AWS Private DNS), **#6** (we create our own
security groups), **#18** (ECR in-region, in your shared-services account), **#20**, **#22**
and **#23** (the three endpoint-policy checks that decide whether an image pull works at
all), plus the **R-10** egress ticket and the new **#27–#39**. Everything else in §§3–5 is
withdrawn, re-scoped or answered, and each one now says so at its own heading.

### 9.3 New requirements — Tier 1 unless marked

> **The two asks that replace the whole of the old network request** are **#27** (namespaces,
> with their Pod Security level and `ResourceQuota` — our numbers are in §9.1) and **#39**
> (IP headroom in the subnets we are scheduled into). Everything else in this section is
> either a confirmation of something you already run (#30, #31, #35, #36) or a single rule
> or grant (#32, #33, #38). **#29 is the one that is not a configuration item at all.**


As before, each states what breaks without it. Most cost nothing. **#29 is the one that
is not a configuration item**, and we ask you to read it first.

#### 29. Node maintenance — a written operating agreement for the validator nodes

The ledger is QBFT with **four validators** and tolerates **exactly one** being down.
Two down at once and the chain **halts** — it does not degrade, it stops, and it stays
stopped until an operator intervenes. This is the single failure we design everything
around, and node maintenance is the operation most likely to cause it.

Our validators carry a `PodDisruptionBudget` with `maxUnavailable: 0` and hostname
anti-affinity, so a normal drain of one node evicts nothing and waits. **We need your
node-rotation and Kubernetes-upgrade tooling to honour that**, specifically:

1. **Never force-evict past the PDB** on nodes carrying our validators. A managed
   node-group update with `--force` ignores PDBs by design; that flag, on our nodes, is
   a chain halt.
2. **One node at a time**, with our validator confirmed back in the block-producing set
   before the next. We will provide a one-line health check you can run, and we are
   happy to be paged to run it ourselves.
3. **Notice** of planned node rotation and Kubernetes version upgrades — we would ask
   for 5 working days — and a **maintenance window** we can attend. Besu must be
   compatibility-tested against each new Kubernetes minor before your upgrade, on your
   cadence (#36).
4. If your tooling cannot do 1–2, the alternative is **#28 with the node group excluded
   from automated rotation**, and we rotate it ourselves under change control.

**What breaks without it:** a routine node rotation halts a payment ledger. There is no
configuration on our side that prevents it; only the agreement does.

#### 27. Two namespaces, with known Pod Security and quota settings

**Ledger** and **application** namespaces, not one — RBAC, `ResourceQuota` and Pod
Security Admission are namespace-granular, and the application workloads (including the
SWIFT event listener) must not share any of them with validators. If the application
estate is not destined for this cluster, tell us and we ask for one.

On each namespace we need to know, before we deploy: the **Pod Security Admission
level** (`kubectl get ns <ns> --show-labels`) — our validator pod has one init step that
runs as root to fix file ownership, which `restricted` rejects at admission, so we need
`baseline` or we rework it first; the **`ResourceQuota`** (§9.1 has our numbers); and any
**`LimitRange`** whose defaults or maximums sit below the requests in §9.1.

One detail we would not otherwise think to ask: Pod Security can also be enforced
**cluster-wide** through the API server's `AdmissionConfiguration`, which does not show up
in a namespace's labels. If that is how it is set here, please tell us the cluster default
as well as any namespace label, because the label alone would mislead us.

**What breaks without it:** at `restricted`, every validator pod is refused before it
starts; a quota below the table makes the fourth validator unschedulable — and QBFT with
three of four is one failure from a halt.

#### 28. A dedicated, tainted node group for the ledger — Tier 2, and it matters

Validators are the trust anchor of a payment ledger. Sharing a node's kernel with
other tenants' pods is a security-posture regression we would rather not absorb.
Standard multi-tenant practice, and it fits your role-separated layout:

- a **node group reserved for our ledger namespace** — a taint only our pods tolerate,
  a label we select on;
- **at least 4 nodes across 3 AZs** (one validator per node, spread by zone), of an
  `m6i.xlarge`-class instance;
- in **dedicated ledger subnets** if you can — that restores the NACL boundary and flow
  logs we asked for in August, now in your hands rather than ours; in the application
  subnets if not.

**If refused:** we run on shared nodes with `NetworkPolicy` default-deny as the
compensating control, and we record the posture change in the design. We would rather
you said no than we assumed.

#### 30. Cluster add-ons we depend on — please tell us which exist

Our workloads consume four cluster-scoped components that a tenant cannot install.
For each: what we need, and what we do if it is absent.

| Add-on | What we need | If absent |
|---|---|---|
| **AWS Load Balancer Controller** | the `TargetGroupBinding` CRD, and tenants permitted to create them — we register our pods into NLB target groups we own | **No workaround.** Our SWIFT and application RPC endpoints cannot be exposed without it. Hard requirement |
| **EBS CSI driver + a StorageClass** | a class we may use: `gp3`, encrypted, `volumeBindingMode: WaitForFirstConsumer`, `allowVolumeExpansion: true` (the chain grows). Tell us whose KMS key encrypts it | **No workaround** — the chain needs persistent volumes |
| **Secrets Store CSI driver + AWS provider** | the `SecretProviderClass` CRD — our validator keys are mounted from Secrets Manager under a customer-managed KMS key | We fetch at pod start from Secrets Manager via the pod's IAM role instead. Acceptable; we prefer the CSI path |
| **Prometheus Operator** | the `PodMonitor` / `PrometheusRule` CRDs, and either your Prometheus scraping our namespace or our own `Prometheus` object in it | We run a plain Prometheus in-namespace. Acceptable |
| **Log shipping** (Fluent Bit or equivalent) | our containers' logs delivered to a CloudWatch log group **we can read and alarm on** | A sidecar per pod. Acceptable, heavier |

Two details in that table matter more than they look, and one extra ask:

- **`volumeBindingMode` must be `WaitForFirstConsumer`.** With `Immediate`, the volume is
  provisioned before the pod is scheduled and is pinned to whichever AZ the provisioner
  chose; our validators are spread across three, so one can end up permanently `Pending`
  with its data in the wrong zone. `allowVolumeExpansion: true` matters because the chain
  grows — without it the first disk-full is an incident rather than a change request.
- **Whose KMS key encrypts the StorageClass's volumes?** If it is yours, we need to know:
  chain data encrypted under a key we cannot audit or hold is something we have to declare
  in review, and a key policy change on your side stops the ledger.
- **The load-balancer controller's own IAM role** needs to be able to register targets into
  target groups **we** create in Terraform. Those do not carry the
  `elbv2.k8s.aws/cluster` tag that a hardened controller policy is often conditioned on. If
  yours has such a condition, `RegisterTargets` fails with `AccessDenied` in the
  controller's log — in a namespace our scoped access cannot read — and from our side the
  binding looks healthy with an empty target group. Please send the policy (question I) or
  confirm there is no tag condition.

**What breaks without it:** the first two, everything — no RPC endpoint and no chain
data. The others degrade the operational posture rather than the ledger.

#### 31. Pod identity mechanism — IRSA or EKS Pod Identity

Our pods reach KMS, Secrets Manager, SNS and SQS through IAM roles bound to service
accounts. Tell us which mechanism the cluster uses:

- **IRSA** — we need the cluster's **OIDC provider ARN and issuer URL**; our roles trust
  it with a condition on `system:serviceaccount:<our-namespace>:<sa>`; or
- **EKS Pod Identity** — the `eks-pod-identity-agent` addon is present, and we need
  permission to create **pod identity associations** for service accounts in our
  namespaces (or you create them from a list we send).

Either is fine. One consequence to flag: **Pod Identity needs the `eks-auth` interface
VPC endpoint.** We left it off our endpoint list deliberately on the assumption of IRSA. If
the cluster already uses Pod Identity the endpoint must already exist — but in this VPC a
missing endpoint does not error, it hangs until timeout, so we would rather confirm it than
infer it (question J).

**What breaks without it:** no pod can decrypt a validator key or read a secret; nothing
starts. And if neither mechanism is wired for our service accounts, the AWS SDK falls back
to instance metadata and our pods run **as your node role** — which on a shared cluster may
quietly succeed with wider privilege than we asked for. We check for that explicitly
(§9.6).

#### 32. Cluster access for our administrative instance — namespace-scoped

Our deployment worker (the R-10 instance) applies Helm releases and runs the
one-validator-at-a-time upgrade script. It needs an **EKS access entry** for its IAM
role with **`AmazonEKSEditPolicy` scoped to our two namespaces** (or a `Role` +
`RoleBinding` you prefer) — never cluster-wide. Plus: the **cluster name, API endpoint
and CA certificate**, and confirmation the endpoint is **private-only**.

One thing that grant probably does not cover: `AmazonEKSEditPolicy` follows the built-in
`edit` role, which enumerates **built-in** kinds. The four custom resources we create —
`TargetGroupBinding`, `SecretProviderClass`, `PodMonitor`, `PrometheusRule` — are included
only if the add-on that owns each CRD ships a `ClusterRole` labelled
`rbac.authorization.k8s.io/aggregate-to-edit`, which is not guaranteed. Please either add a
`Role` in our namespaces covering those four kinds, or confirm the aggregation exists; we
verify it with `kubectl auth can-i` rather than finding out at deploy time.

**What breaks without it:** nothing can be deployed. And too broad a grant would be
something we have to explain in a review; scoped is what we want — so we also check that
the grant *cannot* reach outside our namespaces (§9.6).

#### 33. Node security group — admit our load balancers, or enable Security Groups for Pods

Our two internal NLBs target **pod IPs**, so traffic arrives at the **node** security
group, which is yours. Either:

- add an ingress rule on the node SG permitting **TCP 8545–8546 from our NLB security
  groups** (we will send the IDs), or
- enable **Security Groups for Pods** (`ENABLE_POD_ENI`) so we attach our own SG to the
  RPC pods and you touch nothing.

Also needed: the **node security group ID** and the **node IAM role ARN** (for #38).

**What breaks without it:** the NLB health checks never pass, and SWIFT's endpoint is
unreachable — with no error anywhere, just `unhealthy` targets.

#### 34. Network flows through your subnet rules

You define the rules on each subnet; our pods sit in your application subnets, one per
AZ. Validators are deliberately spread across all three AZs, so **every
validator-to-validator connection crosses a subnet boundary** and meets your rules.
Please confirm these flows are permitted — or send us the rules (§9.4) and we will check
ourselves:

| # | Flow | Port / protocol | From → To |
|---|---|---|---|
| F-1 | Validator/bootnode peer-to-peer | **30303 TCP and UDP** | application subnet ↔ application subnet, all AZs |
| F-2 | RPC via our NLBs (IP targets) + their TCP health checks | 8545, 8546 TCP | load-balancer subnet → application subnet |
| F-3 | Return path for F-2 — **only if the rules are stateless (NACLs)** | 1024–65535 TCP | application subnet → load-balancer subnet |
| F-4 | Metrics scrape | 9545 TCP | your Prometheus → application subnet (or intra-namespace) |
| F-5 | AWS APIs via interface endpoints | 443 TCP | application and administrative-instance subnets → endpoint subnet (+ return if stateless) |
| F-6 | S3 gateway — image layers, Terraform state, our tool bundle | 443 TCP | application and administrative-instance subnets → **the S3 prefix list** (a NACL cannot reference it; the rule must cover S3's regional ranges) |
| F-7 | Administrative instance → cluster API | 443 TCP | its subnet → the control-plane ENIs' subnets |
| F-8 | Administrative instance → egress proxy VIP | the proxy port | its subnet → the egress prefix (R-10, unchanged) |
| F-9 | Explorer database | 5432 TCP | intra-namespace, or application → data subnet (#37) |
| F-10 | DNS | 53 UDP/TCP | to the VPC resolver. Listed for completeness: network ACLs do not apply to the Amazon-provided resolver, so there is probably nothing to do — but if pods resolve through anything else, it needs a rule |

And three placement facts: **which subnet(s) your node group uses**, **which
load-balancer subnets** we may place NLBs in, and **which subnet** our administrative
instance should use.

*(This table is the single source of truth for the flow list: our preflight check and
our design record both cite `#34 F-n` rather than restating it.)*

**Two things we found while building the checker for this, and you should know both
before committing to the table above.**

**1. If these are NACLs, the flow list does not fit in one.** AWS allows **20 rules per
network ACL per direction** by default. Expressing the table above with a per-AZ CIDR for
each counterparty needs **26 inbound and 30 outbound** rules on the subnets our pods run
in — before any of your other tenants' rules. The options are all ordinary, and they are
yours: summarise the source CIDRs (which costs precision), raise the quota to 40 via
Service Quotas (*"Rules per network ACL"*, with the documented network-performance
caveat), or use **security groups**, which have no equivalent limit. **If you grant #28**
(a dedicated ledger node group, so our pods peer across *two* subnet roles), it goes over
the default limit on its own. We are not asking you to pick — we are flagging that
"yes, those flows are permitted" may require a quota change you have not budgeted for,
and we would rather surface it now than discover it in your change window.

**2. A NACL cannot actually protect our service ports, and we would rather say so than
over-claim the control.** NACLs are stateless, so every permitted flow needs a matching
return rule over the ephemeral range, conventionally `1024-65535`. **Every port this
platform listens on is inside that range** — Besu P2P 30303, JSON-RPC 8545, WebSocket
8546, metrics 9545, Postgres 5432. So a NACL that permits ephemeral return traffic from a
given subnet has, by construction, also permitted **inbound connections to every one of
those services** from that subnet. It still separates subnet *roles* usefully, and it is
still worth having; but it is not the tenant boundary, and we have stopped describing it
as one. The controls we rely on are the **security groups** (#6, ours) and
**`NetworkPolicy`** (#35, your CNI must enforce it). This is also why we withdrew #13 —
asking to manage your NACL rules would have bought us less than it appeared to.

**What breaks without it:** a blocked F-1 means the chain never reaches quorum and
reports nothing except a peer count of zero — and note that F-1 needs **both** protocols:
with 30303/TCP open and 30303/UDP closed, our statically-configured peers still connect and
the chain runs with discovery dead, which is a failure we would not see until it mattered; a blocked F-2 is #33's silent failure; a
blocked F-6 stops every image pull half-way through a layer. None of these produce an
error naming the cause — which is why we want to verify the rules before anything is
built, not diagnose them after.

#### 35. `NetworkPolicy` enforcement in the CNI

With shared nodes, Kubernetes `NetworkPolicy` is our primary tenant boundary. Please
confirm the cluster enforces it — VPC CNI with network policy enabled
(`enable-network-policy=true` on `aws-node`), or Calico / Cilium.

**What breaks without it:** our default-deny policies are accepted by the API and
enforced by nothing; every pod in the cluster can reach the validators' privileged RPC.

#### 36. Kubernetes version and upgrade cadence

The current version, the planned upgrade cadence, and the notice period (#29 item 3).
Hyperledger Besu's chart and our operator tooling are validated per Kubernetes minor;
we need to run that validation **before** your upgrade, on your schedule.

#### 37. Placement policy for the explorer database

Blockscout (the block explorer, internal-only) runs a small PostgreSQL. Today it is a
StatefulSet in the namespace. If your policy is that **databases live in the data
subnets**, tell us and we move it to RDS there, with F-9 as an application → data rule.
Either is fine; it is the lowest-stakes item in this document.

#### 38. ECR pull for your cluster's node role (re-scopes #25)

Images are pulled by **your** nodes now. The repository policies on our ECR
repositories (central shared-services account, §8) must grant pull to **your node
group's IAM role** — send us its ARN (#33) and we add it, or add it yourselves if the
repositories are managed centrally.

Two halves, and the second is easy to miss: a repository policy grants the *resource*
side, but the node role still needs **`ecr:GetAuthorizationToken`** in its own identity
policy, which no repository policy can grant. The managed `AmazonEC2ContainerRegistryReadOnly`
policy includes it; a hardened policy scoped to your own registry account will refuse ours.
Please confirm which the node role carries.

**What breaks without it:** `ImagePullBackOff` on every pod, against a registry that
looks fully populated. Our own `verify-images.sh` **cannot catch this** — it authenticates
as our administrative instance, not as your node role, so it passes either way. We close
that gap with a canary pull from inside our namespace (§9.6).

#### 39. IP headroom in the subnets we are scheduled into

This is the one piece of the old /20 request (#7) that survives, and it is a **question
for you rather than a request from us** — the subnets and the node groups are both yours.
It needs asking because the thing that drives it is counter-intuitive.

With the **AWS VPC CNI**, which EKS uses by default, **every pod receives a real VPC IP
address**, and nodes do not request them one at a time: the CNI attaches a whole ENI's
worth in advance so that pods can start without waiting on an EC2 API call. On an
`m6i.xlarge`-class node that is roughly **30 addresses while idle and up to about 50 under
load**, regardless of how many pods are actually running.

So **our ~20 pods are not the measure of what we consume — the nodes we land on are.**
Please confirm there is room for:

* the **nodes** our ~20 pods will be scheduled onto, in whichever application subnets your
  node group uses, alongside your other tenants;
* **6 load-balancer interfaces** — two internal network load balancers, one per AZ across
  three AZs — in whichever load-balancer subnet you want us to use;
* **1 address** for our administrative instance, in whichever subnet you prefer for it.

If headroom is tight, the remedies are all yours and all ordinary: a larger node subnet,
`WARM_IP_TARGET` / `MINIMUM_IP_TARGET` tuning on the CNI, prefix delegation, or VPC CNI
custom networking on a secondary CIDR (the old #17). **We are flagging it, not proposing
it.** Note that prefix delegation allocates in /28 blocks per ENI, which makes consumption
*worse* on a small subnet — it is the right tool for large subnets and the wrong one here.

One small ask alongside the confirmation: **if you alarm on subnet address exhaustion,
please include the subnets we land in.** AWS publishes no CloudWatch metric for free
addresses in a subnet, so this is never accidental — and a snapshot reading from us does not
protect against another tenant's scale-up next week.

**What breaks without it:** pods stuck in `ContainerCreating` with an IP-allocation error,
on a cluster that looks healthy from every other angle. It is not a clean "out of
addresses" failure, and on a shared subnet it can arrive because of someone else's
scaling rather than ours — which is why we would rather know the margin now than diagnose
it later.

### 9.4 What we need you to send — four commands, then a few questions

Most of §9.3 is answered by pasting four outputs. We ask for these rather than
descriptions because we have been misled by descriptions before; a string cannot be
ambiguous.

```bash
# 1 — the cluster: version, endpoint access, OIDC issuer, addons
aws eks describe-cluster --name <cluster> --region af-south-1
aws eks list-addons      --cluster-name <cluster> --region af-south-1
aws eks describe-nodegroup --cluster-name <cluster> --nodegroup-name <ng> \
    --query 'nodegroup.{subnets:subnets,instanceTypes:instanceTypes,taints:taints,labels:labels,nodeRole:nodeRole,sg:resources.remoteAccessSecurityGroup}'

# 2 — what is installed, and what we may use
kubectl get crd | grep -E 'targetgroupbindings|secretproviderclasses|podmonitors|prometheusrules|securitygrouppolicies'
kubectl get storageclass
kubectl get ns <our-namespace> --show-labels
kubectl get resourcequota,limitrange -n <our-namespace>
kubectl -n kube-system get ds aws-node -o jsonpath='{.spec.template.spec.containers[?(@.name=="aws-node")].env}' | tr ',' '\n' | grep -iE 'NETWORK_POLICY|POD_ENI'
kubectl get deploy -A -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl get storageclass <class> -o jsonpath='{.volumeBindingMode}{" "}{.allowVolumeExpansion}{" "}{.parameters.kmsKeyId}{"\n"}'

# 3 — the subnet rules our flows must pass (#34)
aws ec2 describe-network-acls   --region af-south-1 --filters Name=association.subnet-id,Values=<node,lb,data subnet ids>
aws ec2 describe-security-groups --region af-south-1 --group-ids <node sg id>

# 4 — free addresses in the subnets we would land in (#39)
aws ec2 describe-subnets --region af-south-1 --subnet-ids <node,lb,admin subnet ids> \
    --query 'Subnets[].{subnet:SubnetId,az:AvailabilityZoneId,cidr:CidrBlock,free:AvailableIpAddressCount}'
```

In words:

| # | Question |
|---|---|
| A | Is the **application estate** also destined for this cluster (#27 — one namespace or two)? |
| B | Is the node group **charged back** to consuming teams? (cost model only) |
| C | Are the subnet rules **NACLs, security groups, or both**? (decides whether F-3 and the return rows in #34 are real) |
| D | For #33: will you **add the node-SG rule**, or is **Security Groups for Pods** enabled? |
| E | Your **node-rotation policy** — do you ever force past a PDB, and what notice do tenants get? (#29) |
| F | The **cadence** for Kubernetes upgrades (#36) |
| G | **Databases in data subnets** — policy or preference? (#37) |
| H | Who creates our **access entry** (#32) and **pod identity associations** if #31 is Pod Identity |
| I | The **load-balancer controller's IAM policy** — is `RegisterTargets` conditioned on a resource tag? (#30) |
| J | If #31 is Pod Identity: does the VPC have the **`eks-auth` interface endpoint**? (#31) |
| K | Is Pod Security enforced **cluster-wide** as well as by namespace label? (#27) |

### 9.5 Shared responsibility — delta to §7 and §8.5

| Resource | Cloud Platform Team | Ledger Platform Team |
|---|---|---|
| EKS cluster, node groups, Kubernetes upgrades, addons, CRDs, StorageClasses, cluster RBAC | **Own** | Consume; assert via preflight |
| Node rotation on ledger nodes | **Own the tooling, honour #29** | Provide the health check; attend the window |
| Namespaces, quotas, PSA labels, access entries | **Own** (#27, #32) | Request; verify |
| Node security group rule for our NLBs, or SGP | **Own** (#33) | Send NLB SG IDs |
| Subnet rules for F-1..F-9 | **Own** (#34) | Verify by preflight; cite the flow number on failure |
| Free addresses in the node / LB / instance subnets | **Own the sizing** (#39) | State our footprint; verify the margin before deploying |
| Everything inside our namespaces; NLBs, KMS, Secrets Manager, IAM roles, SNS/SQS, S3, the administrative instance | — | **Own** |
| ECR repository policies for your node role (#38) | Add, if repositories are centrally managed | Request; verify from the runner |
| ~~Interface endpoints, gateway endpoints, route tables, NACL rules, flow logs~~ | **Own — all of it, now without qualification** | Verify only |

### 9.6 How we will prove it works before we spend anything

Every requirement above states what breaks without it. Almost all of those breakages are
**silent**: nothing reports the cause, and several report nothing at all because they look
like success. So for each requirement we have written down the check that turns it into a
named failure, and the stage it runs at. All are read-only, all are free, and the whole
set takes about a minute.

Two instruments do most of the work:

- **Server-side admission dry-run.** We render our manifests and submit them with
  `--dry-run=server`, which runs your Pod Security, `ResourceQuota`, `LimitRange`, RBAC
  and webhook admission without creating anything. If the namespace will not accept our
  pods we learn it in seconds, before a cluster-minute is billed.
- **Checks that assert a negative.** A boundary — a scoped grant, a default-deny policy —
  works identically whether it is present or missing, so the only proof is a probe that
  must *fail*. Those are called out below.

| Req | What fails silently | How we detect it, and when |
|---|---|---|
| **#27** Pod Security | Pod Security can be enforced **cluster-wide** through the API server's `AdmissionConfiguration`, which does not appear in `kubectl get ns --show-labels`. And a violation in a StatefulSet's pod template comes back as a *warning*, not a rejection, because enforcement happens when the controller creates the pod — so a naive dry-run passes and the validator still never starts | Dry-run a **standalone Pod** built from the same template, and treat any admission warning as a failure. Pre-deploy |
| **#27** quota | The worst case in this document, because **it looks like success.** A quota a few hundred millicores short admits three validators and refuses the fourth. QBFT's quorum is 3 of 4, so the chain starts, produces blocks and reports healthy — with **zero** fault tolerance. The refusal is an event on the StatefulSet; there is no fourth pod to notice | `hard` minus `used` against the §9.1 table, pre-deploy. Then a post-deploy gate that fails unless `qbft_getValidatorsByBlockNumber` returns **four** and every one is `Ready` |
| **#28** | Our spread constraints are `whenUnsatisfiable: ScheduleAnyway` — deliberate, so scheduling never blocks. On a busy cluster that lets two validators land on one node, silently; one drain then removes two of four and halts the chain | Ours to fix: the hostname constraint for validators becomes `DoNotSchedule`, so the failure is a `Pending` pod we can see rather than a co-location we find during an incident. Plus a post-deploy gate asserting four distinct node names |
| **#29** | **No check exists** — see below |
| **#30** CRD vs controller | A CRD proves only that something once installed it. If the controller is not running or not reconciling, our `TargetGroupBinding` is accepted and simply sits there: no targets register, the NLB stays empty, nothing errors | Assert the CRD **and** a ready controller, pre-deploy. Then assert real target registration post-deploy — `describe-target-health` must return four healthy targets, not an empty list |
| **#30** controller IAM | Our target groups are created by our own Terraform, so they do not carry the `elbv2.k8s.aws/cluster` tag that a hardened load-balancer-controller policy is often conditioned on. The controller then fails `RegisterTargets` with `AccessDenied` **into its own log, in a namespace our scoped access cannot read.** From our side: a healthy-looking binding and an empty target group, indefinitely | Question I in §9.4 asks for the policy so we can check the condition before we build. The target-health gate above catches it afterwards whatever the cause |
| **#30** StorageClass | `volumeBindingMode: Immediate` provisions the volume *before* the pod is scheduled, pinning it to an arbitrary AZ — with validators spread across three, one can end up permanently `Pending` with its data in the wrong zone. `allowVolumeExpansion: false` is invisible until the chain fills the disk, by which time it is an incident rather than a change | Assert both fields on the class, pre-deploy |
| **#31** | The one with a security consequence. If we build for Pod Identity and the cluster uses IRSA — or nothing is wired for our service account — no credential variables are injected, the AWS SDK falls through to instance metadata, and the pod runs **as your node role**. On a shared cluster that role is likely broader than ours, so the call may well *succeed*: wrong principal, your CloudTrail, not ours | `aws sts get-caller-identity` from inside one of our pods at startup; fail unless the ARN is the role we expect. Also ours to get right: our IRSA trust policies must condition on `sub = system:serviceaccount:<our-ns>:<sa>` **and** `aud = sts.amazonaws.com`, or any pod in any namespace of your cluster could assume them. A static check fails our plan if either condition is missing |
| **#32** | Two directions. **Too narrow** is loud (`Forbidden`) but blocks a deployment: `AmazonEKSEditPolicy` follows the built-in `edit` role, which enumerates built-in kinds, so the four custom resources we create are covered only if an add-on ships a ClusterRole labelled `aggregate-to-edit` — not guaranteed. **Too broad is the silent one:** a cluster-wide grant works exactly as well as a scoped one, so nothing ever tells us the boundary is absent | `kubectl auth can-i` as the worker's role, asserting the positives (create those four kinds in our namespaces) **and the negatives** (`create pods -n kube-system` must return `no`). Pre-deploy |
| **#33** | The health checks fail, targets read `unhealthy` with `Target.FailedHealthChecks`, and nothing names a security group. If Security Groups for Pods is the chosen route instead and the `SecurityGroupPolicy` selector does not match our pods, they get an ordinary node ENI — our security group is simply not applied, with no error at all | Pre-deploy: evaluate the node SG for 8545–8546 from our NLB security groups. Post-deploy: assert the `vpc.amazonaws.com/pod-eni` annotation on the RPC pods when SGP is the route, and four healthy targets |
| **#34** | Silent by construction — this class is why the document exists. F-1 blocked gives a peer count of zero and no block ever produced; F-6 blocked stalls an image pull mid-layer; F-5 blocked makes every AWS call hang until timeout. **One partial case worth naming:** if 30303/TCP is permitted and 30303/**UDP** is not, our statically-configured peers still connect and the chain runs — discovery is dead and we would not find out until it mattered | A preflight evaluates the rules you send (§9.4 command 3) against F-1..F-10 **before anything is created**, testing each protocol separately, and names the flow: `#34 F-1 BLOCKED: NACL <id> entry <n> denies 30303/udp from <cidr>`. Post-deploy, peer count must be 3 on every validator |
| **#35** | The API server accepts `NetworkPolicy` objects whether or not anything enforces them. A default-deny policy that enforces nothing is indistinguishable from one that works | Read the `aws-node` configuration (§9.4 command 2), then **prove** it: a two-pod probe in our own namespace, one connection that policy forbids, asserting it is actually refused. Configuration is evidence; a refused connection is proof |
| **#36** | Silent in the direction that matters. Your upgrade breaks nothing at the moment it lands; it breaks the next time we apply, when a removed API version stops a chart reconciling | The cluster contract pins a **tested version range** and fails our plan when the live version is above it — an upper bound, not just a minimum. The first apply after your upgrade stops with `#36: cluster is 1.37, validated to 1.36; run the compatibility pass first` |
| **#37** | Loud enough: if Postgres moves to a data subnet and F-9 is not open, Blockscout logs connection timeouts | Covered by the F-9 row of the #34 check |
| **#38** | **The gap is in our own checking, and we would rather say so.** `verify-images.sh` authenticates with *our* credentials, so it proves our administrative instance can pull — not that your node role can. Different principals, different policies, and the check passes either way | Three parts: assert your node role ARN appears in each repository policy with `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`, `ecr:BatchCheckLayerAvailability`; confirm the node role's **identity** policy allows `ecr:GetAuthorizationToken` (a repository policy cannot grant it, and a policy scoped to your own registry account will refuse ours); and the only real proof — a **canary pod** in our namespace pulling one small image from our registry, before anything expensive is built |
| **#39** | Partly undetectable, honestly. The symptom is pods stuck in `ContainerCreating` with `failed to assign an IP address`, on a cluster healthy from every other angle | We read `AvailableIpAddressCount` and fail if the margin is below our node count × ~50 — but on a shared subnet that is a snapshot, and another tenant's scale-up can consume it an hour later. So also: an alert on pod-sandbox creation failures in our namespace, and an ask — **if you alarm on subnet address exhaustion, please include the subnets we land in.** AWS publishes no CloudWatch metric for it, so it has to be deliberate |

#### What has no check, and what we do instead

**#29 is the exception.** There is no configuration to read and no probe to run: a
force-drain past our `PodDisruptionBudget` is indistinguishable from any other
maintenance until the second validator stops. What we can do is make it loud when it
happens rather than when the chain halts —

- an alarm when any validator leaves the block-producing set for more than five minutes
  (one is survivable; it is also the warning);
- an alarm when block height stops advancing (two down — the chain has already halted);
- the one-line health check in #29 item 2, so your tooling can gate its own next step.

Detective, not preventive. That is precisely why we asked you to read #29 first.

Each failure above names a requirement number from this document. If every check passes,
the platform deploys. If one fails, we come back to you with `#34 F-1` and the exact rule,
or `#33` and the exact port — rather than *"the chain won't start."*
---

## Appendix A — IP address sizing

> **WITHDRAWN 2026-09-21 by §9.2 (shared cluster, namespace tenancy).** We no longer lay
> out subnets or request address space; §9.1 states our footprint as a quota instead.
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

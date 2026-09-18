# Network Requirements — Besu Ledger Platform on the Shared VPC

**To:** Cloud Platform Team
**From:** Ledger Platform Engineering
**Date:** 2026-08-29

> **POINT-IN-TIME COPY (v1, 2026-08-29).** The canonical document lives in the
> platform project (`sbsa_besu/docs/`). This copy is deliberate, not a symlink:
> the real cloud team works from a document sent to them on a given date, so
> drift between the two must be VISIBLE. Re-copy and bump the version when the
> spec changes.
**Status:** Request for provisioning parameters — response needed before VPC creation

---

## 1. Purpose

We are building a permissioned Hyperledger Besu (QBFT) ledger platform whose only
external consumer is **SWIFT**, reaching a JSON-RPC endpoint over SWIFT's private
MV-SIPN network. We have adopted your four architectural constraints in full:

1. a single shared VPC for the ledger and the application estate
2. private subnets only — no public subnets, no Internet Gateway
3. all container images sourced from Sonatype Nexus
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
| EKS clusters | **2** — one for the ledger, one for the application estate |
| Worker nodes at peak | ~26 (~6 ledger, ~20 applications) |
| Internet egress required | **None.** The ledger is a closed network. |

---

## 2. Summary checklist

| # | Requirement | Tier | Cost to provide |
|---|---|---|---|
| 1 | VPC `instance_tenancy = default` | 1 | none |
| 2 | `enableDnsSupport` **and** `enableDnsHostnames` = true | 1 | none |
| 3 | DHCP option set resolves both AWS endpoint DNS and Nexus | 1 | none |
| 4 | Subnet tag `kubernetes.io/role/internal-elb=1`; permission to tag | 1 | none |
| 5 | 3 AZs, identified by **AZ ID**; both clusters and endpoints co-located | 1 | none |
| 6 | Permission to create and manage security groups | 1 | none |
| 7 | Contiguous **/20**, carved from a reserved /18 | 1 | address space |
| 8 | Route and DNS resolution to Nexus from the node subnets | 1 | none |
| 9 | Confirm EKS service CIDR (`172.20.0.0/16`) does not collide | 1 | none |
| 10 | Permission to associate **gateway** endpoints (S3, DynamoDB) to the route tables — or you create them | 1 | none |
| 11 | Dedicated subnets for the ledger, separate from applications | 2 | none |
| 12 | Dedicated route tables for the ledger subnets | 2 | none |
| 13 | Permission to manage NACL rules on the ledger subnets | 2 | none |
| 14 | Subnet-level VPC Flow Logs on ledger subnets to our destination | 2 | minimal |
| 15 | Permission to create interface endpoints (min. 8 services) | 2 | none |
| 16 | Dedicated endpoint subnets, separate from load-balancer subnets | 2 | none |
| 17 | Associate `100.64.0.0/16` as a secondary CIDR (unused, held in reserve) | 3 | none |
| 18 | Private ECR mirror in our account as a Nexus fallback | 3 | ~$1/mo |
| 19 | Written exception for AWS-owned EKS addon images | 3 | none |

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

### 3. DHCP option set must resolve both AWS endpoint DNS and Nexus

If the DHCP option set points only at on-premises DNS servers, endpoint Private
DNS stops resolving unless those servers forward appropriately to the Amazon
resolver at the VPC base + 2 address.

**Impact if not met:** identical symptoms to #2, from a different cause. This is
the most common failure mode in air-gapped enterprise VPCs.

### 4. Subnet tag `kubernetes.io/role/internal-elb=1`, plus permission to tag

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

### 7. Contiguous /20, carved from a reserved /18

Full sizing calculation is in **Appendix A**. Summary: peak demand is ~1,455
addresses; a /20 provides 2,805 usable across the proposed subnet plan (~1.9x
headroom), while a /21 provides 1,521 — effectively zero headroom.

We ask that the /20 be allocated from a **reserved /18** in your IPAM so that future
growth never requires re-addressing a live payment system.

### 8. Route and DNS resolution to Nexus from the node subnets

Container images are pulled by containerd **on each node**, using the node's own
address. Nexus must be routable and resolvable from the node subnets.

**Impact if not met:** no node ever successfully joins either cluster.

Please also confirm the **TLS trust chain** for Nexus — we must install the issuing
CA certificate into each node's trust store and configure containerd accordingly, as
part of the node launch template.

### 9. Confirm the EKS service CIDR does not collide

EKS assigns Kubernetes Service IPs from a CIDR that is **not** part of the VPC —
default `172.20.0.0/16`. It must not overlap with anything reachable over the
Transit Gateway.

**Impact if not met:** this value is **immutable after cluster creation**. A
collision discovered later requires rebuilding the cluster.

---

### 10. Permission to associate gateway endpoints to the route tables

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

### 11. Dedicated subnets for the ledger, separate from application subnets

The ledger's IP pool must not be consumable by application workloads.

**Impact if not met:** a single application autoscaler exhausting a shared subnet
means validator pods cannot be scheduled. With fewer than 3 of 4 validators
available, QBFT loses quorum and the ledger stops producing blocks — a payment-system
availability incident caused by an unrelated workload. Subnet-level separation makes
this structurally impossible rather than a matter of operational discipline.

This costs no additional address space: it is the same /20, divided differently.

### 12. Dedicated route tables for the ledger subnets

**Impact if not met:** a routing change made on behalf of an application can alter
the ledger's reachability. The ledger subnets must never acquire a default route.

### 13. Permission to manage NACL rules on the ledger subnets

**Rationale:** a NACL provides a **stateless L3 boundary that does not depend on
security-group correctness** — defence in depth for a system carrying SWIFT traffic,
and a control we expect to be asked about during audit. This is the closest
equivalent to the VPC boundary that consolidation removed.

We are asking to manage the **rules** on ledger subnets only; the NACLs themselves
can remain your resources.

### 14. Subnet-level VPC Flow Logs on the ledger subnets, delivered to our destination

Either grant us permission to create subnet-level flow logs on the ledger subnets,
or deliver a copy of the relevant records to our log destination.

**Impact if not met:** network forensics on the ledger is a compliance artifact. If
flow logs exist only under another team's ownership, we cannot answer "which hosts
connected to the validators, and when" during a security investigation.

### 15. Permission to create interface VPC endpoints

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

### 16. Dedicated endpoint subnets, separate from load-balancer subnets

Endpoint network interfaces must not share a subnet with the Network Load Balancer
nodes they front.

**Impact if not met:** the application-to-ledger PrivateLink path becomes unreliable
in a same-VPC configuration.

---

## 5. Tier 3 — zero-cost options we ask you to take now

### 17. Associate `100.64.0.0/16` as a secondary VPC CIDR

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

### 18. Private ECR mirror in our account, as a Nexus fallback

**This does not weaken the Nexus policy.** Nexus remains the source of record and
populates the mirror; the mirror is a same-region read replica of approximately 20
images.

**Rationale — business continuity:** node replacement must not depend on a service
outside AWS. If Nexus is unavailable, no new node can pull images, and we cannot
replace a failed validator. For a payment system this is a single point of failure
outside the platform's own availability envelope. Approximate cost: USD 1/month.

### 19. Written exception for AWS-owned EKS addon images

The EKS managed addons `vpc-cni`, `coredns` and `kube-proxy` pull from AWS's own ECR
registry and **cannot be repointed at Nexus**. The alternative — self-managing these
three addons — forfeits EKS-managed patching, which we consider a worse security
outcome than the exception.

We ask for this to be recorded as an approved exception now, so that "all images from
Nexus" is not later assessed as a policy breach.

---

## 6. Confirmations we need from you

| # | Question | Why it matters |
|---|---|---|
| ~~Q-0~~ | **ANSWERED: `af-south-1` (Africa, Cape Town).** Remaining action: `af-south-1` is an **opt-in region** and must be enabled on the account before anything provisions. | Resolved 2026-08-29. |
| ~~Q-1~~ | **ANSWERED (assumed): provisioned in our own account, not RAM-shared.** Please confirm — if it is in fact RAM-shared, participant restrictions on creating a **VPC endpoint service** would force us to redesign the application-to-ledger path. | Resolved (assumption) 2026-08-29. |
| Q-2 | Do **centralised interface endpoints** exist in a shared-services VPC that we can consume via Route 53 private hosted zones? | Determines whether we create ~15 endpoints ourselves or route to yours. Material cost difference. |
| Q-3 | Is there **internet egress** via Transit Gateway and a proxy, or is the VPC fully air-gapped? | We are building for a full air-gap and will treat any egress as a bonus, but proxy configuration would need to be threaded through containerd, kubelet and the AWS SDKs. |
| Q-4 | **Nexus specifics:** hostname, authentication model, issuing CA bundle, and whether it proxies **Helm charts and Terraform providers** in addition to Docker images | Charts and providers are as load-bearing as images in an air-gapped build. |
| Q-5 | Is a **golden AMI** mandated for EC2 instances, and if so which OS family? | EKS-optimised AMIs are Amazon Linux 2023. A RHEL mandate means custom AMI construction and the loss of EKS-managed AMI patching. |
| Q-6 | Are **Transit Gateway** attachment charges and **IPAM** charges cross-charged to consuming teams? | Needed for our cost model; not a design constraint. |

---

## 7. Shared responsibility — proposed split

| Resource | Cloud Platform Team | Ledger Platform Team |
|---|---|---|
| VPC, CIDR associations | Create, own | Read only |
| Subnets | Create, own | Consume; request tags (#4) |
| Route tables | Create, own — dedicated per tier (#12) | Read only |
| NACLs (ledger subnets) | Own the resource | **Manage rules** (#13) |
| Security groups | — | **Create and manage** (#6) |
| Interface VPC endpoints | Central ones, if operated (Q-2) | **Create in endpoint subnets** (#15) |
| Gateway endpoints (S3, DynamoDB) | — | Create — no charge |
| Transit Gateway + attachments | Own | Consume |
| DNS / Route 53 Resolver rules | Own | Consume; require Nexus + AWS endpoint resolution |
| VPC Flow Logs | VPC-level | **Subnet-level on ledger subnets** (#14) |
| Nexus | Own | Consume |
| IPAM | Own | — |
| EKS clusters, node groups, launch templates | — | Own |
| Internal load balancers | — | Own (via AWS Load Balancer Controller) |
| PrivateLink endpoint service | — | Own |
| Kubernetes workloads, secrets, KMS keys | — | Own |

---

## Appendix A — IP address sizing

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
| `sns` | Alert delivery |

Application workloads will require additional endpoints as the estate grows; each
new AWS service used by any workload in the VPC requires its own endpoint. This is
a further argument for centralised, shared endpoints if you operate them (Q-2).

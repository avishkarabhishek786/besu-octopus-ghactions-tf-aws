# Shared EKS Cluster — What the Ledger Platform Needs From You

**To:** Cloud Platform Team
**From:** Ledger Platform Engineering
**Date:** 2026-10-09 (updated 2026-10-10: R-10 item 7 and the F-8 return, both found in our first deployment)
**Region:** `af-south-1`
**Status:** Open — we need your answers before we deploy into the shared cluster

This document puts in one place **everything we still need to raise with you, or share
with you**. For sending, it replaces our 2026-08-29 network requirements document, its
2026-09-04 ECR addendum and its 2026-09-21 shared-cluster addendum. **Requirement numbers
are kept from those documents (#1–#39)**, so an answer you have already given still lines
up. Numbers that are withdrawn or answered are listed once in §2 and not repeated.

You told us on 2026-09-21 that we will **not build EKS**: a shared cluster exists, we
are allotted a **namespace** in it, and you run the cluster and its maintenance. You
also told us your VPC has **separate subnets per role** (application, data, …) with
**security rules you define**. We have adopted both. This document states what that
model needs from you, what it lets us **withdraw**, and — because the change moves one
specific operation onto your schedule — the one thing we need agreed in writing rather
than configured.

| § | Contents |
|---|---|
| 1 | The model — what we run in the namespace, and what we own beside the cluster |
| 2 | What is withdrawn, what is answered, and what is still live |
| 3 | New requirements **#27–#39** — **please read #29 first** |
| 4 | What we need you to send — five commands, then a few questions |
| 5 | Shared responsibility |
| 6 | How we will prove it works before we spend anything |
| 7 | Earlier requirements that still stand, the VPC endpoints, and our ECR repositories |
| 8 | Still open from our 2026-09-09 follow-up |
| 9 | Event pipeline — questions for you, or for the team you point us to |

---

## 1. The model

We become a **Kubernetes tenant**. Everything cluster-scoped is yours: the cluster,
node groups, addons, CRDs, DaemonSets, StorageClasses, webhooks, cluster RBAC. We own
what lives inside our namespaces, and the AWS resources beside the cluster: KMS keys,
Secrets Manager secrets, two internal NLBs, IAM roles, SNS, SQS, S3, and one small EC2
instance — our **In-VPC EC2 Runner**, the machine we deploy from (its egress ticket,
R-10 in §8, is unchanged by this).

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
not hit the ceiling. In quota keys: `requests.cpu`, `requests.memory`, `limits.memory`,
`pods`, `persistentvolumeclaims`, `requests.storage` — **and no `limits.cpu`** (#27 says
why). An application namespace (#27) is sized separately, later.

**Two settled points that do not change:** (1) **no internet egress** — nothing in our
namespaces reaches the internet; images come from ECR over your endpoints (§7); (2) the
**deployment path** — Octopus drives our In-VPC EC2 Runner through your shared
egress (R-10). The instance now needs *namespace-scoped* access to your cluster instead
of admin access to ours (#32).

---

## 2. What this lets us withdraw

Nine requirements from our 2026-08-29 document are withdrawn outright, two are
re-scoped. Please treat the originals as closed. (The numbers below are that document's.)

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
| — | **Appendix A** of that document (subnet plan) | Superseded in full |

| Re-scoped | Was | Now |
|---|---|---|
| **#11** | Dedicated ledger *subnets* | **#28** — a dedicated ledger *node group*, in dedicated subnets if you can |
| **#25** | Cross-account ECR pull for *our* node roles | **#38** — pull for *your* cluster's node role on our repositories |

**Answered — thank you:** **#18** and **#25** (ECR in your shared-services account, in
af-south-1, tag immutability on, no lifecycle expiry), and **#24** in its original form (we
are proceeding as tenants in your account; the residual questions are R-3 in §8).

**Still live, and it is a short list:**

- the **new requirements #27–#39** (§3);
- from the earlier documents, **#1, #2, #3, #5, #6** and the three endpoint-policy checks
  **#20, #22, #23**, together with the **VPC endpoints** themselves and **who creates our
  ECR repositories** (§7);
- the account-level and pipeline asks from our 2026-09-09 follow-up — **R-10** (egress),
  **R-3**, **R-7**, **R-2b** and **R-8** (§8);
- the **event pipeline questions EQ-1..EQ-7**, and four questions for whichever team owns
  the receiving system (§9).

Everything else from the earlier documents is withdrawn, re-scoped or answered.

---

## 3. New requirements — Tier 1 unless marked

> **The two asks that replace the whole of the old network request** are **#27** (namespaces,
> with their Pod Security level and `ResourceQuota` — our numbers are in §1) and **#39**
> (IP headroom in the subnets we are scheduled into). Everything else in this section is
> either a confirmation of something you already run (#30, #31, #35, #36) or a single rule
> or grant (#32, #33, #38). **#29 is the one that is not a configuration item at all.**


As before, each states what breaks without it. Most cost nothing. **#29 is the one that
is not a configuration item**, and we ask you to read it first.

### 29. Node maintenance — a written operating agreement for the validator nodes

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

### 27. Two namespaces, with known Pod Security and quota settings

**Ledger** and **application** namespaces, not one — RBAC, `ResourceQuota` and Pod
Security Admission are namespace-granular, and the application workloads (including the
SWIFT event listener) must not share any of them with validators. If the application
estate is not destined for this cluster, tell us and we ask for one.

On each namespace we need to know, before we deploy: the **Pod Security Admission
level** (`kubectl get ns <ns> --show-labels`) — our validator pod has one init step that
runs as root to fix file ownership, which `restricted` rejects at admission, so we need
`baseline` or we rework it first; the **`ResourceQuota`** (§1 has our numbers); and any
**`LimitRange`** whose defaults or maximums sit below the requests in §1.

One detail we would not otherwise think to ask: Pod Security can also be enforced
**cluster-wide** through the API server's `AdmissionConfiguration`, which does not show up
in a namespace's labels. If that is how it is set here, please tell us the cluster default
as well as any namespace label, because the label alone would mislead us.

**Please do not put `limits.cpu` in the quota.** A `ResourceQuota` that names a resource
makes Kubernetes refuse any pod with a container — init containers included — that
does not declare it. Our charts set CPU **requests** but no CPU **limits**, so a quota
with `limits.cpu` refuses every validator pod at admission (`failed quota: must specify
limits.cpu`). We found this by testing against a namespace configured that way. If your
standard quota template includes `limits.cpu`, tell us and we will discuss it rather than
quietly add limits.

**What breaks without it:** at `restricted`, every validator pod is refused before it
starts; a quota with `limits.cpu` refuses them too; a quota below the table makes the
fourth validator unschedulable — and QBFT with three of four is one failure from a halt.

### 28. A dedicated, tainted node group for the ledger — Tier 2, and it matters

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

### 30. Cluster add-ons we depend on — please tell us which exist

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

### 31. Pod identity mechanism — IRSA or EKS Pod Identity

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
(§6).

### 32. Cluster access for our In-VPC EC2 Runner — namespace-scoped

Our In-VPC EC2 Runner applies Helm releases and runs the
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
the grant *cannot* reach outside our namespaces (§6).

### 33. Node security group — admit our load balancers, or enable Security Groups for Pods

Our two internal NLBs target **pod IPs**, so traffic arrives at the **node** security
group, which is yours. Either:

- add an ingress rule on the node SG permitting **TCP 8545–8546 from our NLB security
  groups** (we will send the IDs), or
- enable **Security Groups for Pods** (`ENABLE_POD_ENI`) so we attach our own SG to the
  RPC pods and you touch nothing.

Also needed: the **node security group ID** and the **node IAM role ARN** (for #38).

**What breaks without it:** the NLB health checks never pass, and SWIFT's endpoint is
unreachable — with no error anywhere, just `unhealthy` targets.

### 34. Network flows through your subnet rules

You define the rules on each subnet; our pods sit in your application subnets, one per
AZ. Validators are deliberately spread across all three AZs, so **every
validator-to-validator connection crosses a subnet boundary** and meets your rules.
Please confirm these flows are permitted — or send us the rules (§4) and we will check
ourselves:

| # | Flow | Port / protocol | From → To |
|---|---|---|---|
| F-1 | Validator/bootnode peer-to-peer | **30303 TCP and UDP** | application subnet ↔ application subnet, all AZs |
| F-2 | RPC via our NLBs (IP targets) + their TCP health checks | 8545, 8546 TCP | load-balancer subnet → application subnet |
| F-3 | Return path for F-2 — **only if the rules are stateless (NACLs)** | 1024–65535 TCP | application subnet → load-balancer subnet |
| F-4 | Metrics scrape | 9545 TCP | your Prometheus → application subnet (or intra-namespace) |
| F-5 | AWS APIs via interface endpoints | 443 TCP | application and In-VPC EC2 Runner subnets → endpoint subnet (+ return if stateless) |
| F-6 | S3 gateway — image layers, Terraform state, our tool bundle | 443 TCP | application and In-VPC EC2 Runner subnets → **the S3 prefix list** (a NACL cannot reference it; the rule must cover S3's regional ranges) |
| F-7 | In-VPC EC2 Runner → cluster API | 443 TCP | its subnet → the control-plane ENIs' subnets |
| F-8 | In-VPC EC2 Runner → egress proxy VIP | the proxy port | its subnet → the egress prefix (R-10), **+ return if stateless**: 1024–65535 TCP from the egress prefix back to its subnet |
| F-9 | Explorer database | 5432 TCP | intra-namespace, or application → data subnet (#37) |
| F-10 | DNS | 53 UDP/TCP | to the VPC resolver. Listed for completeness: network ACLs do not apply to the Amazon-provided resolver, so there is probably nothing to do — but if pods resolve through anything else, it needs a rule |

And three placement facts: **which subnet(s) your node group uses**, **which
load-balancer subnets** we may place NLBs in, and **which subnet** our In-VPC EC2 Runner
should use.

*(This table is the single source of truth for the flow list: our preflight check and
our design record both cite `#34 F-n` rather than restating it.)*

**The table lists only our flows. The cluster's own flows must keep working too** in
whatever rules apply to the subnets you place us in. They are yours, and on a cluster
you already run they work today; we state them because a NACL written for one tenant's
subnet can remove them, and nothing we deploy could then tell why. In our own test
environment, with NACLs limited to the table above, a node in the one AZ without a
control-plane interface **never joined the cluster**:

| # | Flow | Port / protocol | Between |
|---|---|---|---|
| C-1 | Nodes → cluster API (control-plane ENIs) | 443 TCP | every node subnet → every subnet holding a control-plane ENI, **across AZs** |
| C-2 | Pods → CoreDNS | 53 UDP **and** TCP | node subnet ↔ node subnet, **across AZs** (CoreDNS replicas sit on some nodes, not all) |
| C-3 | Control plane → kubelet, and to webhook / metrics-server pods | 10250 and the webhook ports, TCP | control-plane ENI subnets → node subnets |
| C-4 | Pod ↔ pod, node ↔ node (CNI, kube-proxy) | as your CNI requires | node subnet ↔ node subnet |

*(Our checker cites these as `#34 C-n`, as it does `#34 F-n` for the table above.)*

If the rules are NACLs this adds rules to the count in point 1 below.

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

### 35. `NetworkPolicy` enforcement in the CNI

With shared nodes, Kubernetes `NetworkPolicy` is our primary tenant boundary. Please
confirm the cluster enforces it — VPC CNI with network policy enabled, or Calico /
Cilium. On current VPC CNI versions the setting is the add-on configuration
`enableNetworkPolicy: "true"`, and it shows as the argument
`--enable-network-policy=true` on the **`aws-eks-nodeagent`** container of the
`aws-node` DaemonSet — not as an environment variable on the `aws-node` container
(command 2 in §4 prints both).

**What breaks without it:** our default-deny policies are accepted by the API and
enforced by nothing; every pod in the cluster can reach the validators' privileged RPC.

### 36. Kubernetes version and upgrade cadence

The current version, the planned upgrade cadence, and the notice period (#29 item 3).
Hyperledger Besu's chart and our operator tooling are validated per Kubernetes minor;
we need to run that validation **before** your upgrade, on your schedule.

### 37. Placement policy for the explorer database

Blockscout (the block explorer, internal-only) runs a small PostgreSQL. Today it is a
StatefulSet in the namespace. If your policy is that **databases live in the data
subnets**, tell us and we move it to RDS there, with F-9 as an application → data rule.
Either is fine; it is the lowest-stakes item in this document.

### 38. ECR pull for your cluster's node role (re-scopes #25)

Images are pulled by **your** nodes now. The repository policies on our ECR
repositories (central shared-services account, §7) must grant pull to **your node
group's IAM role** — send us its ARN (#33) and we add it, or add it yourselves if the
repositories are managed centrally.

Two halves, and the second is easy to miss: a repository policy grants the *resource*
side, but the node role still needs **`ecr:GetAuthorizationToken`** in its own identity
policy, which no repository policy can grant. The managed `AmazonEC2ContainerRegistryReadOnly`
policy includes it; a hardened policy scoped to your own registry account will refuse ours.
Please confirm which the node role carries.

**What breaks without it:** `ImagePullBackOff` on every pod, against a registry that
looks fully populated. Our own `verify-images.sh` **cannot catch this** — it authenticates
as our In-VPC EC2 Runner, not as your node role, so it passes either way. We close
that gap with a canary pull from inside our namespace (§6).

### 39. IP headroom in the subnets we are scheduled into

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
* **1 address** for our In-VPC EC2 Runner, in whichever subnet you prefer for it.

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

---

## 4. What we need you to send — five commands, then a few questions

Most of §3, and the endpoint check in §7, are answered by pasting five outputs. We ask for these rather than
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
kubectl -n kube-system get ds aws-node -o jsonpath='{.spec.template.spec.containers[?(@.name=="aws-eks-nodeagent")].args}' | tr ',' '\n' | grep -i 'enable-network-policy'
aws eks describe-addon --cluster-name <cluster> --addon-name vpc-cni --region af-south-1 --query 'addon.{version:addonVersion,config:configurationValues}'
kubectl get deploy -A -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl get storageclass <class> -o jsonpath='{.volumeBindingMode}{" "}{.allowVolumeExpansion}{" "}{.parameters.kmsKeyId}{"\n"}'

# 3 — the subnet rules our flows must pass (#34)
aws ec2 describe-network-acls   --region af-south-1 --filters Name=association.subnet-id,Values=<node,lb,data subnet ids>
aws ec2 describe-security-groups --region af-south-1 --group-ids <node sg id>

# 4 — free addresses in the subnets we would land in (#39)
aws ec2 describe-subnets --region af-south-1 --subnet-ids <node,lb,runner subnet ids> \
    --query 'Subnets[].{subnet:SubnetId,az:AvailabilityZoneId,cidr:CidrBlock,free:AvailableIpAddressCount}'

# 5 — the VPC endpoints that exist (§7)
aws ec2 describe-vpc-endpoints --region af-south-1 --filters Name=vpc-id,Values=<vpc id> \
    --query 'VpcEndpoints[].{service:ServiceName,type:VpcEndpointType,privateDns:PrivateDnsEnabled,state:State}'
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

---

## 5. Shared responsibility

| Resource | Cloud Platform Team | Ledger Platform Team |
|---|---|---|
| EKS cluster, node groups, Kubernetes upgrades, addons, CRDs, StorageClasses, cluster RBAC | **Own** | Consume; assert via preflight |
| Node rotation on ledger nodes | **Own the tooling, honour #29** | Provide the health check; attend the window |
| Namespaces, quotas, PSA labels, access entries | **Own** (#27, #32) | Request; verify |
| Node security group rule for our NLBs, or SGP | **Own** (#33) | Send NLB SG IDs |
| Subnet rules for F-1..F-9 | **Own** (#34) | Verify by preflight; cite the flow number on failure |
| Free addresses in the node / LB / instance subnets | **Own the sizing** (#39) | State our footprint; verify the margin before deploying |
| Everything inside our namespaces; NLBs, KMS, Secrets Manager, IAM roles, SNS/SQS, S3, the In-VPC EC2 Runner | — | **Own** |
| ECR repository policies for your node role (#38) | Add, if repositories are centrally managed | Request; verify from the runner |
| ~~Interface endpoints, gateway endpoints, route tables, NACL rules, flow logs~~ | **Own — all of it, now without qualification** | Verify only |

---

## 6. How we will prove it works before we spend anything

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
| **#27** quota | The worst case in this document, because **it looks like success.** A quota a few hundred millicores short admits three validators and refuses the fourth. QBFT's quorum is 3 of 4, so the chain starts, produces blocks and reports healthy — with **zero** fault tolerance. The refusal is an event on the StatefulSet; there is no fourth pod to notice | `hard` minus `used` against the §1 table, pre-deploy. Then a post-deploy gate that fails unless `qbft_getValidatorsByBlockNumber` returns **four** and every one is `Ready` |
| **#28** | Our spread constraints are `whenUnsatisfiable: ScheduleAnyway` — deliberate, so scheduling never blocks. On a busy cluster that lets two validators land on one node, silently; one drain then removes two of four and halts the chain | Ours to fix: the hostname constraint for validators becomes `DoNotSchedule`, so the failure is a `Pending` pod we can see rather than a co-location we find during an incident. Plus a post-deploy gate asserting four distinct node names |
| **#29** | **No check exists** — see below |
| **#30** CRD vs controller | A CRD proves only that something once installed it. If the controller is not running or not reconciling, our `TargetGroupBinding` is accepted and simply sits there: no targets register, the NLB stays empty, nothing errors | Assert the CRD **and** a ready controller, pre-deploy. Then assert real target registration post-deploy — `describe-target-health` must return four healthy targets, not an empty list |
| **#30** controller IAM | Our target groups are created by our own Terraform, so they do not carry the `elbv2.k8s.aws/cluster` tag that a hardened load-balancer-controller policy is often conditioned on. The controller then fails `RegisterTargets` with `AccessDenied` **into its own log, in a namespace our scoped access cannot read.** From our side: a healthy-looking binding and an empty target group, indefinitely | Question I in §4 asks for the policy so we can check the condition before we build. The target-health gate above catches it afterwards whatever the cause |
| **#30** StorageClass | `volumeBindingMode: Immediate` provisions the volume *before* the pod is scheduled, pinning it to an arbitrary AZ — with validators spread across three, one can end up permanently `Pending` with its data in the wrong zone. `allowVolumeExpansion: false` is invisible until the chain fills the disk, by which time it is an incident rather than a change | Assert both fields on the class, pre-deploy |
| **#31** | The one with a security consequence. If we build for Pod Identity and the cluster uses IRSA — or nothing is wired for our service account — no credential variables are injected, the AWS SDK falls through to instance metadata, and the pod runs **as your node role**. On a shared cluster that role is likely broader than ours, so the call may well *succeed*: wrong principal, your CloudTrail, not ours | `aws sts get-caller-identity` from inside one of our pods at startup; fail unless the ARN is the role we expect. Also ours to get right: our IRSA trust policies must condition on `sub = system:serviceaccount:<our-ns>:<sa>` **and** `aud = sts.amazonaws.com`, or any pod in any namespace of your cluster could assume them. A static check fails our plan if either condition is missing |
| **#32** | Two directions. **Too narrow** is loud (`Forbidden`) but blocks a deployment: `AmazonEKSEditPolicy` follows the built-in `edit` role, which enumerates built-in kinds, so the four custom resources we create are covered only if an add-on ships a ClusterRole labelled `aggregate-to-edit` — not guaranteed. **Too broad is the silent one:** a cluster-wide grant works exactly as well as a scoped one, so nothing ever tells us the boundary is absent | `kubectl auth can-i` as the worker's role, asserting the positives (create those four kinds in our namespaces) **and the negatives** (`create pods -n kube-system` must return `no`). Pre-deploy |
| **#33** | The health checks fail, targets read `unhealthy` with `Target.FailedHealthChecks`, and nothing names a security group. If Security Groups for Pods is the chosen route instead and the `SecurityGroupPolicy` selector does not match our pods, they get an ordinary node ENI — our security group is simply not applied, with no error at all | Pre-deploy: evaluate the node SG for 8545–8546 from our NLB security groups. Post-deploy: assert the `vpc.amazonaws.com/pod-eni` annotation on the RPC pods when SGP is the route, and four healthy targets |
| **#34** | Silent by construction — this class is why the document exists. F-1 blocked gives a peer count of zero and no block ever produced; F-6 blocked stalls an image pull mid-layer; F-5 blocked makes every AWS call hang until timeout. **One partial case worth naming:** if 30303/TCP is permitted and 30303/**UDP** is not, our statically-configured peers still connect and the chain runs — discovery is dead and we would not find out until it mattered | A preflight evaluates the rules you send (§4 command 3) against F-1..F-10 **before anything is created**, testing each protocol separately, and names the flow: `#34 F-1 BLOCKED: NACL <id> entry <n> denies 30303/udp from <cidr>`. Post-deploy, peer count must be 3 on every validator |
| **#35** | The API server accepts `NetworkPolicy` objects whether or not anything enforces them. A default-deny policy that enforces nothing is indistinguishable from one that works | Read the `aws-node` configuration (§4 command 2), then **prove** it: a two-pod probe in our own namespace, one connection that policy forbids, asserting it is actually refused. Configuration is evidence; a refused connection is proof |
| **#36** | Silent in the direction that matters. Your upgrade breaks nothing at the moment it lands; it breaks the next time we apply, when a removed API version stops a chart reconciling | The cluster contract pins a **tested version range** and fails our plan when the live version is above it — an upper bound, not just a minimum. The first apply after your upgrade stops with `#36: cluster is 1.37, validated to 1.36; run the compatibility pass first` |
| **#37** | Loud enough: if Postgres moves to a data subnet and F-9 is not open, Blockscout logs connection timeouts | Covered by the F-9 row of the #34 check |
| **#38** | **The gap is in our own checking, and we would rather say so.** `verify-images.sh` authenticates with *our* credentials, so it proves our In-VPC EC2 Runner can pull — not that your node role can. Different principals, different policies, and the check passes either way | Three parts: assert your node role ARN appears in each repository policy with `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`, `ecr:BatchCheckLayerAvailability`; confirm the node role's **identity** policy allows `ecr:GetAuthorizationToken` (a repository policy cannot grant it, and a policy scoped to your own registry account will refuse ours); and the only real proof — a **canary pod** in our namespace pulling one small image from our registry, before anything expensive is built |
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

## 7. Earlier requirements that still stand

These come from our 2026-08-29 document and its 2026-09-04 ECR addendum. Under the
shared cluster most of those were withdrawn (§2); these were not. Each is a setting you
already own — we are asking you to **confirm** it, not to change anything, and we check
every one of them read-only from inside the VPC before we build.

**A missing piece here does not give a clean error.** The VPC has no route out, so a call
that goes the wrong way hangs until it times out, and an image pull shows up as a generic
`ImagePullBackOff` that names neither the registry nor the cause.

### 1. VPC `instance_tenancy` must be `default`

If the VPC was created with `instance_tenancy = dedicated`, every instance launched into
it is forced onto dedicated tenancy, and that **cannot be changed on an existing VPC**.
It affects our In-VPC EC2 Runner, and your nodes as well.

### 2. `enableDnsSupport` **and** `enableDnsHostnames` must both be true

VPC endpoints work through **Private DNS**, which needs both attributes. Without them every
AWS call resolves to a public address that has no route out — node bootstrap, IAM role
assumption, KMS decryption of validator keys and secret retrieval all hang.

### 3. The DHCP option set must resolve AWS endpoint Private DNS

If the DHCP option set points only at on-premises DNS servers, Private DNS stops working
unless those servers forward the AWS service domains to the Amazon resolver (the VPC base
address + 2). This is the most common failure in an air-gapped enterprise VPC. #22 is the
ECR-specific form of the same requirement.

### 5. Our pods spread across three AZs, identified by AZ ID

QBFT needs our 4 validators spread across 3 AZs so that losing one zone does not halt the
chain. The node group our pods land on (#28) must span all three AZs — `afs1-az1`,
`afs1-az2`, `afs1-az3`. We use **AZ IDs**, not AZ names, because names map to different
physical zones in different accounts.

### 6. We create and manage our own security groups

We need to create security groups for our load balancers and, if you enable Security
Groups for Pods (#33), for our RPC pods. Security-group changes are part of routine ledger
operations, so they cannot route through an external change queue.

### 20. The S3 gateway endpoint policy must allow the ECR layer bucket

ECR serves image **manifests** over the `ecr.dkr` endpoint, but the **layers** — the actual
bytes — come from an AWS-managed S3 bucket. If the S3 gateway endpoint policy is scoped to
bank-owned buckets, every image pull fails **part-way through the layer download**, which
looks like a network error rather than an access-denied. Minimum addition:

```json
{
  "Sid": "AllowEcrLayerRetrieval",
  "Effect": "Allow",
  "Principal": "*",
  "Action": "s3:GetObject",
  "Resource": "arn:aws:s3:::prod-af-south-1-starport-layer-bucket/*"
}
```

### 22. Private DNS must be enabled on the `ecr.api` and `ecr.dkr` endpoints

ECR endpoints support only AWS-provided DNS, and `ecr.dkr` requires Private DNS. Without it
the ECR hostnames resolve to public addresses this VPC cannot reach, and every pull hangs.

### 23. The ECR endpoint policy must not be scoped to a single AWS account

The EKS managed addons (`vpc-cni`, `coredns`, `kube-proxy`) pull **cross-account** from
AWS's own registry. In af-south-1 that is account **`877085696533`** — not the
widely-quoted `602401143452`, which serves us-east-1 and most other regions. Our own images
come from your shared-services account. A policy restricted to one account breaks one or
the other. Two things to check on the policy you already have:

| Check | Why |
|---|---|
| It allows **`ecr:GetAuthorizationToken` with `Resource: "*"`** | It is a registry-level action with no resource-level permissions. Scoped to repository ARNs, authentication fails before any pull is attempted — and reads as a credentials problem |
| It does **not** restrict `Resource` to one account's repositories | Breaks the addon pulls, or ours |

If the policy is full-access, both hold already and there is nothing to do.

### The VPC endpoints we depend on

The endpoints are yours. Please confirm these exist in the VPC, with **Private DNS on** for
the interface endpoints — command 5 in §4 answers it:

- **Interface:** `ssm`, `ssmmessages`, `ec2messages`, `ecr.api`, `ecr.dkr`, `ec2`, `sts`,
  `eks`, `elasticloadbalancing`, `kms`, `secretsmanager`, `logs`, `monitoring`, `sns`, `sqs`
- **Gateway (free):** `s3` — and `dynamodb` for the event pipeline's cursor table
- **`eks-auth`** — only if the cluster uses EKS Pod Identity (#31)

**The three SSM endpoints matter most.** Our In-VPC EC2 Runner has no SSH and no public IP;
Session Manager is the only way in. Without `ssm`, `ssmmessages` and `ec2messages` we cannot
reach it, and nothing can be deployed. `sns` and `sqs` carry our event pipeline (SWIFT
actions delivered to bank systems).

### Our ECR repositories

**Settled — thank you:** the registry is ECR in your central shared-services account, in
af-south-1, with tag immutability on and no lifecycle expiry (#18, #25). It is already our
only image source: our CI mirror copies every third-party image and chart in from outside
the VPC, and nothing inside the VPC pulls from anywhere else.

**Still open:** we cannot create repositories in an account we do not own. We need roughly
28 (our mirrored images plus a Helm chart namespace). Please tell us:

- the **name prefix** our repositories should sit under, and
- whether you **create them on request**, or give us a **role that can create them under
  that prefix**. We would prefer the role, so mirroring a new upstream version is not a
  ticket each time.

The pull grant for your node role is #38.

---

## 8. Still open from our 2026-09-09 follow-up

These concern the AWS account and our build and deployment pipeline rather than the
cluster. The full wording is in that note; they are summarised here so this document is
the complete list. **One correction first:** that note asks for ECR pull rights for *our*
node role — under the shared cluster it is *your* node role that pulls, so **#38 replaces
that request.** It also calls our In-VPC EC2 Runner the *administrative instance* — same
machine, new name.

| Ask | What we need | Priority |
|---|---|---|
| **R-10** — egress for our deployment agent | (1) the **proxy address**, `host:port`, as seen from the ledger VPC; (2) a **source allowlist** entry for our In-VPC EC2 Runner's fixed private IP (a /32 — we will send it), or its subnet /24; (3) **destinations** `<instance>.octopus.app` and `polling.<instance>.octopus.app`, port 443, `CONNECT` only, outbound only; (4) **no TLS decryption** on those two — the Octopus agent pins certificates on both ends and needs an uninterrupted TLS tunnel; (5) a **route** from the In-VPC EC2 Runner's subnet to the proxy's prefix over the Transit Gateway — never a default route; (6) whether the proxy **requires credentials**; (7) **an explicit subnet CIDR reservation on that /32** in the In-VPC EC2 Runner's subnet (`create-subnet-cidr-reservation --reservation-type explicit`). Your cluster's nodes share that subnet, and the VPC CNI keeps a warm pool of addresses drawn from it at random. In our test it took the runner's address, and EC2 refused to launch the runner. With the reservation, AWS gives the address out only on explicit request, which is how we launch the runner. It costs nothing and changes no rule. We are **not** asking for general internet access, an Internet Gateway, a public cluster endpoint, any inbound rule, or how the egress is built | **High** |
| **R-3** — account rules | A dedicated IAM path or role-name prefix for our roles; any **mandatory permissions boundary**; **Service Control Policies** that would deny creating KMS keys, IAM roles or specific instance types (an SCP denial is invisible until an apply fails mid-way); a **mandatory tag set**; **service quotas** we share with other tenants; **CloudTrail read access** for our resources — we audit every KMS decrypt of a validator key | High |
| **R-6** — the VPC endpoints | Covered in §7: **SSM trio first**, plus `ec2:DescribeVpcEndpoints` for our read-only check and notice before any endpoint-policy change | High |
| **R-7** — CI runner identity | How your runners get AWS credentials — **GitHub OIDC, IRSA, or an instance profile** (it changes our workflow code, not just a setting); **ECR push** rights for that identity under our prefix; which **runner labels** to target; whether GitHub-hosted runners may be used for jobs that handle only public artefacts | High |
| **R-5b** — ECR repositories | Covered in §7: the prefix, and create-on-request or a scoped role | Medium |
| **R-2b** — the runners' internet path | Direct or through a forward proxy (and if so, host and port); **does it decrypt TLS?** — `crane`, `helm` and `curl` reject an unknown CA, so we would need its CA bundle; do you have **Docker Hub credentials** for CI (anonymous pulls are rate-limited per source IP, shared by every team on your runners) | Medium |
| **R-8** — Octopus | Is our namespace **our own Space** or a project group in a shared one (we need a service account that can deploy to SIT but not PROD); a **worker pool** with AWS credentials for Terraform steps; is the central ECR registered in Octopus as a **Docker feed** | Medium |

---

## 9. Event pipeline — questions for you, or for the team you point us to

When something happens on the ledger (for example, a payment is recorded), we pick up that
event and deliver it to the bank's own systems through SNS and SQS. Before we build the
last step — handing the message to the bank system — we need the answers below. Some of
these are not yours to answer; if so, please tell us who owns them.

None of this blocks building the rest of the platform. We need it before we build the
hand-off.

| # | Question | Why we ask |
|---|---|---|
| EQ-1 | When we reply to SWIFT, do we send the reply back over SIPN ourselves, or do we hand it to the bank's own SWIFT gateway (Alliance Access) inside the network? | We have assumed the bank's gateway sends it. If we must send to SWIFT ourselves, we need an outbound network path to SIPN — much more work |
| EQ-2 | How does the receiving bank system accept messages — IBM MQ, HTTP (with mTLS), Kafka, or something else? | This decides how we build the hand-off. See the four questions below |
| EQ-3 | How many messages per day, and how many per second at peak? | We have sized for hundreds to low thousands per day. Much higher volume may change the design |
| EQ-4 | Is it enough to keep messages in order per payment, or does any system need every message in one single order? | One single order forces everything through one lane and slows the whole pipeline |
| EQ-5 | Does the bank already run Kafka? | If yes, we would deliver to it directly instead of building on SQS — simpler and cheaper |
| EQ-6 | Is there an approved place inside the network to get Java (Maven) or other software packages — for example AWS CodeArtifact or an internal repository? | ECR holds container images only, not software packages. We need this only if EQ-2 forces a Java client (for example IBM MQ's Java library) |
| EQ-7 | Can a single message ever be larger than 256 KB (for example a full ISO 20022 message)? | SQS limits messages to 256 KB. Larger ones must be stored in S3 with a pointer in the message, and we would build that from day one |

**Four questions for the team that owns the receiving system**, whatever it uses:

1. **When is a message safely stored on your side?** We delete our copy only after that
   point — not when your system has merely received it. Otherwise a crash on your side
   loses a payment we can no longer resend.
2. **How do you handle duplicates?** To make sure nothing is lost, we retry, so you will
   sometimes receive the same message twice. Every message carries a unique ID. Which field
   will you check, and what do you do with a repeat?
3. **Do you need messages for the same payment kept in order, and can your side keep that
   order?** We deliver them in order; it can still be lost inside your system.
4. **Who owns the queue or endpoint on your side, its credentials, and their renewal?**

**If the answer is IBM MQ:** we would prefer to connect over **AMQP 1.0** or the **MQ REST
API** rather than IBM's standard client. The standard client needs a licensed IBM download
that we cannot mirror into ECR. Please tell us whether either option is enabled on the queue
manager.

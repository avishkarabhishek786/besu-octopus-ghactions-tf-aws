# Besu Ledger Platform — requests to the Cloud Platform Team
## Container registry, supply chain, and CI/CD

**Date:** 2026-09-07 · **From:** Ledger Platform Team · **Region:** af-south-1
**Companion to:** the network requirements document already sent (requirements #1–#19).
This document covers requirements **#20, #22–#26** and CI/CD questions **CQ-1–CQ-8**, and
**withdraws three earlier requirements (#8, #19 and #21)**.

> ## ⚠ STATUS — partly superseded, 2026-09-09
>
> This document was **sent, and answered on a call of 2026-09-09**. Four items
> are now settled and three are withdrawn as a result. **Do not re-send this
> document** — send `CLOUD_TEAM_FOLLOWUP_2026-09-09.md`, which records the
> answers and carries the seven remaining questions (R-1..R-8).
>
> | Item | Status |
> |---|---|
> | **#24** — who owns the VPC | **ANSWERED**: shared VPC, we are a tenant, the account is theirs. *Still open: one account or two — R-3.* |
> | **#25** — ECR topology | **ANSWERED: (b)**, a central shared-services account. #23 is therefore **mandatory**. New follow-ups R-4 (region) and R-5 (namespace, immutability, lifecycle). |
> | **CQ-2** — runners | **ANSWERED**: they have self-hosted runners and asked us not to stand one up. **#26 below is superseded** — GitHub-hosted runners are no longer the plan. New follow-ups R-2 (egress) and R-7 (AWS identity). |
> | **CQ-1** — Octopus | **PARTLY ANSWERED**: "a dedicated server in their account, cloud-hosted" — which reads both as self-hosted-on-AWS and as Octopus Cloud. **Still blocking — R-1.** |
> | **#13, #14** | **WITHDRAWN** — not a tenant's to manage. Security groups and ENI-level flow logs instead. |
> | **#26** | **WITHDRAWN as a request** — no longer asking for GitHub-hosted runners or an OIDC provider. |
> | **#20, #22, #23** | **Unchanged and still required.** #23 was advisory under #25a; under #25b it is mandatory. |
> | **#4** | Possibly withdrawable — the load balancer controller accepts explicit subnet IDs. Verifying. |

---

## 0. How to read this

We are deploying a permissioned Hyperledger Besu ledger onto two EKS clusters in the
shared VPC you provide. The VPC has **private subnets only, no Internet Gateway and no
NAT**, and the EKS API endpoints are **private**. We are not asking you to change any of
that — the whole design assumes the air-gap holds.

What we need falls into three groups:

- **Section A — Registry (#20–#26).** Mostly VPC endpoint *policy* settings. Every item
  is zero-cost, and every one of them, unmet, stops **all** container image pulls in both
  clusters.
- **Section B — CI/CD (CQ-1–CQ-8).** Mostly questions about Octopus Deploy: where the
  server lives, how we get a scoped service account, and one deployment gate that must be
  un-bypassable. Only **CQ-1** is blocking.
- **Section C — what we are NOT asking for**, and **Section D — what we are withdrawing.**

**Sections 1 and 2 explain two things that are commonly mis-assumed.** They are short and
we would ask that they be read before Section A, because each one, mis-assumed, leads to a
solution that is more work than what we are actually asking for.

---

## 1. Important: our pipeline does NOT need egress from the VPC

**Amazon ECR has public service endpoints.** A build machine with internet access and IAM
credentials can **push** images to ECR from anywhere — it does not need to be inside the
VPC, peered to it, or attached to the Transit Gateway.

The `ecr.api` and `ecr.dkr` **interface endpoints exist for the other direction**: so that
workloads *inside* the no-egress VPC can **pull** without any internet route.
They're the two AWS PrivateLink (VPC interface endpoint) service names for Amazon ECR. You create them when instances, ECS tasks, or EKS pods in private subnets need to reach ECR without going out through a NAT gateway or internet gateway.

com.amazonaws.<region>.ecr.api — the ECR control plane. This handles the AWS API calls made by the CLI/SDK: GetAuthorizationToken, DescribeRepositories, CreateRepository, BatchGetImage, InitiateLayerUpload, and so on. Anything you'd do with aws ecr ....

com.amazonaws.<region>.ecr.dkr — the Docker Registry HTTP API V2 endpoint. This is what the Docker daemon, containerd, or kubelet talks to when you run docker push / docker pull against an ECR registry.

```
   CI runner (has internet)                    The shared VPC (NO egress)
   ┌──────────────────────┐                    ┌──────────────────────────┐
   │ pull from docker.io, │                    │  EKS nodes               │
   │ ghcr.io, quay.io,    │                    │      │ pull              │
   │ registry.k8s.io      │                    │      ▼                   │
   │          │           │                    │  ecr.api / ecr.dkr       │
   └──────────┼───────────┘                    │  interface endpoints     │
              │ push (public ECR endpoint)     └──────────┬───────────────┘
              └──────────────►  Amazon ECR  ◄─────────────┘
```

**Why this matters to you:** if a request to "let the pipeline reach the registry" arrives
in your queue, the correct answer is **not** to add NAT, an Internet Gateway, or an egress
proxy. Nothing inside the VPC ever contacts a public registry. Push happens outside; pull
happens over endpoints you already provide.

**This is the fact that lets us keep the air-gap and still have a working supply chain.**

---

## 2. Important: ECR is a registry, not a proxy

Some artefact repositories fetch from upstream on demand. **ECR does not.** It serves only
what has been deliberately pushed into it.

ECR's proxy-equivalent feature is **pull-through cache**, and it **cannot be used in this
VPC**. AWS documents that the *first* pull through a pull-through cache rule requires a
route to the internet when ECR is reached via an interface endpoint — which this VPC does
not have, by design.

**Consequence:** our supply chain is an **explicit mirror pipeline**, not an on-demand
cache. Third-party images and Helm charts are copied into ECR deliberately, from outside
the VPC, and someone owns that pipeline for the life of the platform. We are content to
own it — and for a payment system we think a deliberate, logged, scannable promotion step
is the better posture than fetching from the internet on demand. But it is a standing
commitment rather than a one-off configuration, and we would rather agree it now than
discover the mismatch during a deployment.

**If anyone is expecting "ECR will just cache Docker Hub for us" — it will not, here.**

---

## Section A — Registry requirements (#20–#26)

All are **Tier 1** (the platform does not function without them) and all are **zero-cost**.

A note on how these fail, which is why we are being this explicit: in a VPC with no
egress, a blocked or misrouted pull **does not return an error**. The connection has
nowhere to go, so it **hangs until timeout** and surfaces as a generic
`ImagePullBackOff` that names neither the registry nor the cause. These are expensive to
diagnose and trivial to prevent.

### #20 — The S3 gateway endpoint policy must allow the ECR layer bucket

**What we need**

The S3 gateway endpoint policy must permit `s3:GetObject` on:

```
arn:aws:s3:::prod-af-south-1-starport-layer-bucket/*
```

Minimum statement to add:

```json
{
  "Sid": "AllowEcrLayerRetrieval",
  "Effect": "Allow",
  "Principal": "*",
  "Action": "s3:GetObject",
  "Resource": "arn:aws:s3:::prod-af-south-1-starport-layer-bucket/*"
}
```

**Why**

ECR serves image **manifests** over the `ecr.dkr` endpoint, but the image **layers** — the
actual bytes of every container image — are served from an **AWS-managed S3 bucket**. This
is documented AWS behaviour, not a quirk of our design.

**What happens if we don't get it**

Every image pull fails **partway through the layer download**. It does not present as an
access-denied error; it presents as an intermittent network failure mid-pull. Nothing
starts: not our workloads, and not the EKS managed addons.

**Note:** this requirement already applies today for the AWS-managed EKS addon images. Our
move to ECR makes it total rather than partial. If the S3 gateway endpoint currently
carries a least-privilege policy scoped to bank-owned buckets — an entirely reasonable
landing-zone default — this will need adding.

### #22 — Private DNS must be enabled on the `ecr.api` and `ecr.dkr` endpoints

**What we need**

1. **Private DNS enabled** on both ECR interface endpoints.
2. The VPC must resolve AWS service names via **AWS-provided DNS** (the Amazon resolver at
   VPC base + 2) — either directly, or via **conditional forwarding** from your resolvers
   for the AWS service domains.

**Why**

AWS documents that ECR VPC endpoints support **only** AWS-provided DNS through Route 53,
and that the `ecr.dkr` endpoint requires Private DNS to be enabled. Without it, the ECR
service hostnames resolve to **public** addresses, which this VPC has no route to.

**What happens if we don't get it**

Identical symptom to #20 — every pull hangs. This is, in our experience, the single most
common failure mode in an enterprise air-gapped VPC, because a DHCP option set pointing at
on-premises DNS servers is a perfectly normal configuration that silently breaks endpoint
resolution.

This is the ECR-specific form of requirement **#3**, which we sent previously.

### #23 — Scope the ECR endpoint policy by PRINCIPAL, not by resource account

**What we need**

A restrictive endpoint policy is welcome — we are asking for the *right* restriction, not
the absence of one. The distinction that matters:

| Dimension | Scope it? | Why |
|---|---|---|
| **`Principal`** | **Yes — this is the strong control** | Every pull through this endpoint is made by *our* IAM roles (EKS node roles and our In-VPC EC2 Runner role). Restricting to them limits the blast radius to exactly what we run. |
| **`Action`** | **Yes** | Only four read actions are ever needed. |
| **`Resource`** | **Careful — do NOT scope to our account alone** | The EKS managed addon images live in an **AWS-owned account**, not ours. A `Resource` limited to our repositories denies them. |

**Why `Resource` is the trap**

The EKS managed addons — `vpc-cni`, `coredns`, `kube-proxy` — are pulled **by our node
role** but **from AWS's own registry**. For af-south-1 that is:

```
877085696533.dkr.ecr.af-south-1.amazonaws.com
```

> **This account ID is region-specific.** af-south-1 is **`877085696533`** — **not** the
> widely-quoted `602401143452`, which serves us-east-1, eu-west-1 and most other regions.
> A policy written with the common value fails in af-south-1 exactly as if no policy
> allowed the pull at all. AWS publishes the per-region table under *"View Amazon container
> image registries for Amazon EKS add-ons"*.

So the principal is ours; the resource is not. Scope by the former.

**A second, easily-missed detail**

`ecr:GetAuthorizationToken` is a **registry-level** action — it does not support
resource-level permissions and its resource is always `*`. If it is folded into a
statement whose `Resource` lists only repository ARNs, **authentication fails before any
pull is attempted**, which reads as a credentials problem rather than a policy one. It
needs its own statement.

**A policy that satisfies both**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AuthTokenIsRegistryLevel",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*",
      "Condition": {
        "StringEquals": { "aws:PrincipalAccount": "<our-workload-account-id>" }
      }
    },
    {
      "Sid": "PullOurImagesAndTheEksAddonImages",
      "Effect": "Allow",
      "Principal": "*",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": [
        "arn:aws:ecr:af-south-1:<our-workload-account-id>:repository/*",
        "arn:aws:ecr:af-south-1:877085696533:repository/*"
      ],
      "Condition": {
        "StringEquals": { "aws:PrincipalAccount": "<our-workload-account-id>" }
      }
    }
  ]
}
```

The `aws:PrincipalAccount` condition does the real work: only principals from our account
can use the endpoint at all. We suggest it in preference to enumerating role ARNs, which
change as node groups are replaced and then quietly drift out of date. `aws:PrincipalOrgID`
is equally acceptable if that fits your standards better.

**If the registry ends up in a shared-services account (#25b)**, add that account's
repository ARN to the `Resource` list as well.

**Simplest acceptable alternative:** condition on `aws:PrincipalAccount` with
`"Resource": "*"`. That is still a genuine restriction — the endpoint is unusable to
anyone outside our account — and it removes the region-specific account ID from the policy
entirely, which is one fewer thing to get wrong.

**What happens if we don't get it**

`vpc-cni`, `coredns` and `kube-proxy` fail to start and the cluster never becomes ready.
The failure looks like a broken cluster rather than a policy problem, so it is diagnosed
slowly and expensively.

### #24 — Which AWS account OWNS the VPC?

**What we need**

The AWS account ID that owns the VPC and subnets — and specifically, whether they are
shared into our account with **AWS Resource Access Manager (RAM)**.

**Why we are asking it this way**

We have been calling this "the shared VPC" throughout, meaning *shared usage*: you own it,
both our clusters live in it, and other applications may too. That is settled and is not
what this question is about.

This question is about **account ownership**. "Shared" in the AWS RAM sense means the VPC
lives in a **different AWS account** and its subnets are shared into ours. Those are
different things, and a "yes, it's shared" that means the first while we assume the second
would send us down a design that cannot be built.

**Why it matters this much**

In a RAM-shared VPC, AWS assigns ownership of specific resource types to the **VPC owner**,
and participants simply cannot create them. Several things in our documents change hands:

| Item | If the VPC is in our account | If RAM-shared to us |
|---|---|---|
| Interface VPC endpoints (incl. `ecr.api`, `ecr.dkr`, `kms`, the SSM trio) | **We create and own them** | **You must** — participants cannot create interface endpoints |
| Gateway endpoints + associating them to route tables (**#10**) | We create them | **You must** — route tables are owner-only |
| NACL rules on the ledger subnets (**#13**) | We manage the rules | **You must** — participants cannot create, delete or replace NACLs |
| Subnet-level flow logs (**#14**) | We create them | **You must** — participants can only create flow logs for network interfaces they own, not for a shared subnet |
| Subnet tag `kubernetes.io/role/internal-elb=1` (**#4**) | We tag, with permission | **You must** — participants cannot modify shared subnets or their attributes |
| Security groups (**#6**) | Ours | **Still ours** — participants can create and manage their own |

Our current design assumes the first column. In particular we asked to **own the eight
endpoints on the critical path** (`kms`, `secretsmanager`, `sts`, `ecr.api`, `ecr.dkr`,
`ssm`, `ssmmessages`, `ec2messages`) precisely so that a validator restart or an emergency
administrative session never waits on another team's change queue. **If the VPC is
RAM-shared, that is not a preference we can hold — it is not permitted**, and we would need
to agree an operational arrangement instead: who is on call for an endpoint change, and how
quickly.

**To be clear: a RAM-shared VPC is fine with us.** It is a normal, well-governed landing-zone
pattern and everything we are building works inside one. We are not asking you to change
your topology — we are asking you to tell us which it is, because it reassigns ownership and
we would rather design for it than discover it mid-apply.

**If the answer is "RAM-shared", here is what we propose instead.** Please treat this as a
proposal you can simply approve.

| Instead of | We propose |
|---|---|
| **Us owning the eight critical endpoints** | You own them. In exchange we ask for a **named escalation path with a response target** for endpoint changes during an incident, and **notification before any change to an endpoint policy**. Endpoints are create-once and change-rarely, so this is a narrow, low-frequency commitment — the risk we are managing is a bad endpoint *policy* (#20/#22/#23), not routine operations. |
| **#13 — us managing NACL rules on the ledger subnets** | **Withdrawn.** We fall back to security groups, which participants can own. Stated honestly: this costs us a stateless L3 layer, so security-group correctness becomes a single point rather than defence-in-depth. We accept that trade rather than ask you to delegate NACLs. |
| **#14 — subnet-level flow logs** | **ENI-level flow logs instead.** Participants may create flow logs for network interfaces they own, and our EKS interfaces are ours. Noisier and a little more assembly on our side, but it gets us the same visibility without needing anything from you. |
| **#4 subnet tagging · #10 gateway endpoints** | Yours, with no negotiation needed. Both are one-time setup rather than ongoing friction. |
| **#6 — security groups** | **Unchanged, ours.** Participants can create and manage their own. |

**The one thing we do need either way: describe/read access to the endpoints and their
policies.**

Our preflight asserts that every required endpoint exists, resolves and is correctly
configured **before** anything is applied — that is what turns a twenty-minute mid-apply
failure into a ten-second message naming the requirement. If we cannot read the endpoints,
we lose that check and go back to discovering misconfiguration during a billed deployment.

The AWS documentation lists participant describe rights for route tables, NACLs, subnets,
VPCs and security groups, but **does not state either way for VPC endpoints**. So we are
asking explicitly rather than assuming. It is a small grant and it protects the control that
saves the most time.

**One item to test rather than negotiate.** Whether a participant may create a **VPC
endpoint service** (the PrivateLink provider side) in a shared subnet is not documented
either way. Our application-to-ledger path uses one. If it turns out participants cannot,
our documented fallback is a direct internal load balancer with security-group and
NetworkPolicy isolation — we would tell you the isolation posture had changed. We will test
this early rather than discover it at integration.

**What happens if we don't get an answer**

Provisioning fails partway through with authorization errors on endpoint, NACL and flow-log
creation — after budget has been spent — and the shared-responsibility table gets
renegotiated under time pressure instead of agreed up front. **This is a one-line answer
that changes several of the others**, which is why it sits here rather than in the
confirmations section.

### #25 — ECR account topology, and cross-account pull for our node roles

**What we need — please choose:**

- **(a) ECR in our workload account.** Simplest; nothing further needed from you.
- **(b) ECR in a central shared-services account.** Then we need **repository policies**
  granting our EKS node roles and our In-VPC EC2 Runner role:
  `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`, `ecr:BatchCheckLayerAvailability`.
  In this case **#23 becomes mandatory** rather than merely advisable.

Either works for us. (b) is likely what you want if other teams will share the mirror, and
we are happy to consume it that way.

**Two repository settings we ask for, in both cases:**

- **Tag immutability ENABLED.** (It is off by default.)
- **No lifecycle expiry policy.**

**Why those two**

A container image tag is a *mutable pointer*: re-pulling the same tag can return different
bytes. In a permissioned financial network that means a validator could restart as
software nobody reviewed. We pin every image by **digest** for this reason; tag
immutability is the registry-side backstop.

And a validator node replaced eight months from now must still be able to pull the **exact
digest** the network was reviewed and approved on. An aggressive lifecycle policy would
delete it.

### #26 — Build-and-push path outside the VPC (no action required under #25a)

**The requirement**

Something must fetch third-party images and Helm charts from public registries and push
them into ECR. It needs to (i) reach the public internet and (ii) hold IAM credentials for
ECR push. Per §1, it **cannot** and **need not** live in this VPC.

> **If your answer to #25 is (a) — ECR in our own workload account — then this section
> requires NOTHING from you.** It is recorded so the supply-chain path is documented and
> reviewable, not because it needs a decision. You can skip to Section B.

**Our path, and why it asks so little**

We use **GitHub-hosted Actions runners** with **OIDC federation** to a short-lived IAM role
— no long-lived access keys anywhere. GitHub-hosted runners always have internet, so
condition (i) is satisfied by construction, and condition (ii) needs only an IAM role whose
trust policy accepts GitHub's OIDC issuer, scoped to this repository.

Every piece of that sits outside your control surface:

| Piece | Whose | Needs anything from you? |
|---|---|---|
| The machine with internet | GitHub's | No |
| The IAM role + OIDC trust | Our account (under #25a) | No |
| ECR repositories | Our account (under #25a) | No |
| Network path | None — ECR's public service endpoint (§1) | No |

**Under #25b** (ECR in a central shared-services account) the only addition is permission
for that OIDC role to push into the shared repositories — a repository-policy line, not a
machine.

**To be clear about what does not change:** a build host is still *required* either way.
The bytes have to flow `public registry → a machine with internet → ECR`, and there is no
AWS-native way to skip that hop — pull-through cache is unusable here (§2), and ECR
replication only copies ECR-to-ECR. #25a does not remove the machine; it removes your
involvement in providing one.

**Two workflows, different sensitivity — please read this before answering**

We expect the policy question to be about *what runs where*, not about internet access, so
we have separated the two jobs deliberately:

| Workflow | What it handles | Runs on |
|---|---|---|
| **Supply-chain mirror** | **Public** upstream images and Helm charts only. Nothing confidential is ever present on the runner. | GitHub-hosted is appropriate |
| **Release packaging** | **Our own** Terraform, Helm charts and scripts, packaged for Octopus | Wherever your policy requires |

If your policy permits GitHub-hosted runners for public artefacts but not for bank source
code, that split already exists in our design and costs nothing to honour — tell us and we
will run the second workflow on your infrastructure.

**Alternatives, if GitHub-hosted runners are not permitted at all**

- **An existing bank self-hosted runner estate** — likely the simplest, if it has egress and
  can assume an ECR-push role. It may not be owned by your team; see **CQ-2**.
- **AWS CodeBuild with no VPC configuration attached** — runs inside AWS, auditable through
  CloudTrail, a few cents per run, and because it is not attached to the VPC it does not
  affect the no-egress posture. Happy for it to live in a tooling account you control.

**What happens if none of these is permitted**

Nothing can be published to ECR and the platform cannot be built at all. We do not expect
this — under #25a the question does not even reach you — but it is the one place where a
flat "no" has no workaround.

---

## Section B — CI/CD and Octopus Deploy (CQ-1 – CQ-8)

We are wiring the platform into **GitHub Actions** (build/CI) and **Octopus Deploy**
(release/CD), following the pattern your teams already use.

### CQ-1 — Where does Octopus Server run, and can it be reached from inside the VPC?

**This is the most important question in this document.** It determines whether the
CD design works at all.

**The mechanism we plan to use:** the **Octopus Kubernetes Agent** — a Helm-installed agent
that runs *inside* the cluster and uses **polling communication**. The agent opens the
connection **outbound** to Octopus Server. This means:

- **no inbound access to the cluster,**
- **no publicly-addressable EKS endpoint,**
- **no inbound firewall rule.**

Octopus documents it as working with private/restricted Kubernetes API endpoints. It is
exactly the right shape for our constraints.

**The problem:** the agent needs **outbound reachability to Octopus Server**, and this VPC
has no internet route.

> **This works only if Octopus Server sits on the bank's internal network with a route
> from the VPC over the Transit Gateway.**
>
> **If Octopus Server is internet-hosted (e.g. Octopus Cloud), the agent cannot reach it
> from this VPC and this design does not work.**

**What we need from you:**

1. Where Octopus Server runs (internal / cloud-hosted / other).
2. Whether there is, or can be, a Transit Gateway route from the shared VPC to it.
3. The hostname and port the agent would poll, so we can scope the egress rule precisely
   rather than opening a range.

**If the answer is that Octopus is internet-hosted**, please tell us early — we would then
need to design an alternative together, and we would much rather do that now than at
integration testing.

**One consequence either way, which affects sequencing:** the agent is itself a Helm chart
that pulls its own container images. Those must be **mirrored into ECR before** the agent
can be installed, and installing it requires cluster access, which is what our in-VPC
In-VPC EC2 Runner is for. So the bootstrap order is: In-VPC EC2 Runner →
mirror the agent chart and images → install the agent → Octopus takes over from there.

### CQ-2 — GitHub Actions runners: who owns them, and should we use them? (not blocking)

**Not blocking.** Our default is GitHub-hosted runners with OIDC (#26), which needs no
machine from anyone. This question is about whether an existing bank runner estate would be
preferable — and, first, **who to ask**.

**Question zero: is this even your team?** Reference pipelines we were shown use
self-hosted runners labelled `[self-hosted, kubernetes]`, so a runner estate clearly exists
somewhere in the organisation. But those workflows belong to application teams, and CI
runners are often owned by a platform or DevOps group rather than by the team that provides
the network. **If runners are not yours, please just tell us who to ask** — we would rather
route the question correctly than have you chase an answer on our behalf.

**If they are yours (or once we reach the right team), we would like to know:**

1. **Which network are they in, and do they have internet egress?**
2. **Do they have a stable egress IP?** This one has a concrete consequence — see below.
3. Can a runner scale set be pointed at our repository, and can it assume an IAM role
   permitting **ECR push**?
4. Is the estate **Actions Runner Controller** (runners as pods) or long-lived VMs? Not
   important to us technically; it tells us whether adding a scale set is a configuration
   change or a provisioning request.

**Why the egress IP matters.** Docker Hub rate-limits anonymous pulls at 100 per 6 hours,
**enforced per IP address**, and notes that pulls attributed to a single address may hit
abuse limiting even when authenticated. GitHub-hosted runners share egress addresses across
all of GitHub's customers, so a mirror job that pulls from Docker Hub can fail
intermittently through no fault of its own — which is worse than failing consistently. We
can mitigate that by authenticating our mirror job to Docker Hub, and we will. But **a
runner with a stable, dedicated egress IP is simply more predictable for this workload**,
which is the one genuine technical argument for using yours rather than GitHub's.

**Where this stops being optional.** If policy permits GitHub-hosted runners for public
artefacts but not for the workflow that packages our own source code, we will need
somewhere to run the second one — see the two-workflow split in **#26**.

### CQ-3 — Why is the deployment package stored twice?

In one of the reference pipelines, the deployment package is stored **both** in the Octopus
built-in package feed **and**, wrapped in a `FROM scratch` container image, in ECR.

**Question:** is that ECR copy required by an artefact-retention or audit policy, or is the
Octopus feed sufficient on its own?

**Why we ask:** it determines whether we maintain one publication path or two. We are happy
to do either; we would just rather not carry a second path by accident.

### CQ-4 — Octopus space, projects, and naming

**What we need:**

1. Do we get our own Octopus **space**, or projects inside an existing one?
2. What naming convention should the projects follow?

**Context:** we expect **three** projects, not one:

| Project | Deploys |
|---|---|
| Infrastructure | Terraform, applied in a fixed order across four state files |
| In-cluster workloads | Helm releases: RPC nodes, explorer, monitoring |
| **Validator upgrades** | **Deliberately separate — see CQ-7** |

### CQ-5 — Does Octopus already run Terraform for other teams?

**What we need to know:** if so, which worker pool, and how Terraform state and
state-locking are handled.

**Our situation:** S3 backend with **S3-native state locking** (`use_lockfile`), **four
separate state files**, applied in a fixed order. Two concurrent applies against the same
state file contend on the lock and the second fails late and confusingly.

**No DynamoDB table is involved.** Terraform 1.10 added native locking — a `.tflock` object
written into the state bucket with a conditional put — and DynamoDB-based locking was
deprecated in 1.11. If your existing Octopus Terraform setup provisions a DynamoDB lock
table per project, we do not need one. It also means an in-VPC Terraform run needs only the
**S3** gateway endpoint to take a lock, not a second endpoint: **one fewer dependency in an
air-gapped VPC**, which is why we chose it.

**What we therefore need:** **deployment concurrency limited per project + environment** in
Octopus. If your existing Octopus Terraform setup already does this, we will follow it.

**One related item.** Octopus workers do not ship Terraform, so the step must run in an
**execution container** — and Octopus resolves every container image through a registered
**feed**. In this VPC that image cannot come from Docker Hub, so we need **our ECR
registered as a Docker feed in Octopus**, with the Terraform image mirrored into it like
any other. Please confirm whether ECR is already registered as a feed for other teams, or
whether we should request one.

### CQ-6 — Octopus service account and API key issuance

**What we need:**

A **service account** (not a personal user account), scoped to:

- push packages,
- create releases,
- deploy to **DEV only**.

**It must not be able to deploy to PROD.**

**Why a service account:** an API key generated against a personal login inherits that
person's permissions and dies when their account changes. Octopus documents that an API key
**cannot have more permissions than the user that created it**, so the scoping has to happen
on the account, before the key is generated.

**Also please confirm your rotation policy.** Octopus API keys default to a **180-day**
expiry. We intend to keep that default rather than extend it — a pipeline that fails on a
known date is a much better outcome than a credential that never expires.

### CQ-7 — PROD approval, and one gate that must be un-bypassable

**What we need:**

1. Who approves a PROD deployment, and can Octopus enforce that approval?
2. **A mandatory manual-intervention gate on validator upgrades, in both environments,
   that cannot be bypassed.**

**Why the second one needs explaining — this is a ledger-availability issue, not a
process preference:**

The chain runs **QBFT consensus with 4 validators**. It requires a quorum of 3 to produce
blocks, and therefore tolerates **exactly one validator being down at a time**.

A standard "Deploy Helm Chart" step pointed at the validator release updates **all four**
pod templates simultaneously. All four restart together. Quorum is lost. **The ledger stops
producing blocks and does not recover on its own.**

Our design prevents this in three independent places — the Terraform configuration ignores
validator changes, the Kubernetes workload uses a manual update strategy, and a CI check
fails any change that would restart more than one validator. The Octopus process is the
fourth: validator upgrades live in their own project, and the deployment step is a
controlled script that upgrades **one validator at a time**, verifying the chain kept
producing and the restarted node caught up before proceeding to the next.

We need that gate to be enforced by Octopus, not by operator discipline.

### CQ-8 — ECR account and cross-account pull

This duplicates **#25** and **#23** above and is listed here only so the CI/CD reviewers
see it. Please answer it once, in Section A.

---

## Section C — What we are NOT asking for

We want to be unambiguous, because several of the items above mention internet access and
we do not want that misread as a request for it.

- **No Internet Gateway.** Not now, not later.
- **No NAT Gateway.** Our pipeline runs outside the VPC (§1); nothing inside it needs
  egress to the internet.
- **No public EKS API endpoint.** The Octopus agent polls outbound; nothing dials in.
- **No inbound firewall rules** of any kind for CI/CD.
- **No egress proxy** for container image pulls.

The only outbound path we are asking about at all is **cluster → Octopus Server over the
Transit Gateway** (CQ-1), on the internal network, to a single known host and port.

---

## Section D — What we are withdrawing

Two requirements from the earlier network document are **no longer needed**. Both were
consequences of using a third-party artefact repository; moving to ECR removes them.

| Withdrawn | Was | Why it's gone |
|---|---|---|
| **#8** | Route and DNS resolution from the node subnets to an external registry host, plus its TLS trust chain | ECR is an AWS service reached through endpoints we already require. No external host to route to, no hostname for your DNS, no private CA certificate to distribute to our nodes. **This was the longest-lead item in the original document for your team.** |
| **#19** | A written policy exception for AWS-owned EKS addon images, which could not be repointed at a third-party registry | With ECR there is one registry and one path: the addon images and our mirrored images arrive identically. "All images from ECR" holds with no carve-out to defend. |

| **#21** | Permission for our In-VPC EC2 Runner to reach the Amazon Linux package repositories through the S3 gateway endpoint | **We removed the dependency instead of asking you to accommodate it.** That instance no longer installs any OS packages: its entire toolchain (`kubectl`, `helm`, `terraform`, and a JRE) is downloaded and checksum-verified outside the VPC, then delivered as a single S3 object it unpacks at boot. It needs no package manager, no internet, and no new permission. |

Also no longer needed, and previously implied: a registry CA certificate distributed into
every node's trust store, and a registry service account with pull credentials and a
rotation process. ECR uses a publicly-trusted certificate and authenticates from the node's
IAM role, so **no registry credential exists to be issued, stored or rotated.**

**Net effect on your queue: of the nine registry items we originally needed from you,
three are withdrawn (#8, #19, #21) and #26 needs nothing from you if #25 is (a).** That
leaves **four or five** depending on that one answer — and none of them requires a network
change. They are endpoint policy settings, one DNS setting, and answers to questions.

One thing #25a does **not** simplify, because it is easy to over-read: **#23 still stands.**
Even with the registry in our own account, the EKS managed addons pull from **AWS's own
registry account**, which is neither ours nor yours — so an endpoint policy scoped to a
single account still breaks `vpc-cni`, `coredns` and `kube-proxy`.

---

## Section E — How we will verify this, before spending anything

We are not asking you to take our word that these settings are correct, and we are not
planning to discover a problem during a billed deployment.

We run a read-only preflight from **inside the VPC** — from the In-VPC EC2 Runner,
not from a laptop, because a laptop would pass while the cluster still could not pull. It
resolves the image list from our Terraform configuration itself (so it cannot disagree with
what will actually be deployed), pulls every image manifest, and prints the digests.

That single check exercises **#20, #22 and #23** end-to-end, in about ten seconds, before
any billable infrastructure exists.

**If it fails, we will come back to you with a specific requirement number from this
document, not with a symptom.**

---

## Summary — what we need from you

| # | Ask | Type | Cost |
|---|---|---|---|
| #20 | S3 gateway endpoint policy → allow the ECR layer bucket | Config | none |
| #22 | Private DNS enabled on `ecr.api` + `ecr.dkr`; AWS-provided DNS resolution | Config | none |
| #23 | ECR endpoint policy scoped by **principal** (`aws:PrincipalAccount`), not by resource account — the EKS addon images live in an AWS-owned account (af-south-1: `877085696533`) | Config | none |
| #24 | **Which AWS account owns the VPC** — is it RAM-shared into ours? RAM-shared is fine; #24 carries a ready-to-approve proposal for that case (we withdraw #13, self-serve #14, ask only for an endpoint escalation path + describe access) | Answer (one line, wide impact) | none |
| #25 | ECR account topology + cross-account pull; tag immutability ON; no lifecycle expiry | Decision + config | ~USD 1–2/mo |
| #26 | Build-and-push path outside the VPC — **FYI only under #25a**; under #25b, one repository-policy line for our OIDC role | FYI / one policy line | none |
| CQ-1 | **Where Octopus Server runs and whether the VPC can reach it** | Answer | none |
| CQ-2 | Runner estate — **who owns it** (may not be your team), egress + stable IP, ECR-push role. **Not blocking**; preference plus one technical argument (Docker Hub per-IP rate limits) | Answer / redirect us | none |
| CQ-3 | Is the second (ECR) copy of the deployment package required? | Answer | none |
| CQ-4 | Octopus space, three projects, naming | Decision | none |
| CQ-5 | Octopus + Terraform: worker pool, state locking, concurrency limits | Answer | none |
| CQ-6 | Octopus service account scoped to DEV; key rotation policy | Provision | none |
| CQ-7 | PROD approval + **un-bypassable validator-upgrade gate** | Decision | none |
| CQ-8 | *(duplicate of #25/#23 — answer once, in Section A)* | — | — |

**Highest priority: CQ-1.** It is the only item that could require a design change rather
than a configuration change, so we would like it answered first.

**Withdrawn: #8, #19 and #21.**

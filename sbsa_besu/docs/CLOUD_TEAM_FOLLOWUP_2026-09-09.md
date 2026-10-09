# Besu Ledger Platform — open items after the calls of 2026-09-09

**From:** Ledger Platform Team · **Region:** af-south-1
**Supersedes:** the registry/CI-CD request document (#20–#26, CQ-1–CQ-8), which is now
mostly answered.

Thank you — most of the registry and supply-chain questions are closed. This note records
what is settled, sets out **one design problem your answers created**, and asks for the
**tenancy detail** that is now the last large unknown.

> **Update 2026-09-14 — R-9 is answered, thank you.** You confirmed a **shared central
> egress** exists (a load balancer for outbound traffic, another for internal traffic) and that
> the ledger VPC may use it. We understand the internals are yours and are not asking about
> them. §2.1 now records the answer, §2.2 has one **correction** on our side (TLS inspection),
> and §5 replaces R-9 with **R-10 — a short, ticket-shaped list** of what we need configured.
> Nothing else in this document changed.

---

## 1. Settled — no further action needed

| Item | Answer | Status |
|---|---|---|
| **#25** — ECR topology | Central shared-services account | **Closed** (= option b) |
| **#25** — ECR **region** | `af-south-1` | **Closed.** Same region as the VPC, so the `ecr.dkr` endpoint reaches it and the `prod-af-south-1-starport-layer-bucket` ARN in #20 is correct as written |
| **#25** — tag immutability | Already enforced registry-wide | **Closed** — and it is the right default; thank you |
| **#25** — lifecycle expiry | No expiry policy | **Closed.** This was the one we expected to have to argue for |
| **CQ-2** — CI runners | Bank self-hosted runners, with internet | **Closed.** We will not stand up our own |
| **CQ-1** — Octopus | **Octopus Cloud** (`*.octopus.app`) | **Answered — see §2.** This is the one that changes the design |
| **CQ-4** — Octopus space | We have our own namespace | **Closed**, subject to one clarification in §4 |

**Withdrawn by us as a result** — please ignore these from the earlier document:

- **#26** — we are no longer asking you to permit GitHub-hosted runners or create an OIDC
  identity provider. We will use your runners.
- **#13** — NACL rules on the ledger subnets. We fall back to security groups.
- **#14** — subnet-level flow logs. We will use ENI-level flow logs on interfaces we own.

---

## 2. The one problem: Octopus Cloud cannot reach an air-gapped VPC

**What we confirmed.** The Octopus URL is `https://<instance>.octopus.app`, and the
certificate is issued for `*.octopus.app`. That is Octopus Deploy's own domain — a
self-hosted server would be on a bank domain with a bank certificate. So Octopus Server is
**SaaS, on the public internet**.

**Why that is a problem.** Every mechanism Octopus offers for deploying into a private
network works the same way: an agent inside the network opens an **outbound** connection to
Octopus Server and holds it open. That is a genuinely good security property — nothing dials
in, no inbound rule, no public cluster endpoint. But it means the agent must be able to
**reach `<instance>.octopus.app` on the public internet**, and this VPC has no route to the
internet by design.

So the constraint is not about firewalls or permissions. **There is nowhere for the packet
to go.**

```
  Octopus Cloud                 The shared VPC
  (public internet)             (no IGW, no NAT, no egress)
 ┌────────────────┐            ┌──────────────────────────┐
 │  <instance>    │            │  EKS (private endpoint)  │
 │  .octopus.app  │ ◀───────╳──│  agent tries to poll out │
 └────────────────┘   no route └──────────────────────────┘
```

**What still works without any change.** Octopus Cloud's own hosted workers have internet,
and **AWS's API endpoints are public**. So Octopus can already run, today, with nothing new
from you:

- all of our Terraform that only calls AWS APIs — networking, EKS cluster, IAM, KMS,
  Secrets Manager, S3 state,
- release management, versioning, approvals and the audit trail for that layer.

**What does not work.** Anything that talks to the **Kubernetes API**: the in-cluster
Terraform layer, the Helm releases, and the validator upgrades. Those need a path into the
VPC.

### 2.1 The question that matters most — R-9 · **ANSWERED 2026-09-14**

> **How do your other teams deploy into private AWS environments from this Octopus Cloud
> instance today?**

> **Your answer:** through a **shared central egress** — not dedicated to any one team —
> fronted by a **load balancer for outbound traffic**, with a **second load balancer for
> internal traffic**. The ledger VPC can use it. **We adopt this pattern**; §2.3's split is
> now our fallback only, and the validator-gate reduction it carried no longer applies. What
> we need configured is in **R-10** (§5). The rest of §2.1 below is kept as the record of what
> was asked.

We ask because **you have already solved this.** The reference pipelines we were shown
deploy Kubernetes workloads through Octopus, so a working pattern exists somewhere in the
bank. Whatever it is, it is almost certainly better for us to adopt it than to invent a
fourth thing. Specifically:

- Do targets reach Octopus Cloud **outbound through a central egress proxy or NAT** that
  the ledger VPC could also use over the Transit Gateway?
- Or do those clusters have **public API endpoints**? (We would not follow that one, but it
  tells us the pattern.)
- Or do deployments there stop at the AWS API layer too?

### 2.2 If a narrow egress path is possible — what we would actually be asking for

We want to be honest that this **reverses** something we said earlier. Our first document
stated we were not asking for NAT, an Internet Gateway or a proxy. That was written on the
assumption that Octopus was on your internal network. It is not, so the assumption was wrong
and we are revising the ask rather than pretending it still holds.

**But the ask is much narrower than "internet access."** One destination, one direction:

| | |
|---|---|
| **Destination** | `<instance>.octopus.app` — a single hostname. Octopus publishes static IP addresses for Cloud instances, so this can be an IP allowlist rather than a DNS-based rule |
| **Direction** | **Outbound only.** Nothing ever dials into the VPC |
| **Port** | Octopus polling; **10943** by default, and we would ask Octopus whether your instance supports polling over **443** instead, which usually fits an existing egress rule |
| **Who initiates** | An agent inside our cluster, on a schedule |
| **What we are NOT asking for** | General internet access, an Internet Gateway, a public EKS endpoint, or any inbound rule |

~~If the bank's standard is a central egress proxy that terminates TLS, tell us — the agent
would need the proxy's CA certificate, and we would want to confirm with Octopus that
polling tolerates interception before committing to it.~~

**Correction (2026-09-14) — we had this wrong, and it matters for the ticket.** The Octopus
agent does **not** tolerate TLS interception and no CA bundle changes that: its protocol uses
**client-certificate authentication with pinned thumbprints on both ends** and, in Octopus's
own words, "requires an uninterrupted TLS tunnel". So if your egress decrypts by default, the
two Octopus hostnames need a **no-decrypt (bypass) rule** — the same exception any team
running a mutually-authenticated agent through the proxy will already have. It is listed in
R-10. Also corrected: the destination is **two** hostnames, not one — Octopus Cloud serves
agent polling on **443** at `polling.<instance>.octopus.app`, alongside the instance URL
itself. Port **443**, so no non-standard port exception is needed.

### 2.3 If it is not possible — what we will do instead, and what it costs

We are not blocked. Our current, already-proven process runs the in-cluster layer from an
**administrative EC2 instance inside the VPC**, reached over **AWS Systems Manager Session
Manager** — no SSH, no public IP, no inbound rule. That works today and needs nothing from
you beyond the SSM endpoints in §4.

The deployment would then split:

| Layer | Runs where | Loses anything? |
|---|---|---|
| AWS-API Terraform (network, EKS, IAM, KMS, secrets) | **Octopus Cloud hosted worker** | No |
| In-cluster Helm releases, in-cluster Terraform | **In-VPC In-VPC EC2 Runner, by an operator** | Yes — see below |
| **Validator upgrades** | **In-VPC In-VPC EC2 Runner, by an operator** | **Yes, and this is the one that matters** |

**The cost, stated plainly.** The chain runs QBFT with 4 validators. It needs 3 to produce
blocks, so **exactly one may be down at a time**. Restart more than one and the ledger stops
producing and does not recover on its own. We wanted that protected by a gate the deployment
tool enforces and nobody can click past. Under this split, it is protected by three
structural controls in our own code — the Terraform ignores validator changes, the Kubernetes
workload will not restart pods on a template change, and a CI check fails any change that
would touch more than one validator — plus **operator discipline** for the final step.

That is defensible. It is what we do today. But it is a weaker control than a tool-enforced
gate, and we would rather you knew that we chose it than discover later that everyone assumed
Octopus was enforcing something it was not.

**Our recommendation:** answer **R-9** first. If an egress pattern already exists for other
teams, we adopt it and lose nothing. If not, we take the split above and record the reduced
control explicitly.

> **Outcome (2026-09-14):** the pattern exists and we adopt it. The split above is now our
> fallback only. See R-10 in §5 for what we need configured.

---

## 3. Tenancy — working assumption, and what we still need

**Our working assumption, which we would like confirmed in passing rather than
investigated:** we are tenants **inside your AWS account** — our credentials resolve to the
same account that owns the VPC, and our EKS clusters, IAM roles, KMS keys and Terraform
state all live there. We are proceeding on that basis. If it turns out our credentials
resolve to a *different* account with your subnets shared to us via AWS Resource Access
Manager, tell us and several items below change hands — but we are not blocking on it.

**`af-south-1` is enabled on the account** — confirmed, thank you. That was the one that
could have stopped everything on day one, since it is an opt-in region.

### 3.1 What this changes about our earlier requests — please read, it makes them smaller

**#23 was written for the wrong shape, and we are correcting it downward.**

We originally asked you to scope the ECR endpoint policy by principal, using
`aws:PrincipalAccount` restricted to our account. **That request is now both meaningless
and harmful:** meaningless because in a single shared account every tenant satisfies the
condition, and harmful because the ECR endpoint is shared with your other tenants — a
policy scoped to *our* roles would break *theirs*.

**So we withdraw the principal-scoping request entirely.** What remains is much smaller:
two things to *verify* on an endpoint policy you already have.

| Check | Why |
|---|---|
| The policy permits **`ecr:GetAuthorizationToken` with `Resource: "*"`** | It is a registry-level action that does not support resource-level permissions. If it sits in a statement scoped to repository ARNs, **authentication fails before any pull is attempted** — and it reads as a credentials problem, not a policy one |
| The policy does **not** restrict `Resource` to a single account's repositories | The EKS managed addons — `vpc-cni`, `coredns`, `kube-proxy` — are pulled **by our node role** but **from an AWS-owned registry account**. In af-south-1 that is **`877085696533`**, which is **not** the widely-quoted `602401143452` — that value serves us-east-1, eu-west-1 and most other regions, and a policy copied with it fails here exactly as if no policy allowed the pull |

If the policy is currently full-access, both hold already and there is nothing to do. The
same applies to **#20** — the S3 gateway endpoint policy must permit `s3:GetObject` on
`arn:aws:s3:::prod-af-south-1-starport-layer-bucket/*`, because ECR serves manifests over
`ecr.dkr` but the **layers** come from an AWS-managed S3 bucket.

**We have written a read-only script that checks all of this in about ten seconds**
(`scripts/preflight/verify-endpoints.sh`). It needs only `ec2:DescribeVpcEndpoints`,
`ec2:DescribeVpcs` and `ec2:DescribeSecurityGroups`. **We would rather run it ourselves and
bring you a specific requirement number than send you a symptom** — see §4, R-6.

**#13 and #14 stay withdrawn, for a better reason than before.** We withdrew NACL rules and
subnet-level flow logs believing a RAM participant was structurally forbidden from them. In
a single shared account that is not the constraint — but the better argument holds anyway:
both are **subnet-level** settings on subnets shared with your other tenants, so our
changing them would affect workloads that are not ours. Security groups and ENI-level flow
logs give us what we need without touching anything shared.

### 3.2 What we still need to know

1. **A dedicated IAM path or role-name prefix** for the roles we create (roughly nine
   workload roles plus IRSA roles). We are asking for this, not resisting it — it is what
   makes the next item safe.
2. **Is there a mandatory permissions boundary** we must attach? We already attach one of our
   own to all nine roles. If you mandate one, yours should **replace** ours rather than
   layer, and we would want to check it does not deny something the platform needs.
3. **Service Control Policies.** Are there any that would deny creating KMS keys, creating
   IAM roles, or specific EC2 instance types? An SCP denial is invisible to us until the API
   call fails mid-apply.
4. **A mandatory tag set**, if you enforce one. We already tag everything with `Project`,
   `Environment`, `ManagedBy`, `DeletionGroup`, `Owner` and `CostCenter`, and are happy to
   add yours.
5. **Service quotas.** Our footprint is two EKS clusters, security groups for both, and — if
   the endpoints in §4 do not already exist — up to 16 VPC endpoints. In a shared account
   those draw on limits your other tenants also use.
6. **CloudTrail read access for our resources.** We audit every access to a validator key via
   KMS decrypt events. Without read access to the trail, that control does not exist for us.
7. **A Route 53 private hosted zone associated with the VPC.** The RPC server certificate is
   issued for a name in it, so every TLS client fails hostname verification if it does not
   resolve. In a single account this is straightforward; we mention it only so the zone name
   we choose does not collide with one you already have.
8. **Can Octopus Cloud assume a role in this account** to run the AWS-layer Terraform (§2),
   and **can the GitHub runners assume a role** that can push to the central ECR (§4)?

### 3.3 One thing we want you to see rather than trust

Our teardown is **tag-keyed** — it finds resources by our `DeletionGroup` tag and deletes
them. That is safe in a dedicated account and deserves more care in a shared one, so we will
additionally constrain it to our IAM path and resource-name prefix.

**We would like you to review that script before it is ever run in your account.** We would
rather you saw it than took our word for it.

---

## 4. Smaller open items

**R-2b — how do the runners reach the internet?** You confirmed they have it. Two details
that cost a day each if found late:

- Direct, or through a **forward proxy**? If a proxy, hostname and port.
- **Does it terminate and re-sign TLS?** If so we need its CA bundle — the tools we use
  (`crane`, `helm`, `curl`) verify certificates and fail closed against an unknown CA.
- **Do you have Docker Hub credentials for CI?** Docker Hub rate-limits anonymous pulls at
  **100 per 6 hours, per source IP**. A shared runner estate presents few egress addresses
  shared by every team, so an anonymous mirror job can fail intermittently through no fault
  of its own. An organisational token, or confirmation that we should supply our own.

**R-5b — repository namespace and creation.** Immutability and retention are settled. We
still need: a **repository prefix we own** (we need roughly 28 — 23 mirrored images plus a
Helm chart namespace), and whether repositories are **created on request** or we get a
**scoped cross-account role** that can create them under our prefix. We would prefer the
latter so mirroring a new upstream version is not a ticket.

**R-7 — the two ECR permissions, and how the runners get an AWS identity.**

1. **Push.** The runners' AWS identity needs `ecr:GetAuthorizationToken` (registry-level,
   resource `*`) plus push actions scoped to our namespace.
2. **Pull.** A repository policy in the central account granting our EKS node role and admin
   instance role `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer` and
   `ecr:BatchCheckLayerAvailability`.

**3. Which mechanism do your runners use to obtain AWS credentials?** This one changes what
we write, not just what we configure, so we would rather ask than discover it on the first
run:

| Mechanism | When it applies | What we would need |
|---|---|---|
| **GitHub OIDC → `sts:AssumeRoleWithWebIdentity`** | Works on self-hosted runners exactly as on GitHub-hosted ones. **Our current default** | A role whose trust policy accepts GitHub's OIDC issuer, scoped to this repository |
| **IRSA** — a Kubernetes service account annotated with an IAM role | If the runners are pods (an Actions Runner Controller estate) | The role attached to the runner scale set's service account, or a role it may assume |
| **EC2 instance profile** | If the runners are long-lived VMs | The role on the instance profile, or one it may assume |

We ask because the reference pipelines we were shown run on runners labelled
`[self-hosted, kubernetes]`, which is *consistent with* runners that are themselves pods —
in which case **IRSA is the more likely mechanism than OIDC**, and our workflow's
authentication step is a different piece of code rather than a different setting. Two labels
are not proof of it, which is exactly why this is a question.

**One thing we would rather not inherit.** Those reference pipelines authenticate with
**static AWS access keys** held as repository secrets. We are deliberately not copying that:
long-lived keys in CI are the credential most likely to outlive the person who created them.
If your runners genuinely cannot federate, tell us and we will design around it explicitly —
but we would like that to be a stated constraint rather than something we absorb by imitation.

**4. What runner labels should we target?** `runs-on` selects by label, and ours is a
repository variable precisely so no bank-specific value is committed. We just need the
correct set — and whether there is more than one pool, since a mirror job that queues behind
another team's builds is worth knowing about before we schedule it.

**5. Are GitHub-hosted runners usable for jobs that handle nothing sensitive?** One of the
reference pipelines runs a trivial job on `ubuntu-latest` and its AWS-touching jobs on
`[self-hosted, kubernetes]`, so we read "do not stand up your own runners" as being about
*provisioning*, not about *using GitHub-hosted at all*. If that reading is right, our
supply-chain job — which handles only **public** upstream images and charts, with nothing
confidential ever on the runner — could run there and leave your capacity for work that needs
it. If the reading is wrong, no problem: everything runs on yours. We are checking the
inference rather than acting on it.

> `ecr:GetAuthorizationToken` does **not** belong in the repository policy — it is authorised
> in the *caller's* account against resource `*`. Put there it does nothing; omitted from the
> caller's identity policy, or excluded by the endpoint policy in #23, authentication fails
> before any pull is attempted and reads as a credentials problem rather than a policy one.

**R-6 — the VPC endpoints.** We need 16: `ssm`, `ssmmessages`, `ec2messages`, `ecr.api`,
`ecr.dkr`, `ec2`, `sts`, `eks`, `elasticloadbalancing`, `kms`, `secretsmanager`, `logs`,
`monitoring`, `sns`, `sqs` as interface endpoints, plus **`s3` as a free gateway endpoint**.

**Please build the three SSM endpoints first, ahead of everything else.** The administrative
instance has no SSH, no public IP and no inbound rule — Session Manager is its only access
path. Without those three we cannot reach it, cannot bootstrap the cluster, and cannot deploy
anything at all. It is the one dependency with no workaround, and §2.3 makes it more
important than it was, not less.

Two things that make this cheaper for both of us:

- **`ec2:DescribeVpcEndpoints` for us.** We run a read-only preflight that asserts every
  endpoint exists, resolves and is configured correctly **before** anything is applied. It
  turns a twenty-minute mid-apply failure into a ten-second message quoting a requirement
  number back to you.
- **Notification before any endpoint-policy change**, and a named escalation path for
  endpoint changes during an incident. Endpoints are create-once and change-rarely, so this
  is narrow — the risk being managed is a bad endpoint *policy* (#20, #22, #23), not routine
  operations.

**We may be able to withdraw #4.** It asked you to tag the load-balancer subnets
`kubernetes.io/role/internal-elb=1`. The AWS Load Balancer Controller also accepts subnet IDs
specified explicitly on the Service, which removes the need for the tag. We are verifying it
against our controller version; if it holds, #4 goes away.

**R-8 — Octopus detail.**

1. Is our namespace **our own Space**, or a project group inside a shared Space? It decides
   how we scope a service account, and we need one that can deploy to **DEV but not PROD**.
2. **A worker pool with AWS credentials** for the Terraform steps — and does Octopus already
   run Terraform for other teams? We will follow an existing pattern rather than invent one.
   We use S3-native state locking (`use_lockfile`), so **no DynamoDB lock table is needed**.
   We do need **deployment concurrency limited per project + environment**.
3. **Is the central ECR registered in Octopus as a Docker feed?** Octopus resolves every
   execution-container image through a registered feed, and our Terraform steps need a pinned
   `hashicorp/terraform` image that cannot come from Docker Hub in this VPC.

---

## 5. Summary

| # | Ask | Priority |
|---|---|---|
| ~~**R-9**~~ | ~~How do your other teams deploy into private AWS environments from Octopus Cloud today?~~ **Answered 2026-09-14 — shared central egress behind a load balancer. Adopted.** | **Closed** |
| **R-10** | **Egress configuration for the Octopus agent — a firewall/proxy ticket, six lines.** (1) The **proxy address** to configure, `host:port`, as seen from the ledger VPC. (2) **Source allowlist:** our In-VPC EC2 Runner's fixed private IP (a **/32** — we will send it), or its subnet /24 if you allowlist by subnet. (3) **Destinations:** `<instance>.octopus.app` and `polling.<instance>.octopus.app`, **port 443, `CONNECT` only**, outbound only. Octopus publishes static IPs for the instance if your rules are IP-based. (4) **No TLS decryption** on those two destinations (§2.2 — protocol requirement, not preference). (5) A **route** from the *ledger* route tables to the egress VIP's prefix over the Transit Gateway — the ledger tables only, not the application/lb/endpoint/data tables. (6) Whether the proxy **requires credentials**; if so, a service credential for our instance. **We are not asking for:** general internet access, an Internet Gateway, a default route, a public cluster endpoint, any inbound rule, or any detail of how the egress is built | **High** |
| **R-3** | **Tenancy detail** — IAM path/prefix, permissions boundary, SCPs, quotas, CloudTrail read. **We now ask you for LESS than before: #23's principal-scoping request is withdrawn (§3.1)** | High |
| **R-6** | The 16 endpoints — **SSM trio first**; read access; change notification | High |
| **R-7** | Runner AWS identity — **OIDC or IRSA?** — plus ECR push, cross-account pull policy, runner labels, and whether GitHub-hosted is permitted for public-artefact jobs | High |
| **R-5b** | Repository prefix; create-on-request or a scoped role | Medium |
| **R-2b** | Proxy / TLS interception / Docker Hub credentials | Medium |
| **R-8** | Octopus Space scope, worker pool, ECR as a feed | Medium |

**Closed:** #4 (pending our verification), #8, #13, #14, #19, #21, #25, #26, CQ-1, CQ-2, CQ-4, **R-9 (2026-09-14)**.

# CI/CD design record — GitHub Actions + Octopus Deploy

**Date:** 2026-09-04 · **Updated:** 2026-09-17 — **CD-56..CD-61 VALIDATED LIVE** (mock deploy, `deploy-run-2026-09-17-r9-mock.md`); CD-65 added. 2026-09-14 — **R-9 CLOSED, option 1** (§7.1, CD-55).
**Status:** CD-1..CD-65 recorded. **#25, CQ-1, CQ-2, CQ-4 and R-9 CLOSED.** CQ-1 resolved against
us — Octopus is Octopus Cloud (SaaS) (CD-33) — but **R-9 resolved for us: the bank has a shared
central egress, fronted by a load balancer, that the ledger VPC can use.** The cloud team will
not disclose the internals, so the configuration on our side is decided by us, per question,
in **CD-56..CD-62**, and reproduced in a new mimic project (**CD-63**). The polling Tentacle
on the runner (CD-36) is now the design, not a contingency; **CD-34's layer split is
superseded** and **CD-5's tool-enforced validator gate is restored.**
Open: **R-3** (tenancy shape) and the firewall-ticket asks in **R-10**.
See `CLOUD_TEAM_FOLLOWUP_2026-09-09.md`.
**Scope:** how the `sbsa_besu` platform is built, mirrored, released and deployed.
Companion to `CLOUD_TEAM_REDESIGN_NOTES.md` (§11 = the ECR registry) and
`NETWORK_REQUIREMENTS_CLOUD_TEAM.md` (§8 = the registry asks).

> **No bank-specific values appear in this document or in any workflow we write.**
> Account IDs, registry hostnames, repository prefixes, org names, runner labels and
> Octopus space names are all inputs — GitHub variables/secrets and Terraform tfvars.
> The reference pipelines that seeded this design contained live values; they were read
> for *shape* only. See CD-10.

---

---

## 0. How the platform actually gets built

**Read this before the decision table.** Everything in §1–§11 assumes it, and the questions
this section answers are the ones that get asked every time someone new looks at the
pipeline — including "so which of these things builds the chain?"

### 0.1 Two execution classes, and why the split is forced

Every Terraform resource in this platform falls into exactly one of two classes, and the
difference is not stylistic — it decides *where the apply can physically run*.

| Class | What it is | Where it can run |
|---|---|---|
| **AWS layer** | Pure AWS API calls: VPC consumption, EKS cluster, IAM, KMS, Secrets Manager, S3, NLBs | **Anywhere** with credentials — a laptop, a CI runner, an Octopus Cloud hosted worker. AWS API endpoints are public |
| **In-cluster layer** | Anything through the `kubernetes` / `helm` providers: the gp3 StorageClass, Secrets Store CSI driver, the Besu releases, Blockscout, kube-prometheus-stack, PDBs | **Only from a host with a network route to the private EKS API endpoint** |

The EKS API endpoint is private (`eks_public_access = false`). A host outside the VPC reaches
AWS APIs perfectly well and then fails on anything Kubernetes with
`dial tcp 10.x.x.x:443: i/o timeout`. That single fact shapes the whole CD design.

### 0.2 What CI produces: TWO artefacts, not one

A common and expensive misreading is that the release package contains the images. It does
not.

| Artefact | Produced by | Lands in | Contains |
|---|---|---|---|
| 23 container images + 5 Helm charts | `supply-chain.yml` | **ECR**, as OCI artefacts | the actual bytes the cluster pulls |
| One versioned tarball | `release.yml` | **the Octopus package feed** | `terraform/` + `helm/` + `scripts/` + the version manifest |

The package **references** images by digest; it never carries them. Two consequences worth
holding on to:

- **Re-mirroring does not produce a new release**, and **cutting a release does not
  re-mirror.** Different triggers, different cadence, different blast radius (CD-3).
- An image that was never mirrored is not caught by cutting a release. It is caught by
  `verify-images.sh` — and only for the 8 platform images, which is why the 15
  chart-carried ones remain the most likely cause of a failed first deployment.

### 0.3 Who deploys what

**GitHub Actions never deploys anything** (CD-2). It mirrors, validates, packages and
publishes, and stops. Octopus deploys.

| Octopus project | Deploys | Needs cluster access? | Status |
|---|---|---|---|
| **`besu-infra`** | Terraform: `shared` → `runner` → `chain` (AWS layer) → `app` (AWS layer) | No | **Works today** from an Octopus Cloud hosted worker. Nothing needed from anyone |
| **`besu-workloads`** | The in-cluster layer: StorageClass, Secrets Store CSI, bootnode / RPC / explorer-RPC releases, Blockscout, monitoring, PDBs | **Yes** | **Buildable — R-9 closed (CD-55).** Runs on the runner's polling Tentacle worker (CD-57), reached through the bank's egress proxy |
| **`besu-validators`** | The validator release **only**, behind a mandatory gate, via `rolling-besu-apply.sh`, one pod at a time | **Yes** | **Buildable — R-9 closed (CD-55).** Same worker; the manual-intervention gate (CD-5) is enforced by Octopus again |

### 0.4 The sequence

```
  1. Actions: supply-chain.yml       23 images + 5 charts  ->  ECR
        |                            MUST be first: nothing can pull before it exists
        v
  2. Actions: release.yml            validate, H1 plan-safety gate, package
        |                            -> Octopus feed, create release (a SNAPSHOT, not a deploy)
        v
  3. Octopus besu-infra              shared -> runner -> chain(AWS) -> app(AWS)
        |                                       |
        |                                       +--> creates the in-VPC EC2 runner
        v
  4. ???  in-cluster layer           StorageClass, CSI, bootnodes, RPC, explorer, monitoring
        |                            Octopus, via the polling Tentacle on the runner (CD-57)
        v
  5. ???  validators                 rolling-besu-apply.sh, ONE pod at a time
```

**Note step 3 feeding step 4: Octopus creates the runner, and the runner deploys the
in-cluster layer.** That chain held whichever way R-9 went, and it holds now that R-9 has
closed: the runner is the Tentacle host Octopus drives (CD-57) and the break-glass shell (CD-53).

### 0.5 What R-9 blocked, and how it closed (2026-09-14)

**R-9 never blocked building the chain.** The `runner` root is part of `besu-infra`, so the
moment the infrastructure layer finishes, the host that can deploy the in-cluster layer exists.
The chain could always be built over SSM, exactly as in the predecessor project. What R-9
decided was **whether Octopus does it** — whether the validator upgrade gate is enforced by a
tool nobody can click past, or by operator discipline plus the H38 CI check. **A control
question, not a capability question.**

**It closed on option 1** (§7.1): the bank has a **shared central egress** — a proxy estate
fronted by a load balancer, with a second load balancer for internal traffic — and the ledger
VPC can use it. It is not dedicated to us, and the cloud team will not describe its internals,
which is reasonable: it is their service and we are one consumer of it. So the remaining
questions (explicit or transparent, TLS inspection, port, source and route) are **answered by
us, as design assumptions chosen to be robust under uncertainty**, each with a one-line
fallback if reality differs — CD-56..CD-60. What we still *ask* for is shaped like a firewall
ticket, not an architecture disclosure — R-10 in the follow-up document.

The corollary still holds: **the EC2 runner stays.** It is now the Tentacle host *and* the
break-glass shell (CD-53). Removing it leaves nothing that can reach the cluster.

### 0.6 Against the predecessor project (`besu-aws`)

Most people arriving here know the earlier model: Terraform from a laptop for infrastructure,
an EC2 runner for the chain. What changed:

| | `besu-aws` (predecessor) | `sbsa_besu` (here) |
|---|---|---|
| Images | pulled from public registries at deploy time | **mirrored into ECR beforehand** by Actions. Nothing in the VPC ever contacts a public registry |
| Infrastructure layer | `terraform apply` from the laptop | **Octopus `besu-infra`**, hosted worker |
| Blockchain layer | EC2 runner over SSM | **Octopus `besu-workloads`**, executing on the same EC2 runner — now a polling Tentacle worker (CD-57). SSM remains for break-glass only |
| Validator upgrades | `rolling-besu-apply.sh`, operator discipline | **Octopus `besu-validators`**: the same script, behind a manual-intervention gate Octopus enforces (CD-5), on the same worker |
| Release / approval record | none | Octopus releases, approvals, and an audit trail |

**So both layers changed owner — the infrastructure layer to a hosted worker, the blockchain
layer to Octopus driving the same in-VPC host we already had.** The genuinely new capability
is the mirror — the predecessor had no equivalent because its nodes
could reach the internet.

### 0.7 What is true once CI has run, and nothing else has

- The images and charts are in ECR.
- A versioned package is in the Octopus feed.
- An Octopus release exists — an **immutable snapshot of the process and its variables**
  (CD-22). A release is not a deployment.
- **Nothing is deployed** — with one exception: **SIT may auto-deploy on merge** (CD-41), so
  a `release.yml` run can cause Octopus to start deploying SIT. UAT and PROD both require
  approval and are unreachable from a CI credential (CD-15, CQ-6).

---

## 1. What the reference pipelines settled

Two production bank pipelines were supplied as reference. They establish the house
style, and it is worth being explicit about what was taken and what was not.

**Adopted:**

- **GitHub Actions for CI, Octopus Deploy for CD.** Actions builds and publishes; Octopus
  owns everything that touches an environment.
- **The Octopus actions** — `OctopusDeploy/push-package-action@v3`,
  `create-release-action@v3`, `deploy-release-action@v3`.
- **The `FROM scratch` package-wrapper trick.** One reference pipeline pulls a third-party
  OCI Helm chart, packages it with its own values files, and stores the tarball both in the
  Octopus package feed and — wrapped in a `FROM scratch` image — in ECR. That is a working
  answer to D-22 (charts must reach an air-gapped cluster) and we reuse the shape.
- **Release notes as a build artefact**, attached to the Octopus release.
- **Job summaries** (`$GITHUB_STEP_SUMMARY`) — cheap, and they make a failed run legible.

**The most instructive thing about them — what they do NOT do.**

The chart pipeline mirrors the *chart* but not **the images that chart references**. Its
target cluster must obtain Prometheus, Grafana and the rest from somewhere else — egress,
or an already-populated registry. Copy that pattern verbatim and, in our VPC, every one of
the **15 chart-carried images** (`../CHART_IMAGES.md`) hangs on `ImagePullBackOff` while
Besu and Blockscout pull fine. Our mirror must do **both** halves, plus per-chart values
overrides pointing each image at ECR. The reference pipelines give us no pattern for that,
because they never needed one.

**Deliberately not adopted, with reasons:**

| Not copied | Why |
|---|---|
| `docker push …:latest` alongside the version tag | Contradicts **H38** (digest pinning) and **O-3** (ECR tag immutability). A validator restarting as bytes nobody reviewed is the exact failure this platform is designed against. |
| Static AWS access keys in GitHub secrets | **H38** already records the position: *"OIDC short-lived AWS creds, never long-lived keys."* See **CD-9**. |
| `docker build` / `push` as the *image*-mirroring mechanism | It re-manifests on push and **changes the digest** (**D-18**). Fine for a package wrapper; wrong for mirroring upstream images. See **CD-11**. |
| Chart and image versions hardcoded in workflow `env:` | Creates a second source of truth beside Terraform, free to drift — against the no-hardcoding rule. See **CD-12**. |
| SonarQube / Checkmarx shared workflow | Not available outside the bank org, and deferred by decision (**CD-13**). Re-add at bank onboarding. |
| Auto-deploy to an environment on merge | Acceptable for a stateless API. Not for a ledger. See **CD-5** and **CD-15**. |

---

## 2. The shape — where the boundary sits

```
  GitHub Actions                    Octopus Deploy                 The VPC
  (has internet)                    (bank network)                 (NO egress)
 ┌────────────────┐               ┌──────────────────┐          ┌──────────────────┐
 │ mirror upstream│──crane copy──▶│                  │          │  private ECR     │
 │ images + charts│               │                  │          │  (endpoints)     │
 ├────────────────┤               │  package feed    │          ├──────────────────┤
 │ package the    │──push pkg────▶│  releases        │          │  chain EKS       │
 │ platform       │  create rel   │  environments    │◀──polls──│  Octopus K8s     │
 └────────────────┘               │  approvals       │  outbound│  Agent           │
                                  └──────────────────┘          └──────────────────┘
```

### 2.1 Why the pipeline needs no egress from the VPC

**ECR has public service endpoints.** A build machine with internet and IAM credentials
**pushes** to ECR from anywhere — it does not need to be in the VPC, peered to it, or on
the Transit Gateway. The `ecr.api`/`ecr.dkr` interface endpoints exist for the **other
direction**: so workloads *inside* the no-egress VPC can **pull** without an internet
route. Push from outside, pull from inside, one registry.

Write this down wherever the question resurfaces, because the wrong inference is
expensive: a request to "let the pipeline reach the registry" must **not** be answered
with NAT, an Internet Gateway, or an egress proxy. Nothing inside the VPC ever contacts a
public registry. **This asymmetry is what lets the air-gap hold while the supply chain
still works.**

**The single most important line:** GitHub Actions never touches a cluster or an AWS
environment. It builds, mirrors and publishes. Octopus deploys. This is not ceremony —
Actions runners have internet and the VPC does not, so a runner that could deploy would
have to be inside the VPC, which would put an internet-connected agent inside the
air-gap. The boundary *is* the control.

---

## 3. Decisions

| ID | Decision | Status |
|---|---|---|
| **CD-1** | **Octopus deploys both the Helm releases and the Terraform applies** — not Helm alone. Octopus owns the apply order `shared → runner → chain → app`. | DECIDED |
| **CD-2** | **GitHub Actions never deploys.** It mirrors, packages, publishes and creates releases. Nothing in CI holds a path into the VPC. | DECIDED |
| **CD-3** | **Two workflows, not one.** `supply-chain.yml` (mirror upstream → ECR) and `release.yml` (package platform → Octopus). Different triggers, different cadence, different blast radius: the mirror runs when a *pinned version* changes; the release runs on merge. | DECIDED |
| **CD-4** | **Three Octopus projects, not one** (§5). Separating them is what makes an unsafe deployment hard to trigger by accident. | DECIDED |
| **CD-5** | **The validator Helm release is NEVER deployed by a standard Helm step.** It lives in its own project, behind a manual-intervention gate, and its only deploy mechanism is `scripts/maintenance/rolling-besu-apply.sh`. See §6. | DECIDED — safety-critical |
| **CD-6** | ~~**Two environments: `DEV` and `PROD`.** No UAT.~~ **SUPERSEDED 2026-09-09 by CD-40** — three environments, `sit`/`uat`/`prod`. Terraform values are lowercase `dev`/`prod` (used in resource names and tags); the Octopus environments are the uppercase names. | DECIDED |
| **CD-7** | **Both environments run in `af-south-1`.** A deploy-test in another region does not prove endpoint-service availability, per-AZ instance-type availability, or AZ IDs — the three things most likely to break. Costs ~31% more than us-east-1; the guardrail buys fewer hours. | DECIDED |
| **CD-8** | **One version scheme:** `YYYY.MM.DD.<run_number>`, used as *both* the package version and the Octopus release number. The reference pipelines used two different schemes in one workflow; one is enough. | DECIDED |
| **CD-9** | **GitHub OIDC → IAM role assumption.** No long-lived AWS keys in GitHub. (During personal-environment bring-up a key pair may be used; it must not survive into the bank environment.) | DECIDED |
| **CD-10** | **No bank-specific value is ever committed.** Account ID, registry host, repo prefix, org, runner labels, Octopus URL/space — all GitHub variables/secrets or tfvars. Workflows are portable between the personal and bank environments by changing configuration only. | DECIDED |
| **CD-11** | **Two distinct copy paths, never confused.** Upstream *images* → `crane copy` / `skopeo copy --all` (digest-preserving, D-18). Our *packages* → `docker build` of a `FROM scratch` wrapper. | DECIDED |
| **CD-12** | **Versions come from one manifest in the repo**, read by both the workflow and Terraform — never restated in workflow `env:`. Mirrors how `verify-images.sh` resolves its list *from* Terraform. | DECIDED |
| **CD-13** | **SonarQube / Checkmarx deferred.** Re-introduce the bank's shared security-checks workflow at bank onboarding. | DECIDED (deferred) |
| **CD-14** | **Octopus must serialize deployments per project+environment.** Two concurrent Terraform applies against one root contend on the **S3-native** state lock (`use_lockfile`, a `.tflock` object in the state bucket — **no DynamoDB table**, deprecated since Terraform 1.11); the second fails late and confusingly. Locking therefore needs only the S3 gateway endpoint, one fewer dependency in the air-gapped VPC. | DECIDED |
| **CD-15** | **PROD requires manual approval.** DEV may auto-deploy on merge. A ledger does not deploy itself. | DECIDED |
| **CD-16** | **Every deployment ends with a chain-integrity check (H35)** — block height advancing, all validators in the set, no fork. A green Helm step is not evidence the chain is alive. | DECIDED |
| **CD-17** | ~~**GitHub-hosted runners + OIDC are the default build host.**~~ **REVERSED 2026-09-09 by CD-26** — the cloud team has a self-hosted runner estate and asked us not to stand one up. The reasoning below is kept because it is still the argument for the *fallback* (CodeBuild, no VPC attachment) if CD-26's egress question comes back negative: GitHub-hosted runners always have internet, so ECR push needs only an IAM role trusting GitHub's OIDC issuer — no machine, no network, no egress question. That is what *used* to make #26 informational. It no longer is. | **REVERSED** |
| **CD-20** | **State keys are environment-scoped: `besu/<env>/<root>.tfstate`.** They were `besu/platform/<root>.tfstate` until 2026-09-07 — the same four keys for DEV and PROD, so the second environment applied would have reconciled its config against the first's state. Four states separate the four *roots*; `<env>` separates the two *environments*. Both dimensions are required. | DECIDED |
| **CD-21** | **The workflow must WAIT for the Octopus deployment, not just queue it.** `deploy-release-action` returns as soon as the deployment is queued — a failed deployment reports green in GitHub. Use `OctopusDeploy/await-task-action` fed from the deploy action's `server_tasks` output. Without this **CD-16's chain-integrity check never runs**, and a job that exits green before the deployment finishes is worse than no check at all. | DECIDED |
| **CD-22** | **A release is an immutable snapshot of the process AND the variables.** Fixing the live deployment process does NOT fix an existing release; redeploying an old one replays the old configuration. **Any process or variable change requires a new release.** Safety-critical here: someone corrects the validator rolling step, redeploys an existing release, and silently gets the OLD, unsafe process (CD-5). This must be stated in the validator runbook, not just known. | DECIDED |
| **CD-23** | **Octopus steps run in an execution container, pinned to the same Terraform as CI.** Hosted Octopus workers do not ship Terraform. The container must be `hashicorp/terraform:<the version in runner-tools.manifest>` — not `worker-tools:latest` — because state records the version that last wrote it, and a newer Terraform can refuse or rewrite state across our four state files. | DECIDED |
| **CD-24** | **That container image is mirrored into ECR, and ECR is registered in Octopus as a Docker feed.** Octopus resolves every container image through a registered feed, and in an air-gapped VPC the image cannot come from Docker Hub. Adds one image to the mirror list and one feed to the Octopus setup. | DECIDED |
| **CD-25** | **Every Octopus variable that selects an environment MUST be scoped to that environment.** An unscoped `Environment = dev` resolves to `dev` in *every* environment including PROD — pointing a production deployment at the DEV state file and naming resources `dev`. With CD-20 this is the single most dangerous misconfiguration available in the Octopus project. Verify scopes as a step in the setup checklist, not by assumption. | DECIDED |
| **CD-19** | **A build host is REQUIRED regardless of registry topology — only the *ask* is conditional.** The bytes must flow `public registry → a machine with internet → ECR`; pull-through cache cannot bridge it (D-17) and ECR replication is ECR-to-ECR only. Under #25a every piece (GitHub's runner, our IAM role, our repositories, ECR's public endpoint) sits outside the cloud team's control surface, so the requirement stands while the request disappears. **For bring-up, the laptop is a legitimate fourth option** — not for go-live: no audit trail of what was mirrored by whom, no repeatability, and a bus factor of one. | DECIDED |
| **CD-18** | **The two workflows are split by artefact sensitivity, and may run in different places.** `supply-chain.yml` handles **public** upstream images and charts only — nothing confidential is ever on that runner. `release.yml` packages **our own** source. If policy permits GitHub-hosted runners for the first but not the second, the split already exists and costs nothing to honour. Decide this deliberately rather than seeking one blanket approval. | DECIDED |
| **CD-26** | **CI runs on the cloud team's self-hosted GitHub runners, not GitHub-hosted ones.** Answered on the 2026-09-09 call: they operate a runner estate and advised against us provisioning one. This **reverses CD-17** and makes **#26 a real dependency** instead of an FYI — the whole supply chain now rests on whether those runners can reach `docker.io`, `ghcr.io`, `quay.io` and `registry.k8s.io`. **→ R-2, and it is blocking.** Side effect: **CD-18's public/confidential workflow split becomes moot** — both workflows run in the same place — but keep the split in the workflow files anyway, because it costs nothing and it is the thing that makes a future policy change a one-line move. | DECIDED |
| **CD-27** | **ECR is in a central shared-services account (#25b).** Consequences, none of them optional: **#23 is mandatory**, not advisory; cross-account **repository policies** must grant pull to our node role and In-VPC EC2 Runner role; we do **not** build a `modules/registry` Terraform module, because we cannot create repositories in an account we do not own — repository creation becomes a request or a scoped cross-account role. **The two settings we assumed are now negotiations**: tag immutability is off by default, and a shared registry very probably carries a **lifecycle expiry policy** — which would delete the exact digest a validator replaced eleven months from now must pull. **→ R-5.** | DECIDED |
| **CD-28** | **ECR is a REGIONAL service and the `ecr.dkr` endpoint reaches only its own region.** If the central registry is not in `af-south-1`, images pushed to it are unreachable from this VPC and **no endpoint policy fixes it** — the remedy is an ECR replication rule in the central account. The `prod-<region>-starport-layer-bucket` ARN in #20 follows the same region, so getting this wrong breaks #20 as well, and it breaks it *halfway through a layer download* rather than at authentication. **→ R-4.** Not previously asked, because under #25a the region was ours by construction. | DECIDED |
| **CD-29** | **The VPC endpoints are the cloud team's to create — all 16.** We are a tenant in an account we do not own. `terraform/shared` must therefore stop *creating* interface endpoints in the bank environment and start *asserting* them, the way `modules/network-contract` already asserts the rest of the network. Add `create_interface_endpoints` (true for `mimic_vpc`, false in the bank) plus one assertion per endpoint quoting its requirement number. **The SSM trio has no workaround**: Session Manager is the only path to the In-VPC EC2 Runner, which is the only path into the cluster. **→ R-6.** | DECIDED |
| **CD-30** | **"We are a tenant in the cloud team's account" is still ambiguous, and the ambiguity is load-bearing.** Single account (our roles inside theirs) versus two accounts (their VPC RAM-shared into ours) changes what is *impossible* versus what is merely *not yet granted* — under RAM, AWS forbids a participant from creating endpoints, route tables or NACLs and no IAM grant can change that; in a single account those are ordinary permissions. It also **guts #23's proposed control**: `aws:PrincipalAccount` is near-meaningless if every tenant shares the account, and must become `aws:PrincipalArn` with a wildcard over an agreed IAM path. Do not write either policy until this is answered. **→ R-3.** | OPEN — blocking |
| **CD-31** | **CQ-1 is NOT closed by "cloud-hosted in their account".** That phrase reads both as *self-hosted on their AWS infrastructure* (workable) and as *Octopus Cloud SaaS* (fatal to the CD design — nothing in a no-egress VPC can reach it). The disambiguator is one string: an Octopus Cloud instance URL ends in **`.octopus.app`**. **→ R-1.** Until it is answered, do not build the Octopus process; the fallback shape is different enough that the work would be thrown away. | OPEN — blocking |
| **CD-32** | **If Octopus is self-hosted, prefer making the in-VPC In-VPC EC2 Runner a polling Tentacle worker over installing the Kubernetes Agent — but verify first.** The Kubernetes Agent is a deployment target for Kubernetes steps; it does **not** give us a place to run the *in-cluster Terraform layer* (the StorageClass, the Secrets Store CSI driver), which needs a host with Terraform and a route to the private EKS endpoint. The In-VPC EC2 Runner is already exactly that host, already has the toolchain from the S3 bundle, and already polls nothing inbound. One machine would then cover Terraform, Helm, kubectl and `rolling-besu-apply.sh`. **It also dissolves CQ-1's chicken-and-egg** — a Tentacle is a binary we can add to `runner-tools.manifest`, whereas the agent is a Helm chart whose images must be mirrored into ECR before it can install. **Verify before committing:** that a Linux Tentacle is distributable as a tarball rather than only through apt/yum (which we removed by D-21), and that a polling Tentacle worker satisfies the same outbound-only network shape. | PROPOSED |
| **CD-33** | **CQ-1 IS CLOSED, AGAINST US: Octopus is Octopus Cloud (SaaS).** Confirmed 2026-09-09 from the instance URL (`https://<instance>.octopus.app`) and its certificate (`*.octopus.app` — Octopus Deploy's own domain; a self-hosted server would carry a bank domain). **Every Octopus mechanism for deploying into a private network — Kubernetes Agent, polling Tentacle, listening Tentacle — requires the agent to reach `<instance>.octopus.app` on the public internet, and this VPC has no route there.** This is not a firewall or permission problem; there is nowhere for the packet to go. §7 of this document is therefore conditional on egress being granted. | DECIDED |
| **CD-34** | **SUPERSEDED 2026-09-14 by CD-55 — kept as the fallback if the egress path is ever withdrawn.** Was the working assumption while R-9 was open: SPLIT BY LAYER. Octopus Cloud's hosted workers have internet and **AWS API endpoints are public**, so Octopus can run the whole AWS-API Terraform layer (`shared`, `runner`, the AWS half of `chain`/`app`) today with nothing new from anyone — including its release management, approvals and audit trail. Everything touching the **Kubernetes API** (in-cluster Terraform, Helm releases, validator upgrades) falls back to the **in-VPC In-VPC EC2 Runner over SSM**, which is the already-prod-verified process. **Name the cost every time this is discussed: CD-5's tool-enforced validator gate is lost**, leaving H1's three structural controls (Terraform `ignore_changes`, `updateStrategy: OnDelete`, the H38 plan-safety CI check) plus operator discipline. That is defensible and it is what we do today — but it is weaker than a gate nobody can click past, and the failure it guards against is a chain halt. | SUPERSEDED (fallback only) |
| **CD-35** | **R-9 is the highest-value question in the programme: how do other bank teams deploy into private AWS environments from this same Octopus Cloud instance?** The reference pipelines deploy Kubernetes workloads through Octopus, so **a working pattern already exists in this organisation.** Adopting it beats inventing a fourth thing. If it turns out to be a central egress proxy or NAT reachable over the Transit Gateway, our ask collapses to **one hostname, outbound only, on the polling port** — narrow enough to be a normal firewall request rather than an architecture change. **This reverses Section C of the sent document**, which said we were not asking for NAT or a proxy; that was written assuming Octopus was internal. Say so plainly rather than pretending the earlier position still holds. **ANSWERED 2026-09-14: it is exactly this** — a shared central egress behind a load balancer; see CD-55. | ANSWERED |
| **CD-36** | **If egress to Octopus Cloud IS granted, use a polling Tentacle on the In-VPC EC2 Runner (CD-32), NOT the Kubernetes Agent.** Both need the same egress, so the network ask is identical — but the Tentacle gives a host that can run the **in-cluster Terraform layer** (StorageClass, Secrets Store CSI) which the Kubernetes Agent cannot, reuses a machine that already has the toolchain, and needs no chart or images mirrored before it can install. The agent's only advantage (native Kubernetes target semantics) does not pay for a second bootstrap dependency. **Verified 2026-09-14:** the Linux Tentacle ships as a tarball (`Linux_x64TarGz`), so it goes into `runner-tools.manifest` like every other tool (CD-59) — D-21 holds. **Unconditional since R-9 closed on option 1 (CD-55).** Configuration detail in CD-57. | DECIDED |
| **CD-37** | **Working assumption: SINGLE-ACCOUNT tenancy.** Our credentials resolve to the same account that owns the VPC; our clusters, roles, KMS keys and state live there. Taken as an assumption on 2026-09-09, **not confirmed** — the confirmation is one command (`aws sts get-caller-identity`) and costs nothing, so run it the moment credentials exist. **If it is wrong** (RAM-shared into a separate workload account), AWS structurally forbids us creating endpoints, route tables or NACLs, and CD-38/CD-39 still hold — so the design does not collapse, but the ownership table in the sent document reactivates. **`af-south-1` is confirmed enabled on the account** — it is an opt-in region and this was the one answer that could have stopped everything on day one. | ASSUMED |
| **CD-38** | **#23's principal-scoping request is WITHDRAWN — it was written for the wrong shape.** We asked the cloud team to scope the ECR endpoint policy with `aws:PrincipalAccount` = our account. Under CD-37 that is **meaningless** (every tenant satisfies it) **and harmful** (the endpoint is shared, so scoping it to our roles breaks other tenants). What survives is two *verifications* on a policy they already have: that `ecr:GetAuthorizationToken` is permitted with `Resource: "*"`, and that `Resource` is not narrowed to one account's repositories (the af-south-1 EKS addon registry is `877085696533`). **The lesson generalises: a control we design for our own account can be actively wrong on shared infrastructure**, and #20 has the same shape — verify, do not re-scope. | DECIDED |
| **CD-39** | **`central_interface_endpoints = true` is the PRODUCTION setting, not a fallback.** In a shared VPC the endpoints almost certainly already exist, because other tenants need ECR, STS and SSM too — and **AWS permits only ONE endpoint per service per VPC to have private DNS enabled**, so a duplicate of ours would have to run with private DNS *off*, which makes it useless to us and bills ~USD 7/mo per AZ for nothing. The toggles already exist (`central_interface_endpoints`, `gateway_endpoints_exist` in `terraform/shared/handover.tf`); **what was missing was verification**, since nothing checked that centrally-run endpoints were configured the way we need. Closed by `scripts/preflight/verify-endpoints.sh`. | DECIDED |
| **CD-40** | **THREE environments: `sit`, `uat`, `prod`** (was `dev`/`prod`). Octopus environments SIT, UAT, PROD. **Supersedes CD-6.** Each has its OWN CIDR allocation and therefore its own `network-handover.auto.tfvars`, which makes the environment tfvars **non-interchangeable in a way the old two-environment setup was not**: pairing one environment's `common.tfvars` with another's hand-over points a cluster at another environment's subnets, and the network-contract gate cannot catch it because both files are internally consistent. State keys stay `besu/<env>/<root>.tfstate` (CD-20 already covers three as easily as two). `verify-images.sh` **lost its default environment** — with three, a defaulted `-e` resolves the image list from one environment while the operator believes they are checking another. | DECIDED |
| **CD-41** | **Promotion gates: SIT may auto-deploy on merge; UAT and PROD both require approval.** CD-15 said "PROD requires approval, DEV may auto-deploy". With three environments the middle one is the question, and UAT is where business sign-off happens — an environment that redeploys itself under a tester is not a UAT environment. The Octopus service account (CQ-6) is therefore scoped to **SIT only**, not "everything but PROD". | DECIDED |
| **CD-42** | **We are ASKING FOR A `/20` PER ENVIRONMENT (4,096 addresses), not designing around the offered /24s.** Decided 2026-09-09. The published subnet plan allocates **2,880** across 15 subnets and was derived for a /20, leaving a **30% reserve** — and the reserve is the substance of the ask, because a **VPC's primary CIDR is immutable after creation** and a routine node-group upgrade runs old and new nodes side by side, doubling node address consumption for its duration. Offered: SIT `10.103.53.0/24` (256), UAT `10.103.0.0/21` (2,048), PROD `10.108.13.0/24` (256). **Floor if refused: `/21`**, plan re-derived (ledger stays 3 × /24, app drops to 3 × /25, small subnets to /27 — uses 1,440 of 2,048). **`/22` is degraded** (~2 nodes per AZ, needs `WARM_IP_TARGET` tuning that slows pod starts and risks EC2 throttling). **`/24` only with CNI custom networking** — Appendix A of the review, deliberately not the plan. Sendable: `docs/CIDR_ALLOCATION_REVIEW.md`. | DECIDED |
| **CD-45** | **Whatever size is agreed, all three environments get the SAME size.** SIT and UAT exist to de-risk PROD and only do that if they are the same *shape*. PROD on default networking at /20 while SIT runs custom networking at /24 means a green SIT deployment proves very little — and the differences surface during the production deployment, which is the exact moment lower environments exist to avoid. **If only one environment can be enlarged it must be PROD**, and we then say explicitly that SIT and UAT have stopped being faithful rehearsals. | DECIDED |
| **CD-46** | **`supply-chain.yml` + `scripts/supply-chain/{mirror.manifest,mirror.sh}` — BUILT 2026-09-09.** The workflow is thin; the logic is a script, so it can be run and tested from a laptop for bring-up (CD-19) and so CI is not the only way to exercise it. 23 images across 5 upstreams (`docker.io` 5, `ghcr.io` 5, `quay.io` 5, `registry.k8s.io` 5, `public.ecr.aws` 3) plus the 5 pinned charts. Copies **by digest** with `crane`, never `docker pull/tag/push` (D-18). Triggers only on `workflow_dispatch` and changes to the manifest itself — mirroring is idempotent but pulls from rate-limited registries, so re-running it is a decision (CD-3). **2026-09-18: relocated to the monorepo root** — GitHub runs workflows only from `.github/workflows/` at the repository root, and the platform is now the `sbsa_besu/` subtree; the job sets `working-directory: sbsa_besu` and the path filters carry the prefix. The scripts were already cwd-independent. ~~**It has never run in CI**~~ — **FIRST CI RUNS 2026-10-10** (GitHub-hosted `ubuntu-latest`, OIDC via `mimic_registry`, CD-66): run 1 refused at the assume (ID-suffixed `sub`); run 2 assumed, then the dry run died on missing repositories (fixed: `--dry-run` now reports them); run 3 dry run green, all 28 upstream artefacts resolved; **run 4 (`38040455269`, 9m28s) mirrored all 23 images and 5 charts into 28 new IMMUTABLE, scan-on-push repositories under `mirror/`**, each verified present at its version afterwards. Digests read back from ECR are recorded in the manifest and pinned on the 8 platform images in `terraform/chain/variables.tf`; `--check-drift` now compares digests as well as tags. (Before: the pre-merge `sbsa_besu` repository had no GitHub remote.) `--check-drift` and the manifest lookups were re-verified locally from the new layout. Before the first run: repository variables `CI_RUNNER_LABELS` (`["ubuntu-latest"]` in the personal environment, CD-17), `AWS_REGION`, `ECR_PREFIX`; secrets `AWS_ECR_PUSH_ROLE_ARN`, `ECR_REGISTRY`; and the GitHub OIDC provider + push role in the target account (CD-9; the `sub`-claim note in §9a). | DONE |
| **CD-47** | **Tag immutability makes "already present" a first-class outcome, and "different digest, same tag" an ALARM.** Because immutability is enabled registry-wide, a re-push over an existing tag *fails* rather than overwriting — so the mirror must check before copying. Three distinct outcomes, and conflating them is how a supply chain rots quietly: **same digest** → already mirrored, skip; **no digest** → copy; **different digest for the same tag** → stop and report, because the upstream tag has moved and that is precisely the substitution digest pinning exists to prevent. A fourth check guards the manifest itself: if a row pins a digest and the upstream tag no longer resolves to it, refuse to mirror. `--record` writes resolved digests on **both** the copied and already-present paths — recording only what a run happened to copy means the steady state (everything present) records nothing — but **never on the conflict path**, because pinning a digest that is in an unexplained conflict would launder the problem into the manifest. | DECIDED |
| **CD-48** | **`mirror.sh --check-drift` is the enforcement behind CD-12.** The 8 platform images live in two places by necessity — `var.container_images` is what Terraform deploys, the manifest is what CI mirrors, and Terraform cannot read a TSV. Drift means the mirror copies a version the cluster never requests while the one it does request is absent, presenting as `ImagePullBackOff` against a registry that looks fully populated. The check runs **first in the workflow**, before AWS credentials or any public registry, so it fails fast and free. | DECIDED |
| **CD-49** | **A runner label describes the RUNNER, not the deployment target — and if the runners are pods, our AWS auth step is the wrong code, not the wrong setting.** The reference pipelines use `[self-hosted, kubernetes]`, which is *consistent with* an Actions Runner Controller estate (two labels are not proof). If it is ARC, the pod's service account is usually IRSA-annotated, so credentials are already in the environment and `configure-aws-credentials` should be **deleted rather than configured** — a different piece of code, not a different value. → **R-7.** Two consequences worth holding on to: choosing a runner *because* it sits near Kubernetes is how **CD-2** erodes, since Actions holding no path into the ledger VPC is the entire boundary; and a daemonless pod cannot run `docker build`/`push` at all, so **`crane` — chosen for digest preservation (D-18) — also happens to be the only mechanism that works there.** | DECIDED |
| **CD-50** | **GitHub-hosted runners are probably still available for public-artefact jobs, and that is worth confirming rather than assuming in either direction.** `sample2.yaml` runs a trivial job on `ubuntu-latest` and its AWS-touching jobs on `[self-hosted, kubernetes]`, so "do not stand up any GitHub Actions runner" reads as being about **provisioning our own**, not about never using GitHub-hosted. If that holds, `supply-chain.yml` — which handles only **public** upstream images and charts, with nothing confidential ever on the runner — is exactly the job that can run there, and **CD-18's split stops being hypothetical**. Asked as part of R-7. **Flagged as an inference from two sample files, which is a source that has misled this design before** (CQ-2 was once addressed to the wrong team on the same evidence). | OPEN |
| **CD-51** | **One home per pinned tool version, decided by how many hosts depend on it.** `scripts/runner/runner-tools.manifest` is the pin, read by `push-runner-bundle.sh` and by the workflows through `tool_version`/`tool_url`/`tool_sha` in `scripts/lib/common.sh`. **The rule: a version more than one host depends on lives in the manifest; a version exactly one host depends on stays with that host.** So `terraform` (CI validates and plans with it, Octopus's execution container runs it, the runner applies with it) and `helm` (CI pulls and pushes charts, the runner installs them) live in the manifest, while `crane` stays pinned in `supply-chain.yml` because CI is its only consumer and putting it in the manifest would ship it in the runner's S3 bundle for nothing. Terraform is the case where this is not a preference: **state records the version that last wrote it**, so a CI runner and an Octopus container on different versions can refuse or rewrite state across the four state files (CD-23). Before 2026-09-10 the helm version was written in two places held together by a "keep in sync" comment, which is the weakest available form of enforcement. A tool absent from the manifest is **fatal**, not empty — an unset version interpolated into a URL fetches a 404 page and surfaces three steps later as a corrupt archive. | DECIDED |
| **CD-52** | **The manifest's digest column is the trust anchor, and it is now populated.** All four artefacts recorded 2026-09-10 (`push-runner-bundle.sh --record`): kubectl `v1.35.8`, helm `v3.21.4`, terraform `1.16.1`, Corretto `17.0.20.10.1`. Both the bundle build and CI now verify against **our** pin. The fallback — a vendor-published checksum file fetched from the same host as the download — is barely verification at all, so it is used only while a column reads `-` and emits a `::warning::` when it fires. Re-run `--record` only when a pinned version changes, and review the diff: a digest that moves under an unchanged version is the supply-chain substitution this whole mechanism exists to catch. | DONE |
| **CD-53** | **Octopus triggers, gates and records. The EC2 runner executes and is break-glass. They are NOT alternatives.** "Runner vs Octopus" is a false binary: Octopus replaces the *human deciding to run a command*, not the *host that runs it* — something inside the VPC always executes the kubectl/helm calls, and an Octopus Cloud hosted worker can never be that thing. Scored against long-term operation: **project management → Octopus** (release records, promotion, an answer to "what is in UAT" that is not a wiki page); **node upgrades → Octopus for the gate, runner for the execution** (the enforced gate is the difference between a runbook saying "one at a time" and a tool refusing otherwise, but recovery wants a shell — `rolling-besu-apply.sh` re-runs safely since it checks each validator's image and readiness, so the issue is diagnosis, not resumability); **code updates → phase-dependent**, runner during bring-up because a six-step pipeline per iteration is brutal, Octopus at steady state because changes are rare and traceability outranks iteration speed; **debugging → the runner, decisively** — Octopus task logs answer "why did the deploy fail" and are useless for "why is validator 3 not producing blocks". **The structural conclusion: break-glass is independent of the deployment mechanism, so the runner is required regardless of who deploys.** If R-9 grants egress, use a polling Tentacle on the runner (CD-36), not the Kubernetes Agent — the agent cannot run the in-cluster Terraform layer, needs its own chart and images mirrored before it can install, has no `keytool`, and gives no shell. The expected objection (a persistent host with cluster-admin and broad IAM) is answered by mitigation, not removal: start-on-demand/destroy-after, an IAM permissions boundary, SSM-only access with no SSH/inbound/public IP, and SSM session logging. Removing it trades an auditable, ephemeral, boundaried host for **an inability to diagnose a halted ledger** — the wrong side of that trade for a payment system, and the halt is exactly when you have least time to build one. | DECIDED |
| **CD-54** | **IMPLEMENTED 2026-09-10 behind `runner_scope`, default off.** **CD-53 lets the runner's IAM shrink hard, because the AWS layer moved to Octopus — and the minimum is a FUNCTION of that split, not an absolute.** Most of the runner's current breadth exists because it could historically apply the whole `chain` root. With `besu-infra` owning the AWS layer, the runner needs only: reach the cluster (`eks:DescribeCluster` + `sts:GetCallerIdentity` for the exec-auth token), its own state and remote state in S3, its bootstrap artefacts, scoped Secrets Manager for the PKI and permissioning scripts, cross-account ECR **pull** for `verify-images.sh`, `ec2:Describe*` for `verify-endpoints.sh` and diagnosis, and the SSM managed-instance policy. **Droppable outright: all IAM writes, `kms:*`, `cloudtrail:*`, `acm-pca:*`, `sns:*`, `resource-groups:*`, and the write half of `ec2`/`eks`/`elasticloadbalancing`/`logs`/`cloudwatch`** — every one is an AWS-layer concern, and the runtime consumers (Fluent Bit, the load-balancer controller, the pods that decrypt node keys) hold their own IRSA roles rather than borrowing the runner's. **Two further separations worth taking:** teardown must NOT sit on the steady-state role — `full-delete.sh` is a distinct and dangerous capability, and the existing practice is that a laptop-driven destroy is safest anyway; and EKS **cluster-admin need not be the same access entry as break-glass**, so consider a second read-mostly entry for diagnosis and keep admin for the deployment window. **This change fails at apply time, not plan time**, which is how IAM reductions always fail — put it behind a variable and validate it on a mock with the boundary in place, exactly as H5's residual still requires. **Shipped as:** `runner_scope = "full-stack" \| "in-cluster"` (default `full-stack`), a self-contained `terraform/runner/deploy-policy-incluster.tf` rather than eight `dynamic` blocks threaded through the hardened `deploy-policy.tf`, and `scripts/validation/simulate-runner-policy.sh` to screen the action list for free before a billed apply. **Two corrections found while implementing:** `kms:*` is NOT droppable to nothing — a Secrets Manager secret encrypted with a customer-managed CMK (which is what C12 does to the node and CA keys) cannot be read without `kms:Decrypt` on that key, and the failure names KMS rather than Secrets Manager, sending the reader to the wrong file; the narrow form is Decrypt/Encrypt/GenerateDataKey/DescribeKey, ABAC-scoped. And the full-stack policy **had no ECR permissions at all** — an omission from the move to ECR that would have failed `verify-images.sh` from the runner, the one place the RUNBOOK insists it must run. Fixed in both modes. | IMPLEMENTED (needs apply-validation) |
| **CD-55** | **R-9 CLOSED 2026-09-14 — OPTION 1. The bank has a shared central egress; the ledger VPC may use it.** What the cloud team said: egress exists, it is **not dedicated to us**, and it is fronted by **a load balancer for outbound traffic and a second load balancer for internal traffic**. What they will not say: how it is built. That is a reasonable position for a shared service and we do not push on it — **every remaining question is answered on our side as a design assumption** (CD-56..CD-60), each chosen because (a) it is the most likely reading of "a load balancer you send traffic to", (b) it is the choice that keeps D-3 (design for air-gap) intact, and (c) the fallback if the assumption is wrong is a one-line configuration change, never a redesign. Consequences: **CD-34 is superseded** (kept as fallback), **CD-36 becomes unconditional**, `besu-workloads` and `besu-validators` are buildable, and **CD-5's tool-enforced validator gate is back** — which was the whole point of asking. The mimic reproduces the assumed shape so the Octopus path can be deploy-tested before the bank's is available (CD-63). | DECIDED |
| **CD-56** | **ASSUME AN EXPLICIT FORWARD PROXY (HTTP `CONNECT`) AT A LOAD-BALANCER VIP, addressed as `host:port`, allowlisted by destination and by source.** Three reasons. **(1) It is what the words mean:** a load balancer is something a client *addresses*; a transparent design would be a default route to a firewall, which nobody describes as a load balancer. **(2) It is the shape that preserves D-3:** with an explicit proxy, nothing in the VPC has egress unless it is *configured* to use the proxy, so the air-gap posture we argued for survives — the ledger route tables gain a route to the egress VIP's prefix, never `0.0.0.0/0`. A transparent path would silently hand every pod and node a route out. **(3) The fallback is trivial:** if it turns out to be transparent, delete the `polling-proxy` setting — one command — and nothing else changes. On our side this is two variables, `egress_proxy_host` and `egress_proxy_port`, supplied by the cloud team as a client-configuration value (the one "internal" fact we do need — it is no more internal than a DNS server address). Proxy authentication: assume none; the Tentacle supports username/password if the bank requires it, so ask, don't design for it (R-10). | DECIDED (assumption; fallback = remove proxy setting) |
| **CD-57** | **TENTACLE CONFIGURATION: POLLING-PROXY ON, WEB-REQUEST PROXY OFF, registered as a WORKER, polling `polling.<instance>.octopus.app` on 443.** The Tentacle has **two** independent proxy settings and the difference matters here. `Tentacle polling-proxy` governs only the Halibut connection to Octopus Server — that one goes through the bank proxy. `Tentacle proxy` (the web-request proxy) is **exported by Tentacle to Calamari and to every step script as `http_proxy`/`https_proxy`** (Octopus docs, proxy-support) — enabling it would send `terraform`, `aws`, `kubectl` and `helm` at the bank proxy instead of at the VPC endpoints and the private EKS endpoint, and everything would fail or, worse, leak. **So the web-request proxy stays OFF and no host-wide `HTTP(S)_PROXY` is ever set on the runner.** Two consequences that are easy to miss: **(a)** the one-shot `register-worker` REST call does *not* use the polling proxy on Linux (known Octopus support thread), so the bootstrap runs that single command with `https_proxy=` scoped to its own environment and nothing else; **(b)** at runtime the worker needs *only* Halibut — packages are pushed to a Tentacle over the Halibut channel, health checks and script execution ride it too — so the allowlist stays at two hostnames (CD-59). Registration shape: `create-instance` → `configure --noListen True --reset-trust` → `polling-proxy --proxyEnable=true --proxyHost=<egress_proxy_host> --proxyPort=<egress_proxy_port>` → `register-worker --server https://<instance>.octopus.app --server-comms-address https://polling.<instance>.octopus.app --comms-style TentacleActive --workerPool <env>-ledger-workers` (omit `--server-comms-port`; requires Tentacle ≥ 6.3.417). **Worker, not deployment target:** the runner is not the thing being deployed to. The Kubernetes deployment target for each environment is configured to execute on that worker pool, which is how Octopus's own model reaches a private endpoint — the worker is inside the VPC. Runs as the runner's non-root deploy user under systemd (`Tentacle service --install`). | DECIDED |
| **CD-58** | **TLS: THE OCTOPUS PATH MUST NOT BE DECRYPTED — and that is not our preference, it is Octopus's protocol.** "Do not enable SSL offloading for Tentacle Communication — the Tentacle communication protocol uses Client Certificate Authentication and requires an uninterrupted TLS tunnel" (Octopus docs). Tentacle and Server pin each other's certificate thumbprints; a proxy that re-signs presents a different thumbprint and the connection is rejected. **This corrects the follow-up document's §2.2**, which said the agent "would need the proxy's CA certificate" — no CA bundle makes an intercepting proxy work here. If the bank's egress inspects by default (common), the ask is a **no-decrypt exception for the two Octopus hostnames** — a normal firewall-ticket item, and one other teams using Tentacles or similar mutually-authenticated agents will already have needed. **Fail-fast test at first connection:** `openssl s_client -proxy <host:port> -connect polling.<instance>.octopus.app:443` from the runner and compare the presented certificate to the one the instance shows from an uninspected network; a mismatch means inspection, before any registration is attempted. In the mimic the proxy is a plain `CONNECT` tunnel with no SSL-bump (CD-63). | DECIDED |
| **CD-59** | **PORT 443, EXACTLY TWO DESTINATION HOSTNAMES, AND NOTHING ELSE ON THE ALLOWLIST.** Octopus Cloud accepts polling on 10943 or — via a reverse proxy on their side — on **443 at `polling.<instance>.octopus.app`** (Tentacle ≥ 6.3.417, no WebSockets). Bank proxies allow `CONNECT` to 443 as a matter of course and to 10943 as an exception; we take the path that needs no exception. The two hostnames: **`<instance>.octopus.app`** (REST — registration and any `octo` CLI use) and **`polling.<instance>.octopus.app`** (Halibut). **Not** `download.octopus.com` — the Tentacle tarball is a **pinned, digest-recorded row in `runner-tools.manifest`** delivered through the S3 gateway endpoint like every other tool (CD-51/52; D-21 holds), so the allowlist never quietly grows to a third host. **Not** a `*.octopus.app` wildcard — that would also admit every other customer's instance. **Not** Octopus's published static IPs as a substitute for the hostnames: offer them to the bank if their proxy allowlists by IP, but the hostname rule is what we ask for. In the mimic these are the only two `dstdomain` entries and `CONNECT` is permitted to 443 only (CD-63). | DECIDED |
| **CD-60** | **SOURCE AND ROUTE: THE RUNNER GETS A PINNED PRIVATE IP so the allowlisted source is a /32; the route to the egress VIP is a specific prefix in the ledger route tables, added by the cloud team — never a default route.** The runner sits in the first ledger subnet, which it **shares with EKS nodes** (`terraform/runner/main.tf`: `private_subnet_ids[0]`) — so "route only for the runner" is not available, and neither is a security-group distinction pods cannot inherit (pods share the node SG). The controls are therefore layered and honestly stated: **(1)** the bank's proxy allowlists by source, and a pinned `runner_private_ip` lets us give them a **/32** — ask for it, accept the subnet `/24` if they insist; **(2)** no process in the VPC other than the Tentacle's polling channel is configured with a proxy (CD-57), and no route table has a default route (mimic rule #2 stands); **(3)** when the H6 NetworkPolicy is on, no allow rule names the egress prefix, so pod egress to the proxy is denied at the CNI as well; **(4)** the route is a **specific prefix** for the egress VIP's CIDR, in the ledger route tables only — not app, lb, endpoint or data. In production the cloud team adds it as a Transit Gateway route (exactly the "TGW routes to on-premises destinations" the hand-over already anticipates); in the mimic it is a peering route (CD-63). Pinning the IP also makes stop/start (CD-61) and destroy/recreate produce the same source address. | DECIDED |
| **CD-61** | **RUNNER LIFECYCLE WITH A REGISTERED TENTACLE: STOP/START, NOT DESTROY/RECREATE — and the pipeline does the starting.** A polling Tentacle is registered by certificate thumbprint; a recreated instance has a new certificate and a dead registration. Stop/start keeps the root volume, the Tentacle certificate, the registration and (with CD-60) the private IP, and costs only the stopped EBS. It is compatible with CD-53's "on-demand host" mitigation: **the first step of `besu-workloads`/`besu-validators` runs on a hosted worker and calls `ec2 start-instances`, then waits for the worker's health check to pass; the last step stops it.** Machine policy for that worker pool: long health-check interval, and no automatic deletion of unavailable machines — a stopped worker is *expected* to be unhealthy between deployments. Break-glass over SSM also starts it first. **Fallback if recreate is ever needed** (an AMI change, an incident): persist the Tentacle certificate in Secrets Manager at first registration and `Tentacle import-certificate` at boot before the service starts — the registration then survives a rebuild. **Do not** run the runner persistently to dodge this: a persistent host with cluster-admin is precisely the objection CD-53 answers with on-demand. | DECIDED |
| **CD-62** | **NAME THE NEW TRUST RELATIONSHIP: a SaaS control plane can now execute code on an in-VPC host holding cluster-admin and (boundaried) IAM.** The network truth is "outbound only, two hostnames, no inbound rule" and that is what the follow-up document says. The control-plane truth is that **anyone with deploy rights in that Octopus space runs scripts on the runner.** This is the price of option 1 and it is worth paying — it is what buys the gate — but it is written down here rather than discovered in a review. Mitigations, all already in the design or cheap: a **dedicated Octopus Space** (CQ-4) so the blast radius is our projects only; **RBAC** — the CI service account can create releases and deploy to SIT only (CQ-6), PROD needs a named approver (CD-5, CQ-7); the worker pool is used by our three projects and no others; the H5 **permissions boundary** caps what the host's IAM can do regardless of what runs on it; **SSM session logging** plus Octopus task logs give two independent audit trails; the Tentacle runs as the non-root deploy user; **API keys keep the 180-day expiry** and are held as Octopus-side secrets, never on the runner. Residual: a compromise of the bank's Octopus Cloud tenant is a compromise of our deployment path — the same is true of every other team deploying through it, which is the argument for adopting the bank's pattern rather than inventing our own (CD-35). | DECIDED (accepted risk — owners: the humans) |
| **CD-63** | **REPRODUCE THE ASSUMED EGRESS IN A NEW SIBLING PROJECT, `mimic_egress` — NOT inside `mimic_vpc`, whose no-IGW/no-NAT/no-default-route rule stands unchanged.** In production the proxy lives in the *cloud team's* egress VPC, reached over the Transit Gateway; the ledger VPC itself stays IGW-free. The mimic must have the same shape or Phase 2/3 will develop a dependency the real hand-over cannot satisfy — so: a second, tiny VPC owned by the "cloud team" role, containing an Internet Gateway, one **Squid** forward proxy (no `ssl-bump`; `CONNECT` to 443 only; `dstdomain` = the two Octopus hostnames; `src` = the runner /32) fronted by an **internal NLB** (the "traffic load balancer"), a **Route 53 private hosted zone** name for the VIP associated to the ledger VPC (the bank's corporate DNS, mimicked), **VPC peering** to the ledger VPC, and **specific-prefix routes** on both sides — the ledger-side route goes into the *ledger* route tables only, which is the cloud team's TGW-route step in the hand-over. It emits `egress-handover.auto.tfvars` (`egress_proxy_host`, `egress_proxy_port`, `egress_vpc_cidr`) — plain variables, never remote state, same rule as the network hand-over. **Fidelity gaps, stated:** peering stands in for the TGW (client-invisible: both are "a route to a prefix"); Squid stands in for whatever the bank runs; the allowlist is ours, not theirs. **Cost ≈ USD 0.6/day** (NLB + a `t3.micro`/`t4g.micro` + PHZ); no NAT gateway — the proxy instance carries the public address in *their* VPC, which leaves our "nothing public" intact. Tested against a **free-tier Octopus Cloud instance** (§9a) since the bank's is not available for deploy-tests. Build brief: `../mimic_egress/CLAUDE.md`. | DECIDED |
| **CD-64** | **Build tasks that fell out of CD-55..CD-63 — STATUS 2026-09-14.** **DONE, statically validated (`terraform validate`, `bash -n`), not yet mock-deployed:** `mimic_egress` project (CD-63: egress VPC + Squid `CONNECT`-only allowlist rendered from a template + internal NLB with client-IP preservation + private zone + peering + one route per LEDGER table; gates for region, CIDR overlap incl. the 100.64 secondary, runner-IP-in-ledger-subnet; `emit-handover.sh` auto-wires `sbsa_besu/terraform/runner`; `verify-egress.sh` = 8 probes over SSM) · `sbsa_besu`: `runner_private_ip` + `runner_subnet_az_id` (runner root; the pin defaults to the hand-over's `egress_allowed_source`; module precondition checks the subnet) · `egress-handover.tf` (optional vars) · `tentacle` manifest row — **11.0.4398**, versioned URL, digest recorded · bundle unpack rule → `tools/tentacle/` · `scripts/runner/install-tentacle.sh` implementing CD-57 against the **actual** CLI (`--workerpool`, `--server-comms-address`, `polling-proxy` on / `proxy` off, one-shot `https_proxy` on `register-worker`, own systemd unit as user `tentacle`, CD-61 cert via `new-certificate --export-pfx` → Secrets Manager → `import-certificate`) · `scripts/preflight/verify-egress-proxy.sh` (probes 1–7, the day-one bank check; the installer refuses to register if it fails) · RUNBOOK **E.1** · drawio redrawn · two latent defects fixed on the way (B17 runner subnet reference, B18 hand-over never delivered to the runner). **MOCK-DEPLOYED 2026-09-17 — CD-56..CD-61 VALIDATED LIVE** (`deploy-run-2026-09-17-r9-mock.md`): 8/8 probes (incl. no-interception), `register-worker` through Squid, worker Healthy, Script Console `kubectl get nodes` = 4 Ready against the private endpoint, stop/start kept thumbprint + IP. Fixed on the way: B21 (contract NAT gate), B22 (deploy-config bundle listed a tfvars this repo lacks), B23 (probe 8 hairpinned through the NLB), B24 (`/etc/octopus` index). **Still open:** the CD-61 pipeline start/stop steps + worker-pool machine policy, and a real Kubernetes deployment target bound to the pool (the mock used the Script Console). | VALIDATED LIVE |
| **CD-65** | **THE REGISTRATION SERVICE ACCOUNT NEEDS A TEAM WITH A SPACE-SCOPED ROLE; `Environment manager` SCOPED TO THE SPACE IS SUFFICIENT — ask for that, not Space Manager (CQ-6).** Found 2026-09-17: a service account with a valid key but no team membership authenticates fine and then cannot see any Space (`GET /api/spaces` → *"either SpaceView permission or access to the data within at least one space"*), so `register-worker --space <name>` fails with *"A space with name … could not be found … the user has access to this space"* — which reads like a typo and is not. Membership of a team holding **Environment manager** scoped to the target Space was enough for `register-worker` (it carries the `Worker*`/`WorkerPool*`/`MachinePolicyView` set). Two practical notes: an Octopus team page **looks complete before SAVE** — verify with the API call, not the UI; and a key that gets 401 is a different problem (rotated/expired key), while "space not found" is always permissions. This is the least-privilege statement for the CQ-6 service-account request. | DECIDED (verified live) |
| **CD-66** | **THE MIRROR RUNS THROUGH THE WORKFLOW FROM BRING-UP ON, NOT FROM A LAPTOP; THE PUSH GRANT IS A MIMIC, `mimic_registry`** (2026-10-10). The operator chose the go-live path over laptop bring-up (CD-19 permitted either), and is the person who writes and shares the GitHub Actions and Octopus files inside the bank — so `supply-chain.yml` is a **deliverable**, kept bank-ready (CD-10), and its first live run should be the one the bank will recognise. The push role is the cloud team's in production (central registry, CD-27; R-5b's "scoped role that can create them under our prefix"), so it is built in a **sibling mimic**, not a platform root, and reaches the platform as values only: `AWS_ECR_PUSH_ROLE_ARN`, `ECR_REGISTRY`, `ECR_PREFIX`. **Trust is EXACT on `sub`** — `repo:<owner>/<name>:ref:<ref>` per allowed branch, no `owner*/repo*` wildcard (that also matches any owner whose name starts the same). For repositories created after 2026-07-15 the workflow now **prints the `sub` claim it received** (masked token, subject only). **First dry run, 2026-10-10:** drift check, toolchain and subject step passed; the assume was refused, and the printed subject was `repo:<owner>@<owner-id>/<repo>@<repo-id>:ref:<ref>` — the ID-suffixed form. `mimic_registry` now generates it exactly from `github_ids`; the workflow's trust-policy note says the same for the bank (it previously advised wildcards). **Permissions:** ECR login, list, push and create **only under `mirror/*`**; no delete, no lifecycle, no tag-mutability change. The account's GitHub OIDC provider is **referenced, not created** — it already serves another repository's role. | DECIDED |
| **CD-67** | **THE FIRST OCTOPUS RUN PROVES THE MACHINERY, AND THE OCTOPUS SPACE IS DEFINED IN TERRAFORM** (2026-10-10, operator's choice of the two recommended options). **Scope:** `release.yml` and all three projects are built for real, but `besu-workloads` runs smoke and preflight steps (nodes, a quota'd namespace, the #38 pull canary, C-2 DNS) through the runner's Tentacle instead of the workload Helm releases — the chain's in-cluster layer still installs the five add-ons from public chart URLs (PORTING item 4), which hangs air-gapped, and under CT-5 those add-ons are the cloud team's anyway. The workload steps slot in after the CT-5 rewrite; nothing built for this run is discarded. `besu-validators` gets its manual-intervention gate and the rolling script in a non-destructive mode. **Form:** the official `OctopusDeploy/octopusdeploy` Terraform provider (**1.20.0**, resolved 2026-10-10) defines environments, lifecycles (CD-41), worker pools, the AWS account, variable sets and the three projects with their processes — one reviewable artefact for the bank, same plan/apply discipline as every other root. **AWS credentials for Octopus:** an OIDC account per environment (issuer = audience = the instance host; `sub` = `space:<space>:project:<project>:environment:<env>`), trusted **exactly** per project+environment — no stored keys (CD-9). Unverified until the first run: OIDC on Octopus Cloud's *dynamic* workers. **Coupling found while planning:** the `runner` root reads `chain`'s state (artifacts bucket, access entry), so `besu-infra` must run `chain`'s AWS layer before `runner` — the own-cluster path, already proven twice — and this run targets that cluster rather than `mimic_eks` (one cluster, not two). Decoupling the runner is CT-5 rewrite work. **Applied 2026-10-10 (Phases 1–2):** `octopus/aws-trust` by the operator (OIDC provider, SIT role trusting exactly `space:default:project:besu-infra:environment:sit`, deploy-config secret); `octopus/terraform` 33 objects, verified through the API (slugs, step keys, account subject keys) and by a no-change plan. Two lessons, both in the code: a **ReadOnly** API key on a Space-manager account plans cleanly and fails every create; and Octopus appends new environments after existing ones, so `sort_order` was dropped (provider 1.20.0 reports the mismatch as an inconsistent result). | DECIDED |
| **CD-68** | **`release.yml` SIGNS IN TO OCTOPUS THROUGH OIDC, AS A SERVICE ACCOUNT DEFINED IN `octopus/ci-trust` — NO API KEY IN GITHUB** (2026-10-10). CD-9's "no long-lived keys" now holds on the Octopus side too: `OctopusDeploy/login@v2` exchanges the run's GitHub token for a short-lived Octopus token as service account `besu-ci`, whose OIDC identities match GitHub's `sub` **exactly** (ID-suffixed form, CD-66), one per allowed ref. **`ci-trust` is aws-trust's counterpart:** its own root, applied once by an Octopus **administrator** (users and roles are system objects; the `besu-terraform` Space-manager key cannot create them, and should not be able to edit CI's permissions). **Two custom roles, not the built-ins:** *publish* (BuiltInFeedPush, FeedView, ReleaseCreate/View, ProjectView, ProcessView, LifecycleView, scoped to the three Besu projects) and *deploy first phase* (DeploymentCreate/View, TaskView, EnvironmentView, scoped to the projects **and SIT**; a variable validation refuses UAT/PROD). Built-in "Package publisher" carries BuiltInFeedAdminister, which can replace or delete a released package; "Release creator" carries RunbookEdit. **Trigger: `workflow_dispatch`, one project per run.** Creating a release deploys SIT automatically (CD-41), and a `besu-infra` SIT deployment applies three Terraform roots, so no merge does that by itself until someone decides it should. The workflow then finds that automatic deployment on the release and **waits for it, failing unless Octopus reports `Success`** (CD-21). **Version (CD-8) is `YYYY.M.D.<run>` with no leading zeros.** Octopus treats versions as SemVer-like, so `2026.11.01` would not be canonical. **Package:** a **zip** (not tar.gz). The built-in feed opens a pushed `.tar.gz`, and if it finds a `Chart.yaml` it files the package as that Helm chart. Run `38055337989` published `sbsa-besu-platform` as `besu-app-rpc-edge 0.1.0`. A zip is always generic and named from its filename. Contents: `terraform/ helm/ scripts/ octopus/` + `RELEASE.json` from `git archive`, so gitignored config can't get in. Tracked saved plans are deleted from it (a plan carries state). Symlinks are dereferenced, because an Octopus worker's extractor is not guaranteed to recreate them. A last guard refuses `.plan`, `.tfstate`, `*.auto.tfvars`, real `environments/*/*.tfvars`, `.pem` and `.env`. **Checks:** fmt, validate on all six roots, helm lint, `shellcheck -S error` (which found B37), and the drift check. **Still missing:** the H1 plan-safety gate. It needs a real plan, and so credentials and state. | DECIDED |
| **CD-43** | **The subnet plan is NOT re-derived, and the mimic VPC keeps its hard `/20` validation — now for a positive reason.** Until 2026-09-09 this was "do not size against numbers under query". With CD-42 it becomes "the mimic must rehearse the shape we intend to be given". Its validation message now carries the offered allocations and the instruction that **if the /20 request is refused, the plan changes HERE FIRST and a rehearsal is re-run** — because a mimic that does not match production proves the platform *works*, not that it *fits*. | DECIDED |
| **CD-44** | **UAT is 8× PROD (2,048 vs 256) and this is raised as probably-a-mistake. Note UAT's /21 already sits at CD-42's acceptable floor, so the substance of the request is SIT and PROD.** Our stated position: **PROD should be the largest**, since it runs the most nodes, the most load balancers and the only workload with a growth path. The urgency is that **a VPC's primary CIDR is immutable after creation**, as is the EKS service CIDR after cluster creation — so this is cheap now and expensive later. | DECIDED |

---

## 4. The GitHub Actions side

### 4.1 `supply-chain.yml` — mirror upstream into ECR

**Runs on a GitHub-hosted runner** (CD-17) — it handles only public upstream artefacts
(CD-18), so nothing confidential is present. Triggered manually and whenever the version
manifest changes. Never on every push: mirroring is idempotent but not free, and re-running
it should be a decision.

Disk is 14 GB on a standard runner, which the 23 images would strain if unpacked — but
`crane copy` streams blob-to-blob with no Docker daemon and no local materialisation, so it
is a non-issue. **A second, independent reason to use `crane` over `docker` beyond CD-11's
digest argument.**

1. Read the manifest (CD-12) — the 8 platform images, the 15 chart-carried images
   (`../CHART_IMAGES.md`), and the 5 pinned charts.
2. Assume the ECR IAM role via OIDC (CD-9).
3. **`crane copy` each image by digest** (CD-11). Repositories are created by Terraform
   (`modules/registry`), not on the fly, so tag-immutability and the no-expiry lifecycle
   are guaranteed rather than hoped for.
4. `helm pull` each chart, `helm push` to `oci://<registry>/charts` (D-22).
5. Print the resolved digests to the job summary, ready to pin.

### 4.2 `release.yml` — package the platform and hand it to Octopus

> **BUILT 2026-10-10 (CD-68)**, at the repository root `.github/workflows/release.yml`.
> **Implemented:** steps 1 (except the H1 gate), 3, 5 and 6, with an OIDC sign-in
> instead of an API key. It waits for the SIT deployment that the release triggers.
> **Not yet built:** step 2, the plan-safety gate, which needs credentials and state;
> step 4's release notes are the commit and the run link; and the optional ECR copy.

Triggered on merge to the release branch, and manually. **Runner placement is a policy
question** (CD-18): this one packages our own Terraform, Helm and scripts, so it may need
to run on the bank's infrastructure even where the mirror does not.

1. `terraform fmt -check` + `validate` on all four roots, `helm lint`/`template`,
   `shellcheck` — the required CI check from **H38**.
2. **The H1 plan-safety gate (H38):** fail if a plan would change more than one validator
   pod template at once. This is the automated backstop behind the rolling rule; it is the
   check that makes CD-5 enforceable rather than aspirational.
3. Package `terraform/`, `helm/`, `scripts/` and the version manifest into a versioned
   tarball (CD-8).
4. Generate release notes; attach as an artefact.
5. `push-package-action` → Octopus feed. Optionally also the `FROM scratch` ECR copy
   (pending **CQ-3**).
6. `create-release-action`. **Deploy to DEV only** if explicitly requested; PROD never
   from CI (CD-15).

---

## 5. The Octopus side — three projects

| Project | Deploys | Runs on | Gate |
|---|---|---|---|
| **`besu-infra`** | Terraform: `shared` → `runner` → `chain` (AWS layer) → `app` | A worker with AWS credentials; no cluster access needed | Plan artefact reviewed before apply; PROD needs approval |
| **`besu-workloads`** | The in-cluster layer: bootnode/RPC/explorer-RPC Helm releases, Blockscout, kube-prometheus-stack, PDBs, StorageClass, Secrets Store CSI | **Inside the VPC** (§7) | PROD needs approval; ends with the H35 check (CD-16) |
| **`besu-validators`** | The validator release **only** | Inside the VPC | **Manual intervention, always, in both environments.** Runs `rolling-besu-apply.sh`, one pod at a time, verifying the chain kept producing and the node caught up between each |

**Why three and not one.** A single project with a "deploy everything" process means one
mistimed run number can roll every validator at once and halt the chain. Splitting the
validators into their own project makes that *structurally* awkward rather than merely
discouraged — the same reasoning as H1's `ignore_changes` + `OnDelete`, applied to the
deployment tool instead of to Terraform.

---

## 6. The constraint Octopus must be built around (H1)

QBFT with 4 validators tolerates **exactly one** down. A standard "Deploy Helm Chart" step
pointed at the validator release updates all four StatefulSet templates at once; they
restart together; quorum is lost; **the chain halts.**

The platform already prevents this from Terraform's side — validators live in their own
`helm_release` with `lifecycle { ignore_changes = [values] }`, and the chart pins
`updateStrategy: OnDelete`, so a blanket apply is a no-op on them. **The PDB does not help:**
`maxUnavailable=0` gates evictions and drains, not StatefulSet template updates.

Octopus must not route around that guarantee. Concretely:

- `besu-workloads` **must not** include the validator release in any Helm step.
- `besu-validators` is the only path, and its deploy step *is* the rolling script.
- A manual-intervention step precedes it, in **both** environments — DEV included, because
  the point of DEV is to rehearse the PROD procedure, not a faster one.
- The H1 plan-safety CI gate (§4.2) fails the build before a release is ever created.

---

## 7. How Octopus reaches an air-gapped, private-endpoint cluster

> **RESOLVED 2026-09-14 — option 1 (CD-55).** Octopus is **Octopus Cloud** (CD-33), and the
> bank has a **shared central egress** the ledger VPC can use. The design is the polling
> Tentacle on the runner (CD-36/CD-57), reached through the bank's proxy. §7.1 keeps the option
> table as the record of what was weighed; §7.2 is the mechanism as it will be built; §7.3 is
> the configuration, question by question. CD-34's layer split remains the fallback if the
> egress path is ever withdrawn.

### 7.1 What Octopus Cloud changed, and the three options that were weighed

The agent's polling model was never the problem — it is exactly the right shape: outbound
only, no inbound rule, no public cluster endpoint. **The problem was the destination.**
Polling to a SaaS host means polling to the internet, and the VPC has no route of its own to
it. No firewall rule, endpoint policy or IAM grant fixes that; the packet needs somewhere to go.

| | Option | Needs | Cost | Outcome |
|---|---|---|---|---|
| **1** | **Narrow egress to Octopus's two hostnames**, outbound only, `CONNECT` on 443 | A route from the VPC to a bank egress point over the Transit Gateway | A documented, deliberate hole in the air-gap. Narrow, but real | **TAKEN.** The route exists for other teams; the bank confirmed a shared egress behind a load balancer |
| **2** | **Split by layer (CD-34).** Octopus runs the AWS-API Terraform from a hosted worker; the in-cluster layer runs from the In-VPC EC2 Runner over SSM | Nothing from anyone | **CD-5's tool-enforced validator gate.** Reduced audit trail for in-cluster deploys | Superseded; **kept as the fallback** |
| **3** | **An S3 deployment bridge.** Octopus writes a signed deployment intent to S3 from a hosted worker; a poller on the In-VPC EC2 Runner reads it over the S3 gateway endpoint and executes | Nothing from anyone | A bespoke deployment path we build, own and get assurance for — in a bank, its own review | Not needed. Remains the answer if option 1 is ever refused *and* the gate is a hard requirement |

### 7.2 The mechanism as built: a polling Tentacle worker on the runner, through the bank's proxy

```
 Octopus Cloud                bank egress (shared)                 ledger VPC (ours)
 <instance>.octopus.app  <──── proxy estate behind an ────  CONNECT  ── runner (EC2, pinned IP)
 polling.<instance>            internal LB VIP                 :443       ├─ Tentacle (polling only)
   .octopus.app:443            allowlist: src=runner /32                  ├─ terraform · helm · kubectl · keytool
                               dst=the two hostnames                      └─ rolling-besu-apply.sh
                               no TLS decryption                                │
                                                                                ▼  private EKS endpoint
                                                                          bootnodes · RPC · validators
```

- **The runner is an Octopus Worker**, in a worker pool of its own per environment. The
  Kubernetes deployment target is bound to that pool, so Octopus's own model — "run this step
  on a worker that can reach the target" — is what reaches the private endpoint. No
  Kubernetes Agent, no chart, no mirrored agent images (CD-36).
- **Only the Halibut polling channel goes through the proxy.** The Tentacle's web-request
  proxy stays off, because Tentacle exports it to every step as `http_proxy`/`https_proxy`
  and the steps talk to VPC endpoints and the private EKS endpoint (CD-57).
- **Packages arrive over Halibut too**, so at runtime the worker needs nothing on the
  allowlist beyond the two hostnames (CD-59).
- **The runner is started by the pipeline and stopped by it** (CD-61); between deployments it
  is a stopped instance with a registered Tentacle, a pinned IP and a preserved certificate.
- **SSM stays**, for break-glass and diagnosis (CD-53). Nothing about Octopus removes it.

**Why not the Kubernetes Agent, for the record.** It is a Helm chart pulling
`octopusdeploy/kubernetes-agent-tools-base` images — both would have to be mirrored into ECR
and installed from the runner *before* Octopus could deploy anything (chicken-and-egg); it
cannot run the in-cluster Terraform layer (StorageClass, Secrets Store CSI); it has no
`keytool`; it supports Kubernetes 1.26–1.35 with our default at the top of that range; and it
gives no shell. It would need the identical egress. Nothing it offers pays for a second
bootstrap dependency.

### 7.3 The configuration, question by question — what we assume, why, and the fallback

The cloud team will not describe the egress internals, so these are **our decisions**, chosen
to be the robust reading and to fail cheap. Each is a decision row above; this table is the
one-screen summary.

| Question | Decision | Why this reading | If wrong |
|---|---|---|---|
| Explicit or transparent proxy? | **Explicit `CONNECT` proxy at an LB VIP** (`egress_proxy_host:port`) — CD-56 | An LB is something you address; explicit keeps D-3 — nothing egresses unless configured | Delete the `polling-proxy` setting. One command |
| TLS inspection? | **None on the two Octopus hostnames** — CD-58 | Not a preference: Octopus's protocol rejects an interrupted tunnel (client-cert auth + thumbprint pinning) | Ask for a no-decrypt exception — a firewall ticket. The `openssl s_client -proxy` probe finds it before registration |
| Which port? | **443**, at `polling.<instance>.octopus.app` — CD-59 | Universally allowed for `CONNECT`; 10943 would be an exception | Fall back to 10943 with `--server-comms-port` if 443 is refused (unlikely) |
| Which destinations? | **Exactly two hostnames**; tarball vendored, no wildcard — CD-59 | Smallest true ask; a third host would creep in via the download URL otherwise | — |
| Which source? | **The runner's pinned /32**; accept the ledger subnet /24 — CD-60 | The bank allowlists by source; a /32 keeps same-subnet pods off the proxy even if misconfigured | Give the /24 and lean on the other three layers |
| Which route? | **Specific prefix to the egress VIP, ledger route tables only, added by the cloud team (TGW)** — CD-60 | Never a default route; mimic rule #2 holds | — |
| Proxy auth? | **Assume none** — CD-56 | Most bank egress authorises by source, not credentials | `polling-proxy --proxyUsername/--proxyPassword`, credential from Secrets Manager |
| Runner lifecycle? | **Stop/start, pipeline-driven; cert persisted as fallback** — CD-61 | A recreated instance has a new thumbprint and a dead registration | `import-certificate` at boot |
| Where does the Tentacle come from? | **`runner-tools.manifest`, versioned tarball, digest-pinned** — CD-59 | D-21: no package manager, no download host on the allowlist | — |
| What did we newly trust? | **Octopus Cloud executes on an in-VPC admin host** — CD-62 | The price of the gate; mitigated by Space, RBAC, approvals, boundary, two audit trails | — |

---

## 8. Setting up Octopus — the API key

> **2026-10-10: for CI this section is SUPERSEDED by CD-68.** `release.yml` signs in
> through OIDC as the `besu-ci` service account (`octopus/ci-trust`), so **no API key is
> stored in GitHub**. What follows still applies to the one key that remains: the
> `besu-terraform` Space-manager key that applies `octopus/terraform`, held in Secrets
> Manager. Points 2 and 3 there were learned the hard way: **the key's access level must be
> read-write.** A ReadOnly key plans cleanly and then fails every create (CD-67).

Verified against the Octopus documentation, 2026-09-04.

1. **Create a service account, not a personal user.** Octopus recommends a dedicated
   service account for "tooling that is not acting on behalf of a particular user." A key
   generated against your own login dies when your account changes, and it silently
   inherits *your* permissions.
2. **Scope it before generating the key.** An API key **cannot have more permissions than
   the user account that created it**, so the scoping happens on the service account:
   put it in a Team granting only
   - push packages to the built-in feed,
   - create releases,
   - deploy to **DEV** — **not** PROD (CD-15).
3. **Generate it:** profile image → **Profile** → **My API Keys** → **New API key** →
   describe its purpose → choose the access level → **Generate new**.
   - **Key type must be "a person", NOT "an AI agent".** The AI-agent type strips write
     capability: it cannot push packages or create releases, and the failure arrives as a
     permission error on the first pipeline run rather than at key creation.
   - **Access level must not be read-only** — the first package push fails.
4. **Copy it immediately.** It cannot be retrieved from the portal again.
5. **Expiry.** New keys default to **180 days**. Accept the default rather than extending
   it, and put the renewal in a calendar — a CI pipeline that dies on a known date is a
   far better failure than a credential that never expires.
6. **Store it in GitHub** as repository secrets:
   - `OCTOPUS_SERVER_API_KEY` — the key
   - `OCTOPUS_SERVER_URL` — the server URL
   and as a repository **variable** (not a secret — it is not sensitive):
   - `OCTOPUS_SPACE`
7. **Rotation.** Generate the replacement, update the GitHub secret, verify one run, then
   revoke the old key. Never revoke first.

> **Personal environment first.** Everything above works identically on a personal Octopus
> instance. Keep the bank's server URL, space, project names and API key strictly in
> GitHub secrets/variables so moving to the bank environment is a configuration change
> (CD-10).

---

## 9. Questions for the cloud team

> **⇢ For sending, use `CLOUD_TEAM_REQUEST_REGISTRY_AND_CICD.md` (2026-09-07).** It merges
> these questions with the registry requirements #20–#26 into one self-contained document
> and explains each failure mode. This section stays as the in-place record so CQ-numbers
> resolve from the design notes.

*Written to be forwarded. It assumes no knowledge of the sections above.*

We are wiring the Besu ledger platform into GitHub Actions (CI) and Octopus Deploy (CD).
The platform runs on two EKS clusters in the shared VPC, which has **no internet egress**
and a **private EKS API endpoint**. *(CT-5, 2026-09-21: it now runs in a namespace of the
cloud team's shared cluster. CQ-1..CQ-8 below are closed and kept as the record; the
deployment design they settled — Tentacle worker on the runner — is unaffected.)* Eight things we need from you:

| # | Question | Why it matters |
|---|---|---|
| **CQ-1** | **Where does Octopus Server run, and is it reachable from inside the shared VPC?** We plan to use the Octopus **Kubernetes Agent**, which polls **outbound** from the cluster to Octopus Server — so no inbound access or public cluster endpoint is needed. But the VPC has no internet route, so this works **only if Octopus Server is on the internal network with a Transit Gateway route from the VPC.** If Octopus is internet-hosted, we need a different mechanism and would like to design it with you now rather than at integration. |
| **CQ-2** | **Where do the self-hosted GitHub Actions runners run, do they have internet egress, and can they be granted ECR push?** Our CI must fetch third-party images and Helm charts from public registries and copy them into ECR. That must happen **outside** the air-gapped VPC. If your existing runners have egress and can assume an ECR-push role, they are exactly what we need and we will use them. |
| **CQ-3** | **The reference pipeline stores the Octopus deployment package twice** — in the Octopus package feed and, wrapped in a `FROM scratch` image, in ECR. Is that ECR copy required by an artefact-retention or audit policy, or is the Octopus feed sufficient? | Determines whether we maintain one path or two. |
| **CQ-4** | **Do we get our own Octopus space, or a project inside an existing one?** And what naming convention should the projects follow? We expect **three** projects (infrastructure, in-cluster workloads, and a deliberately separate one for validator upgrades — see CQ-7). |
| **CQ-5** | **Does Octopus already run Terraform for other teams?** If so, which worker pool, and how is Terraform state and state-locking handled? Ours is S3 with **S3-native locking** (`use_lockfile`; no DynamoDB table), four separate state files, applied in a fixed order. Two concurrent applies against one state file fail on the lock, so **deployment concurrency must be limited per project+environment**. |
| **CQ-6** | **How are Octopus service accounts and API keys issued and rotated?** We need a service account (not a personal user) scoped to: push packages, create releases, and deploy to **DEV only**. PROD deployment must require human approval and must not be reachable from a CI credential. Octopus keys default to a 180-day expiry, which we intend to keep. |
| **CQ-7** | **Who approves a PROD deployment, and can Octopus enforce it?** One item needs more than a normal approval: **validator upgrades**. The chain uses QBFT with 4 validators and tolerates exactly one being down — restarting more than one at a time **halts the ledger**. Our validator project therefore runs a controlled one-at-a-time script behind a mandatory manual-intervention step. We need that gate to be un-bypassable, in both environments. |
| **CQ-8** | **ECR account, repository naming, and cross-account pull.** Cross-references requirement **#25** in `NETWORK_REQUIREMENTS_CLOUD_TEAM.md`: is the registry in our workload account or a central shared-services account, and if the latter, can the repository policies grant pull to our EKS node roles? Also **#23** — the ECR VPC endpoint policy must not be scoped to a single account, or the EKS managed addons (which pull cross-account from AWS's own registry) fail to start. |

**One thing we are NOT asking for:** internet access, for the runners inside the VPC or for
anything else. The whole design assumes the air-gap holds.

---

## 9a. Carried in from a working reference implementation (2026-09-07)

CD-20..CD-25 came from reviewing a complete, working Terraform + GitHub Actions + Octopus
pipeline on AWS — built end to end, with its failures recorded. Every one of them is a
defect we would otherwise have found during a billed deploy-test.

Worth keeping visible, because they share a shape: **four of the six are silent.** The
deployment reports success (CD-21), the fix appears applied (CD-22), the variable appears
set (CD-25), the state key appears unique (CD-20). None of them fails loudly at the moment
the mistake is made. That is the same class as F27, F28 and B16 in this programme's own
history, and the same answer applies — verify the layer, do not infer it from the layer
above.

Two smaller items from the same source, not worth a decision number:

- **GitHub's OIDC `sub` claim changed for repositories created after 15 July 2026** — it
  now carries org and repo ID suffixes (`repo:owner@1234567/repo@8901234:ref:...`), so a
  `StringEquals` trust policy copied from an older tutorial fails with an unhelpful
  `Not authorized to perform sts:AssumeRoleWithWebIdentity`. Use `StringLike` with
  wildcards. **Reported, not independently verified — confirm when we create the role**,
  and if auth fails, decode the actual token claim rather than guessing at the policy.
- **Octopus has a free tier**, not only a trial — enough for the personal-environment
  bring-up (CD-10).

---

## 10. Sources

- [Octopus — Kubernetes Agent](https://octopus.com/docs/kubernetes/targets/kubernetes-agent) (polling communication; private API endpoints; agent chart and images; K8s 1.26–1.35)
- [Octopus — Create an API key](https://octopus.com/docs/api/authentication/create-an-api-key) (service accounts; 180-day default expiry; key shown once; cannot exceed creator's permissions)
- [Octopus — Polling Tentacles over the standard HTTPS port](https://octopus.com/docs/infrastructure/deployment-targets/tentacle/polling-tentacles-over-port-443) (Octopus Cloud: `--server-comms-address https://polling.<instance>.octopus.app`, omit `--server-comms-port`; Tentacle ≥ 6.3.417; not WebSockets) — CD-59
- [Octopus — Proxy support](https://octopus.com/docs/infrastructure/deployment-targets/proxy-support) ("Do not enable SSL offloading for Tentacle Communication … requires an uninterrupted TLS tunnel"; polling proxy vs web-request proxy are independent; the web-request proxy is passed to Calamari and scripts as `http_proxy`/`https_proxy`) — CD-57, CD-58
- [Octopus — `Tentacle polling-proxy`](https://octopus.com/docs/administration/tentacle.exe-command-line/polling-proxy) (`--proxyEnable --proxyHost --proxyPort --proxyUsername --proxyPassword`) — CD-57
- [Octopus — Linux Tentacle](https://octopus.com/docs/infrastructure/deployment-targets/tentacle/linux) (tarball download `Linux_x64TarGz`; `create-instance` / `configure --noListen True` / `register-worker --comms-style TentacleActive`) — CD-36, CD-59
- [Octopus — Tentacle communication](https://octopus.com/docs/security/octopus-tentacle-communication) (Halibut over TCP, mutual certificate thumbprints) — CD-58
- Octopus support thread *"Polling linux tentacle don't use proxy during register-with command"* (#26246) — the register call ignores the polling proxy on Linux — CD-57
- `docs/CLOUD_TEAM_REDESIGN_NOTES.md` §11 — the ECR registry design (D-16..D-22)
- `docs/production-hardening-backlog.md` H1, H35, H38 — the rolling rule, the chain-integrity probe, the CI gate
- `../CHART_IMAGES.md` — the 15 chart-carried images the mirror must cover

---

## 11. The cloud-team call, 2026-09-09 — answers and what they cost

Four answers. Three of them changed the design, and two of the three arrived as
statements we had to treat as *partial*, because the words admit two readings
with opposite consequences. That is not a criticism of the answers — it is the
normal shape of a verbal answer to a written question, and the lesson to keep is
that **a design-blocking question needs a disambiguator built into it**, not just
a clear statement of why it matters. "Where does Octopus run?" produced an
ambiguous answer. "What is the server URL?" could not have.

### What was answered

| Question | Answer | Verdict |
|---|---|---|
| **#24** — who owns the VPC | Shared VPC; we are a tenant; the account is the cloud team's | Answered, but **which shape** — one account or two — is still open (**CD-30**, R-3) |
| **#25** — ECR topology | **Central shared-services account** → (b) | Answered. Everything in **CD-27** follows |
| **CQ-2** — runners | They have self-hosted runners; do not stand up our own | Answered. **Reverses CD-17** → **CD-26** |
| **CQ-1** — Octopus | A dedicated server in their account, cloud-hosted | **Ambiguous — still blocking** (**CD-31**, R-1) |

### What got cheaper

- **#26 disappears as a request.** We are no longer asking anyone to permit
  GitHub-hosted runners or to create an OIDC identity provider.
- **#13 and #14 are withdrawn** — NACLs and subnet flow logs are not a tenant's
  to manage. Security groups and ENI-level flow logs cover the same ground with
  nothing needed from the cloud team.
- **#4 may be withdrawable.** The AWS Load Balancer Controller accepts explicit
  subnet IDs on the Service, which would remove the need for the cloud team to
  tag the load-balancer subnets `kubernetes.io/role/internal-elb=1`. **Verify
  against our controller version before promising it**, and note that
  `modules/network-contract` asserts that tag today — the assertion becomes
  conditional, not deleted.

### What got more expensive, and by how much

- **The supply chain now depends on someone else's machines.** Previously the
  build host was GitHub's, always had internet, and needed nothing from anyone.
  Now it is the bank's, and **whether it has egress to `docker.io` and friends is
  an open question that no amount of design on our side can answer** (R-2). This
  is the single largest new risk, and it did not exist yesterday.
- **The registry is no longer ours to configure.** Tag immutability and the
  absence of a lifecycle expiry were checkboxes under #25a. Under #25b they are
  requests against a shared registry whose owners have a legitimate reason to
  expire images. **The lifecycle one genuinely matters**: it is the difference
  between a routine node replacement and a change-controlled re-approval.
- **A new failure mode we had not asked about at all — region.** ECR is regional
  and the `ecr.dkr` endpoint reaches only its own region (**CD-28**). Under #25a
  this could not go wrong; under #25b it is a coin-flip that nobody would think
  to mention, because from the registry owner's side the repository is simply
  *there*.

### The one to watch

**R-2.** If the bank's runners have no internet egress, there is no machine in
this design that can copy an upstream image into ECR, and the platform cannot be
built at all. There is a fallback — CodeBuild in a tooling account with no VPC
configuration attached, which therefore has internet without touching this VPC —
but it is a new ask to a team that has just told us to use their runners, so it
is better raised now, as a contingency, than later as a reversal.

### 11.1 Second round, same day — four more answers

| Question | Answer | Verdict |
|---|---|---|
| Tag immutability / lifecycle expiry (R-5) | **Both already enforced** registry-wide | **Closed.** The one we expected to argue for, conceded before we asked |
| ECR region (R-4) | **af-south-1** | **Closed.** CD-28's trap did not fire — same region as the VPC, so `ecr.dkr` reaches it and #20's `prod-af-south-1-starport-layer-bucket` ARN is right as written |
| Runner internet egress (R-2) | **Yes** | **Closed**, and it retires the largest new risk CD-26 introduced. Residual detail only: proxy? TLS interception? Docker Hub credentials? |
| Octopus (R-1) | URL is `https://<instance>.octopus.app`; certificate is `*.octopus.app` | **Closed — against us.** See **CD-33** |
| Octopus namespace (CQ-4) | We have our own | **Closed**, pending one clarification: our own *Space*, or a project group in a shared one? It decides how a DEV-only service account is scoped |

**The disambiguator worked.** R-1 was written as "what is the server URL?" precisely because
"where does Octopus run?" had already produced an ambiguous answer. It took one look at a
certificate to settle a question that had been blocking for five days. Worth generalising:
**when a question blocks a design, ask for an observable string, not a description.**

### 11.2 Where the programme actually stands

**The supply chain is fully unblocked.** Registry topology, region, retention, immutability
and a build host with internet are all settled. `supply-chain.yml` has no remaining external
dependency and can be written now.

**The deployment path was not — until 2026-09-14 (§11.4).** It had one open question (R-9)
whose answer decided between a narrow, documented egress hole and a permanent reduction in the
strength of the validator gate. Both were acceptable; they were not equivalent; and the choice
belonged to the humans who own the risk, which is why §2 of the follow-up document states the
cost in the same paragraph as the recommendation. **It closed on the narrow hole** (CD-55).

**The tenancy question (R-3) is now the larger unknown**, because it decides what we are able
to build at all. Its own disambiguator: *what account ID do our credentials resolve to?*

### 11.3 Third round — tenancy assumed, and an ask that got smaller

Two answers on 2026-09-09: single-account tenancy is the **working assumption** (CD-37), and
**af-south-1 is enabled** on the account.

**The interesting outcome is that our ask to the cloud team shrank.** #23 asked them to scope
the ECR endpoint policy by principal to our account. On a *shared* endpoint in a *single*
account that request is meaningless and would actively break other tenants (CD-38). We wrote
a control that was correct for infrastructure we own and wrong for infrastructure we share —
and the correction is not a smaller version of the same request, it is a **different kind of
request**: verify two properties, rather than add a restriction.

Worth keeping as a pattern. Three of our registry requirements (#20, #22, #23) are now
phrased as *"here are things to check on endpoints you already have"*, which is a far easier
thing for another team to action than *"please reconfigure this for us"* — and it is also
more honest, because on shared infrastructure we are one consumer among several and have no
standing to ask for exclusive scoping.

**What we built instead of asking.** `scripts/preflight/verify-endpoints.sh` — read-only,
one `describe-vpc-endpoints` call, about ten seconds. It checks all 15 interface endpoints
plus the S3 gateway, private DNS on the eight where its absence is fatal, 443 ingress on the
endpoint security groups, route-table association for the gateway, the starport layer bucket
in the S3 policy (#20), and both ECR policy traps (#23). Failures name the requirement
number, so what goes back to the cloud team is a citation rather than a symptom.

Its design rule, worth repeating because it is what makes the output trustworthy: **an
endpoint policy is reported PASS only when it is provably permissive.** Anything the script
cannot prove is a WARN with the policy printed. A false PASS here would return us to exactly
the silent mid-apply hang the script exists to prevent.

**One bug caught by testing it against a deliberately broken synthetic VPC rather than
reasoning about it** — the B12 lesson yet again. The private-DNS check read
`.PrivateDnsEnabled // "absent"`, and **jq's `//` treats `false` as empty**, so the single
value the check existed to catch reported as "absent" and was skipped in silence. A check
that cannot fail is worse than no check, because it is trusted. Test fixtures for preflight
scripts should be built broken, not healthy.

### 11.4 Fourth round, 2026-09-14 — R-9 answered: a shared egress exists

**What was said.** There *is* an egress path from private VPCs; it is **shared**, not ours;
it is fronted by **a load balancer for outbound traffic**, with **a second load balancer for
internal traffic**. And that is all that will be said — the internals are the cloud team's,
and we are one tenant of a service they run for many.

**What it means.** Option 1 of §7.1. The Tentacle-on-the-runner design (CD-36) stops being
conditional, CD-34's layer split becomes the fallback, and the validator gate is once again
something Octopus enforces rather than something a runbook asks for. Programme-wise this was
the last open question on the deployment path; only R-3 (tenancy shape) remains, and it is
proceeding on a stated assumption.

**What we did with the silence.** Rather than block on details we will not get, we decided
each remaining configuration question ourselves (CD-56..CD-62, §7.3), choosing the reading
that is (a) most likely from the words used, (b) the one that keeps the air-gap posture, and
(c) cheapest to reverse. Two of those decisions corrected our own earlier text: the
follow-up document's suggestion that a TLS-inspecting proxy could be accommodated with a CA
bundle is wrong for Tentacle (CD-58), and our "one hostname" ask is really two (CD-59).

**What we still ask for — and it is a ticket, not a design review (R-10).** A proxy
`host:port` to configure; a source allowlist entry for the runner's /32 (or its /24);
destination entries for `<instance>.octopus.app:443` and `polling.<instance>.octopus.app:443`,
`CONNECT` only; no TLS decryption for those two; a route from the ledger route tables to the
egress VIP's prefix over the Transit Gateway; and whether the proxy requires credentials.
**Plus one for the subnet owner (B43, 2026-10-10):** an **explicit subnet CIDR reservation** on
that /32 in its ledger subnet. The EKS nodes share the subnet, and the VPC CNI's warm pool took
the runner's address on the first Octopus deployment; with the reservation, AWS assigns it only
on explicit request, which is how the runner asks for it.
That is the whole list.

**What we build to not wait.** `mimic_egress` (CD-63) — the assumed shape, as a sibling of
`mimic_vpc`, so the Octopus path can be deploy-tested against a free-tier Octopus Cloud
instance before the bank's egress is wired. `mimic_vpc` itself does not change: its no-IGW
rule was always about *our* VPC, and the proxy lives in *theirs*.

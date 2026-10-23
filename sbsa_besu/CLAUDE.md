# CLAUDE.md — Besu Ledger + Application Platform (`sbsa_besu`)

> ## Branch `manual-setup` (2026-10-23) — the platform built BY HAND, no Terraform
>
> This branch holds only what a manual build uses. The AWS layer is built with the AWS CLI;
> the in-cluster layer is deployed by Octopus through hand-written script steps on the runner.
> **The guide and run log is `docs/deploy-run-2026-10-23-manual.md`; hand-written files it uses
> live in `manual/`.** All Terraform (`terraform/`, `octopus/`, the `mimic_*` projects) and the
> design records were removed here and remain on branch `testing` — read them there
> (`git show testing:<path>`) for the *why* behind a control. Sections below that describe
> Terraform roots, states or `terraform apply` do not apply on this branch; the prime directives
> (§0) and the design decisions (§1, §5–§7) still do.

> Consumes the shared VPC **and, since CT-5, the shared EKS cluster** provided by the
> bank cloud team. During development those are produced by the sibling projects
> `mimic_vpc` and `mimic_eks` (built and **first applied live 2026-10-09**; **hostile by default** —
> it exists to make this platform's gates fail, so they can be trusted when they pass. On
> that run every `cluster-contract` gate was seen to refuse, and only the expected ones
> against strict. B27 fixed and **proven live 2026-10-10**; open: B30, B34, and B32's runner
> half — `docs/build-findings.md`).

You (Claude Code) are building a production Hyperledger Besu (QBFT) ledger and an
application platform in **a namespace of a shared EKS cluster another team runs, inside a
shared VPC that team owns** — see the CT-5 banner below; the text after it still says
"two EKS clusters we build", which is superseded. **Read this file fully at the start of every session.** It encodes
decisions already settled with the human, hard guardrails, and a mandatory
documentation practice. Do not re-litigate settled decisions; if something here
seems wrong, raise it with the human rather than silently changing course.

**Source of truth for implementation:** the `besu-aws` repository. This platform is a
**port**, not a rewrite. Its modules, Helm charts, scripts, preflight checks, and its
entire catalogue of hard-won findings (F1–F33) and hardening items (H1–H39) are
proven in production deploy-tests. **Port and adapt them. Do not reinvent them.**
When in doubt about *why* something is the way it is, the answer is in that repo's
`docs/` — read it before changing it.

---

> ## ⚠️ CT-5 — 2026-09-21: the cluster is no longer ours to build. READ BEFORE ANYTHING BELOW.
>
> The cloud team provides a **shared EKS cluster** and allots us a **namespace**; they run
> the cluster and its maintenance. Their VPC has **role-separated subnets with security
> rules they define**. Recorded from a verbal update — **not yet confirmed in writing**.
>
> **This brief is not yet rewritten against it**, on purpose: the asks in
> `docs/CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md` **(#27–#38)** decide which files are deleted
> versus made conditional. The full design record is `docs/CLOUD_TEAM_REDESIGN_NOTES.md`
> **§12** (D-23..D-43; §12.13 is the silent-error audit and its gate assignment). Until
> the rewrite, these override the sections they name:
>
> - **§1 "Two EKS clusters"** — superseded. One cluster, ours is a namespace (two requested). PrivateLink between clusters, the `app` cluster and **Stage 3.0 are deleted** (D-28).
> - **Prime directive 1 extends to EKS and to every cluster-scoped Kubernetes kind** — cluster, node groups, addons, CRDs, DaemonSets, StorageClasses, webhooks, cluster RBAC. A plan or chart that creates one is a bug (D-23).
> - **The four cluster-scoped add-ons we install** (LBC, Secrets Store CSI + provider, kube-prometheus-stack, Fluent Bit) are the cloud team's to provide; we **assert, never install** (D-24). §5.3's chart mirroring shrinks accordingly.
> - **§6 isolation** — the validator node group and per-tier SGs become an *ask* (#28, D-26); NetworkPolicy default-deny is now load-bearing. **§7's EKS version ladder** is theirs; what remains is a compatibility gate (#36).
> - **Node maintenance is theirs and can halt the chain** — H1's rolling rule now depends on a written operating agreement (#29, D-27), not on our tooling.
> - **The subnet security rules are a gate** (D-29): the flow table in §12.4 must pass rules we did not write, asserted by a read-only preflight before anything billable.
> - **§6a event pipeline** — E-14 is re-scoped, not reversed: the listener runs in the application *namespace*, in-cluster (D-28). Everything else about the pipeline stands, and PrivateLink is no longer a data-path dependency.
> - **Do not start PORTING items 5 or 6 on the old premise.** Item 4's remaining work (OCI charts, chart-image overrides) mostly disappears if #30 confirms the add-ons are provided.
>
> Branches: this work is on **`shared-eks-namespace`**; the own-cluster design is frozen on **`own-eks-cluster-design`** (`3af66e8`).

---

## 0. Prime directives (read first)

1. **NEVER create network-layer resources.** No VPC, subnet, route table, IGW, NAT,
   Elastic IP, DHCP option set, or Transit Gateway. Those belong to the cloud team
   and are consumed as inputs (§3). If a plan shows any of these being created, stop
   and treat it as a bug. In production, attempting it fails on permissions; in a
   deploy-test against the Phase-1 mimic it would silently succeed and corrupt the
   fidelity of the whole exercise.

2. **THE NETWORK IS AIR-GAPPED.** There is no Internet Gateway and no NAT. Nothing
   may assume outbound internet. Every AWS API call goes through a VPC endpoint;
   every container image comes from our private ECR registry;
   every Helm chart and Terraform provider comes from a mirror. A missing endpoint
   does not error — **it hangs until timeout**. See §5.

3. **COST GUARDRAIL.** Deploy-tests run against the prod configuration with
   **mandatory same-day teardown**. Burn rate for a full two-cluster test was
   ~**USD 1.85/hour** in `us-east-1`: 2 EKS control planes ($0.20), ~15 interface
   endpoints × 3 AZ ($0.45), chain nodes ($0.77), app nodes ($0.19), EBS and NLBs
   (~$0.22). **As of 2026-09-04 ALL environments run in `af-south-1`**, which is
   roughly **31% more expensive** → ~**USD 2.40/hour**. The legacy USD 15 cap now
   buys about **6 hours**, not 8.
   **Recommended: USD 25 for a full two-cluster run, USD 15 retained for chain-only
   runs. This raises a standing hard rule and needs explicit human sign-off before
   it takes effect.** Run `terraform plan` before every `apply` and surface resource
   counts and expensive items.

4. **DOCUMENT AS YOU BUILD.** In the same session as any infrastructure change,
   update `docs/RUNBOOK.md` (what to run, in what order, and what goes wrong) and
   the design record it belongs to — `PORTING.md` for porting work,
   `docs/CLOUD_TEAM_REDESIGN_NOTES.md` for a decision, `docs/build-findings.md`
   for a defect. Record the how, why, what, when, and every decision made.
   Continuous, not a final step.

> **Inherited doc references.** Comments and older documents cite paths like
> `docs/manual-deployment-guide.md`, `docs/explained/01 §3` and
> `docs/prod-deploy-run-*.md`. Those documented the **pre-redesign** `besu-aws`
> build — one Terraform root, a VPC we created, NAT egress — and were deleted here
> rather than left to mislead. They remain in the frozen reference repo at
> `../../besu-aws` (working tree and git history). Look there for the *why* behind
> an F-number or a control; never for how this project is laid out.

5. **Verify versions; do not assume.** Confirm the current value from the
   authoritative source before pinning anything — Besu, EKS, charts, providers,
   addons. Resolve, then PIN. Never a floating tag in committed config.

6. **Deployment is ADVISE-ONLY.** Tell the human exactly what to run; do not execute
   `terraform apply`, `destroy`, `helm`, or billable AWS CLI calls unless explicitly
   asked. The purpose is the human's self-sufficiency at go-live.

7. **Nothing hardcoded** unless strictly required — registries, image digests, CIDRs,
   subnet IDs, hostnames, AZ IDs. Parameterise once, reference everywhere.

8. **Never apply any property that blocks immediate deletion** — no
   `deletion_protection`, no `prevent_destroy`, no S3 Object Lock. Teardown must stay
   instant.

---

## 1. What is being built (settled decisions — do not re-open)

A closed, permissioned Besu network for a financial institution whose only external
consumer is **SWIFT**, reaching **JSON-RPC** over SWIFT's private **MV-SIPN** network.

- **Consensus:** QBFT, 4 validators (N=3F+1, tolerates 1 failure).
- **Validator keys:** generated randomly, or imported when
  `use_provided_validator_keys=true`. At-rest custody under a customer-managed KMS
  CMK (`enable_node_key_cmk`, **C12** — prod-verified). KMS decrypts are CloudTrail
  **management** events (F31).
- **Fully private:** private subnets only, private EKS API endpoint
  (`eks_public_access=false`), no public node IPs.
- **SWIFT is NOT a network member** — no P2P, no enode. It is an external mTLS RPC
  client calling `eth_call`, `eth_sendRawTransaction`, `eth_getLogs`, with
  method-scoped authorisation. Because SWIFT originates transactions, its account
  addresses go on the file-based account allowlist and **must be funded at genesis**
  (`genesis_funded_accounts`, **F20** — a zero-balance account's transaction is never
  mined even on a zero-gas chain).
- **mTLS** on the JSON-RPC plane. CSR-signing is the default cert flow; PKCS12 is the
  fallback. Self-managed CA by default (`ca_mode=""`); AWS Private CA when
  `ca_mode="aws"`.
- **Permissioning:** node = **local** (file-based), account = **local** (file-based,
  **C6**). Both deny-by-default once active — genesis MUST seed the admin account and
  every validator/bootnode/RPC identity or the network bricks. Preflight enforces it.
  - **Smart-contract permissioning does not exist.** Besu removed it in 25.6.0
    (**F17**); on a pinned 26.x those flags crash-loop every node. The file-based
    replacement copies the `besu-account-allowlist` ConfigMap to a **writable,
    besu-owned** `/data/permissions_accounts.toml` (**F32/F32b** — wrong ownership
    or read-only produces `ERROR_ALLOWLIST_PERSIST_FAIL`).
  - Runtime onboarding via `scripts/permissioning/{add,remove,list}-account.sh`.
    `perm_reloadPermissionsFromFile` is a **silent no-op** — use the ConfigMap patch
    plus rolling restart, or the hot path with read-back verification (**H3**).
- **DR is OUT OF SCOPE.** Single-region by design. In-region HA only: 4-validator
  QBFT, AZ topology spread, PDB-gated rolling maintenance.
- **Observability:** Prometheus/Grafana + Alertmanager→SNS→email, Fluent Bit→
  CloudWatch Logs, native CloudWatch alarms, CloudTrail.
- **Explorer:** Blockscout, in-cluster and private, with a dedicated explorer-rpc
  pool carrying DEBUG/TRACE.

### What is new relative to `besu-aws`

- ~~**Two EKS clusters**, not one — ledger and applications, in the same VPC.~~ **Superseded by CT-5 (D-23/D-28): no cluster is ours. One shared cluster, two namespaces requested.**
- **The VPC is not ours.** Consumed via the input contract (§3).
- **No NAT/IGW.** Air-gapped supply chain (§5) is a first-class build stage.
- **Images from a private ECR registry** (CT-3), mirrored in from outside the VPC.
  One registry, no carve-out: the AWS-owned EKS addon images arrive by the same path.
- ~~**PrivateLink is retained** for the application→ledger path even within the single
  VPC — but same-VPC endpoint behaviour is **unvalidated** and must be smoke-tested
  early (§4, Phase 3).~~ **DELETED by CT-5 (D-28)** — one cluster, so ledger↔app is
  in-cluster traffic. No consumer endpoint, no Stage 3.0.

---

## 2. Repository structure & state layout

```
terraform/
  shared/     interface endpoints, gateway endpoints (conditional), Route 53 PHZ
  runner/     the In-VPC EC2 Runner (its own root and state)
  chain/      chain EKS + IAM + storage-csi + secrets/PKI + Besu + access
              + observability + Blockscout
  app/        app EKS + application workloads + PrivateLink consumer endpoint
  modules/    network-contract, endpoints, eks, iam, storage-csi, secrets, pki,
              besu, rpc-access, observability, blockscout, registry
helm/         charts + values
scripts/      preflight/, lib/, pki/, permissioning/, access/, maintenance/, validation/,
              runner/, supply-chain/   — indexed in scripts/README.md (where each RUNS,
              and read-only vs mutating vs irreversible); detail in each script's header
docs/         RUNBOOK.md, PORTING.md, build-findings.md, design records
```

**Naming — the In-VPC EC2 Runner.** The one EC2 instance built by `terraform/runner/` is
called the **In-VPC EC2 Runner** in every document, comment and message (settled
2026-10-09). It replaces "administrative instance", "admin instance", "deployment worker",
"the R-10 instance" and "in-VPC/SSM runner" — all the same machine. Bare "the runner" is
acceptable shorthand once the full name has appeared. The "In-VPC" is what separates it
from the cloud team's **GitHub Actions runners**, which sit outside the VPC with internet.
Exception: three AWS resource `description`s (the runner SG, both runner IAM policies)
keep the old wording, because changing an SG or IAM-policy description forces replacement.

**Four separate states.** Never let one touch another's resources:

| Root | Backend key | Contains |
|---|---|---|
| `shared` | `besu/<env>/shared.tfstate` | VPC endpoints, PHZ — used by BOTH clusters |
| `runner` | `besu/<env>/runner.tfstate` | the In-VPC EC2 Runner |
| `chain` | `besu/<env>/chain.tfstate` | ledger cluster and everything on it |
| `app` | `besu/<env>/app.tfstate` | application cluster |

**`<env>` is `sit`, `uat` or `prod`, and it is NOT decoration.** The key was
`besu/platform/<root>.tfstate` until 2026-09-07 — the same four keys for every
environment. Applying `chain` in SIT and then in PROD would have reconciled PROD's
config against DEV's state and planned to adopt or destroy the other environment's
cluster. Four states separate the four **roots**; the `<env>` segment is what separates
the two **environments**, and both dimensions are required.

This also makes the key drivable from one variable, which is how the Octopus process
selects state per environment: `-backend-config="key=besu/#{Environment}/chain.tfstate"`
alongside `-var-file=environments/#{Environment}/...`. One value picks the state file and
names the resources, so the deployment artefact carries no environment of its own and the
same package promotes from DEV to PROD unchanged.

**Endpoints live in `shared`, not in `chain`.** Both clusters depend on them, so
destroying the ledger must not remove the application cluster's ability to reach KMS.

**Apply order:** `shared` → `runner` → `chain` → `app`.
**Teardown order:** `app` → `chain` → `runner` → `shared`.

`app` and `chain` may read `shared` via `terraform_remote_state` — that boundary is
inside our control. **Neither may ever read the cloud team's network state** (§3).

**On disk**, each root is a sibling directory under `terraform/`, with shared
`modules/` alongside them:

```
terraform/
  modules/       shared by every root; sources are ../modules/<name>
  contract/      handover.tf — the input contract + the 8 gates, NOT a root
  environments/  tfvars
  shared/  runner/  chain/  app/
  network-handover.auto.tfvars      emitted by the mimic; symlinked into each root
```

`contract/handover.tf` is **symlinked** into `shared/`, `chain/` and `app/` rather
than copied, so all three declare one identical contract and run the same gates —
three copies would drift, and the drift would only show up as one root accepting a
network another root rejects. The emitted tfvars is symlinked for the same reason.
Both symlinks are recreated by `mimic_vpc/scripts/emit-handover.sh`, because
`*.auto.tfvars` is gitignored and so are they.

---

## 3. The input contract — consuming someone else's network

The network arrives as **plain input variables**, delivered as a
`network-handover.auto.tfvars` fragment. **Never** via `terraform_remote_state`: the
real cloud team will not grant state access, so building that dependency would work
in deploy-tests and fail at go-live.

Required inputs: `vpc_id`, `vpc_cidr_primary`, `vpc_cidr_secondary`, `az_ids`,
`ledger_subnet_ids`, `app_subnet_ids`, `lb_subnet_ids`, `endpoint_subnet_ids`,
`data_subnet_ids`, the four route-table ID maps, `ledger_nacl_ids`,
`gateway_endpoints_created_here`, `dhcp_options_id`. Subnet maps are keyed by
**AZ ID**, never by index or AZ name.

### `modules/network-contract` — creates nothing, asserts everything

The single highest-value module in this project. Using `data` sources with
`precondition` / `check` blocks, it fails in seconds with an actionable message
rather than twenty minutes into an EKS apply:

- VPC exists, and `instance_tenancy == "default"`
- `enableDnsSupport` and `enableDnsHostnames` both true
- subnets exist, in exactly 3 distinct AZs, matching the supplied AZ IDs
- `kubernetes.io/role/internal-elb=1` present on every LB subnet
- free IP count per subnet above the threshold this deployment needs
- **no `0.0.0.0/0` route** in any supplied route table
- the EKS service CIDR does not overlap the VPC's primary or secondary CIDR
- required VPC endpoints resolve and are reachable
- the ECR endpoints resolve (Private DNS on) and are reachable from the node subnets

Every assertion maps to a numbered requirement in
`NETWORK_REQUIREMENTS_CLOUD_TEAM.md`. Cite the number in the failure message so the
human can quote it straight back to the cloud team.

> **CT-5 (D-30):** four of these go when the code is updated — AZ placement, the
> `internal-elb` tag (#4, withdrawn), free-IP capacity and the service-CIDR overlap (#9,
> withdrawn) all concern subnets and a cluster that are no longer ours. The VPC
> attributes, the no-default-route check and the two region gates stay. The subnet
> inputs move to the **cluster** hand-over, and a new `modules/cluster-contract` carries
> the cluster-side gates (§12.5 of the redesign notes). **The code still has all eight**
> — nothing is removed until shared-cluster requirements §4 is answered.

---

## 4. Build phases

### Phase 2 — Ledger platform

| Stage | Contents |
|---|---|
| 2.0 | `shared`: interface endpoints (§5.1), gateway endpoints if `gateway_endpoints_created_here=false`, Route 53 PHZ |
| 2.1 | `runner`: In-VPC EC2 Runner, source and static tooling delivered by S3 bundle |
| 2.2 | Chain EKS cluster, IAM/IRSA, storage-csi, node group with registry-aware bootstrap |
| 2.3 | Secrets + PKI — CA bootstrap per `ca_mode`, keystores, Secrets Manager, SecretProviderClass, C12 CMK custody |
| 2.4 | Besu workloads — genesis with QBFT extraData + permissioning seed + preflight, bootnodes, validators with PDB and topology spread, RPC pools |
| 2.5 | SWIFT/SIPN access — internal NLB, mTLS, method scoping, join-pack and cert scripts |
| 2.6 | Observability |
| 2.7 | Blockscout + dedicated explorer-rpc pool |

### Phase 3 — Application platform

| Stage | Contents |
|---|---|
| 3.0 | **Same-VPC PrivateLink smoke test — do this FIRST** (see below) |
| 3.1 | Application EKS cluster, IAM/IRSA, node group |
| 3.2 | PrivateLink consumer endpoint → the ledger's app-rpc NLB |
| 3.3 | Application workloads, internal ALB, NetworkPolicy, namespace quotas |

**Stage 3.0 is a gate, not a formality.** AWS documents neither permit nor forbid a
consumer interface endpoint in the same VPC as the provider NLB, and there is a known
sharp edge when endpoint ENIs share a subnet with NLB nodes — which is why endpoint
and LB subnets are separate (#16). Spend ten minutes proving the path works before
building anything on top of it. If it fails, the fallback is a direct internal NLB
with security-group and NetworkPolicy isolation, and the human must be told the
isolation posture changed.

---

## 5. Air-gapped supply chain

### 5.1 VPC endpoints (`shared` state)

**Gateway, free:** `s3`, `dynamodb`.

`s3` is the load-bearing one: container image **layers** (ECR serves manifests, S3 serves
bytes), Terraform **state**, the Terraform **state lock** (`use_lockfile` writes a `.tflock`
object — there is **no DynamoDB lock table**; that mechanism was deprecated in Terraform
1.11), and the runner's toolchain + source bundle (D-21).

`dynamodb` is **currently unused**. It is provisioned for the event pipeline's tailer
**cursor** table (E-4), which is not built yet. Gateway endpoints are free, so it costs
nothing to hold — but do not cite it as a Terraform-locking dependency, because it is not
one.
Created here only when `gateway_endpoints_created_here = false`.

**Interface, 15 × 3 AZ:** `ssm`, `ssmmessages`, `ec2messages` (the only path to the
runner — without these there is no access at all), `ec2`, `ecr.api`, `ecr.dkr`,
`sts`, `eks`, `elasticloadbalancing`, `secretsmanager`, `kms`, `logs`, `monitoring`,
`sns`, **`sqs`**.

`sqs` and `sns` carry the event pipeline (`docs/EVENT_LISTENER_DESIGN_NOTES.md`
§7). `sns` was already required for Alertmanager, so the pipeline adds only ONE
endpoint, not two — ~$28/mo in af-south-1.

**Deliberately excluded:** `eks-auth` (we use IRSA, not Pod Identity) and `autoscaling`
(no Cluster Autoscaler or Karpenter is deployed). If either is ever introduced, its
endpoint must be added in the same change.

> **CT-5 makes the first exclusion conditional, not a choice.** The pod-identity mechanism
> is the cluster owner's (#31). If the answer is **Pod Identity**, `eks-auth` IS required —
> and in this VPC a missing endpoint hangs rather than errors. `REQUIRED_INTERFACE` in
> `scripts/preflight/verify-endpoints.sh` is a static array; it becomes conditional on the
> cluster hand-over's `pod_identity` rather than hand-edited (§12.13.3). D-14 already
> recorded the reasoning; this is where the code lives.

`monitoring` is retained as insurance even though nothing obviously publishes custom
metrics — a missing endpoint hangs rather than errors, and the debugging cost exceeds
the endpoint cost.

**Every new AWS service used by any workload in this VPC needs its own endpoint.**
Treat "add an AWS service" as "add an endpoint" in the same change.

### 5.2 Images — private ECR, mirrored from outside (CT-3)

**ECR is a registry, not a proxy.** Nothing appears in it on demand. Artefacts are
copied in deliberately, from a build host **outside** the VPC; workloads inside the
VPC only ever pull, over the `ecr.api` / `ecr.dkr` interface endpoints plus the `s3`
gateway endpoint. **Pull-through cache CANNOT be used** — AWS requires an internet
route on the first pull through a PTC rule when ECR is reached via an interface
endpoint, and this VPC has none (**D-17**). Owning a mirror pipeline is therefore a
standing commitment for the life of the platform, not a setup step.

- Single `registry_host` variable threaded from the root; per-component `repository`
  and **`digest`**. Pin by digest, not tag (**H38**).
- **Nothing hardcoded.** In `besu-aws` these are hardcoded and must be
  parameterised on port: `alpine/k8s` in the besu-node values, and in the Blockscout
  values four `ghcr.io/blockscout/*` images plus `nginx` and `postgres`.
- **One registry, no exception.** The AWS-owned EKS addon images (`vpc-cni`,
  `coredns`, `kube-proxy`) come from AWS's own ECR account and reach us through the
  same `ecr.api` / `ecr.dkr` / `s3` endpoints as everything else. Do not self-manage
  those addons — it forfeits EKS-managed patching and buys nothing.
- **The mirror MUST preserve digests** — `crane copy` or `skopeo copy --all` only
  (**D-18**). `docker pull` / `tag` / `push` re-manifests on push and **changes the
  digest**, silently invalidating every H38 pin and every `verify-images.sh` result.
- **No CA trust work and no pull secret.** ECR presents a publicly-trusted
  certificate (`registry_cert_publicly_trusted = true`, `registry_ca_cert_pem = ""`),
  and kubelet's ECR credential provider authenticates from the node role. There is no
  `dockerconfigjson` to store or rotate.
- **The three registry traps are network-policy traps, not certificate traps**, and
  they all present as a generic `ImagePullBackOff` or a stalled layer download:
  1. the **S3 gateway endpoint policy must allow `arn:aws:s3:::prod-<region>-starport-layer-bucket/*`**
     — ECR serves manifests, but layers come from S3;
  2. **Private DNS must be enabled** on `ecr.api` and `ecr.dkr`, and the VPC must use
     AWS-provided DNS (endpoints support no other resolver);
  3. the **ECR endpoint policy must not be scoped to a single account**, or the
     cross-account addon pulls break. The EKS addon registry account is **region-specific**:
     af-south-1 is **`877085696533`**, NOT the widely-quoted `602401143452` (which covers
     us-east-1, eu-west-1 and most other regions). Copying the common value into an
     af-south-1 policy fails exactly as if the policy were absent.
  All three are caught by §5.4, run from the runner.
- **Repository hygiene:** tag immutability **ON**, and **no lifecycle expiry** — a
  validator replaced eight months from now must still find its exact digest.
- **We own freshness.** No proxy means no auto-fetch: any `besu_version`, chart or
  addon bump that is not mirrored first reproduces exactly the hang this design
  exists to prevent. §5.4 gates it.

### 5.3 Charts, providers, source

- **Helm charts become OCI artefacts in ECR.** The five upstream charts
  (kube-prometheus-stack, aws-for-fluent-bit, aws-load-balancer-controller,
  secrets-store-csi-driver and its AWS provider) are `helm pull`ed on the build host
  and `helm push`ed to `oci://<acct>.dkr.ecr.<region>.amazonaws.com/charts`, with
  `repository_username` / `repository_password` from `data.aws_ecr_authorization_token`
  (12-hour validity). Verify each packaged `.tgz` carries its subcharts — a chart that
  resolved dependencies at install time would reach for the internet.
- **Terraform providers: `terraform providers mirror` into S3**, synced to the runner
  and wired through `.terraformrc` as a **`filesystem_mirror`** — filesystem, not
  network: a network mirror needs an HTTPS service, a filesystem mirror needs only a
  directory, and the S3 gateway endpoint already carries it (**D-20**). Needed only for
  the In-VPC EC2 Runner; AWS-layer applies run from the laptop, which has internet.
- **Runner source and tooling: S3 bundle — IMPLEMENTED (D-21).** GitHub is
  unreachable and the runner carries **no package-manager dependency**. The chain root
  creates `<prefix>-runner-artifacts`; `scripts/runner/push-runner-bundle.sh` downloads
  the pinned toolchain on the laptop (verifying each sha256 against
  `scripts/runner/runner-tools.manifest`), unpacks it there, and uploads
  `tools/tools.tar.gz` + `source/source.tar.gz` (`git archive` HEAD). The runner pulls
  both over the **S3 gateway endpoint** at boot. Its only prerequisites are `aws`, `tar`
  and `gzip`, all in the AL2023 base AMI. **The GitHub PAT is GONE** — with it, the
  F28/H18/H39 findings it generated. Run the push between the chain AWS-layer apply and
  `terraform/runner`.
- **The Corretto JRE is in the bundle and is not optional** — `scripts/pki/issue-server-cert.sh`
  needs `keytool`, because an openssl-built PKCS12 truststore makes Besu throw a TLS
  internal error during client-cert validation.
- **ECR cannot host Maven, npm or OS packages.** If a workload ever needs them, that is
  a separate ask (CodeArtifact, or an S3-hosted repository) — not a registry change.

### 5.4 `scripts/preflight/verify-images.sh`

Resolve every image reference in the repository and confirm each **digest** exists in
the registry **before** apply, **run from the In-VPC EC2 Runner** — never the laptop, which
would pass while the cluster still cannot pull. Cheap, and it converts a 2am
`ImagePullBackOff` into a ten-second failure. It is a hard precondition of the chain
apply **and** of any validator image bump (**D-19**).

**Known gap 1:** it resolves `local.image_ref`, which covers only the 8 images this
repository names directly. The **15 images carried by the five upstream charts** have no
verification path, so it can exit 0 with 15 images missing. See `../CHART_IMAGES.md` and
PORTING item 4.

> **Known gap 2 — CT-5 (D-38): it proves the WRONG PRINCIPAL.** It authenticates with
> `REGISTRY_USER`/`REGISTRY_PASS` (lines 93–101), i.e. the runner's credentials. Under CT-5
> the pull is kubelet's, with the **cloud team's node role** via the ECR credential
> provider — a different principal against different policies, and this script exits 0
> either way. The sentence above ("never the laptop, which would pass while the cluster
> still cannot pull") now understates it: the *runner* passes while the cluster cannot
> pull. **Its exit 0 does not mean the cluster can pull.** Requirement #38 is closed by a
> repository-policy assertion on their node role ARN, a check that that role's identity
> policy carries `ecr:GetAuthorizationToken` (no repository policy can grant it), and a
> **canary pod** — the only authoritative proof. Spec: redesign notes §12.13.

---

## 6. Isolation model

Consolidating into one VPC removed the boundary PrivateLink used to provide. Rebuild
it deliberately — this is **more** work than the two-VPC design, not less:

- **NetworkPolicy default-deny is MANDATORY** in both clusters (it ships opt-in as
  H6 in `besu-aws`; here it is not optional).
- **Dedicated node group for validators, with taints**, so application pods can never
  co-schedule with a validator.
- **Separate namespaces with `ResourceQuota`.**
- **Security groups scoped per tier** — validators, SWIFT RPC pool, app RPC pool,
  explorer, applications — never "the VPC CIDR".
- **NACL rules on the ledger subnets** (the cloud team owns the NACLs; we manage the
  rules). A stateless L3 boundary that does not depend on security-group correctness.
- **Subnet-level flow logs** on the ledger subnets, delivered to our destination.

---

## 6a. Event pipeline (SWIFT actions)

Full design: **`docs/EVENT_LISTENER_DESIGN_NOTES.md`** (decisions E-1..E-20).
Architecture: `chain-tailer` polls `eth_getLogs` against a durable cursor →
SNS FIFO (fan-out) → SQS FIFO queues → plain poller consumers → S3 Parquet
archive. Load these rules before touching any of it:

- **NO LAMBDA ANYWHERE (E-15).** Hard constraint from the human. Every consumer
  is an EKS pod; the archive path is a pod, not Firehose.
- **The chain is the system of record (E-1).** The messaging tier is transport
  and fan-out, never the source of truth.
- **The cursor advances only after the SNS publish is acknowledged (E-4)** →
  at-least-once with dedupe, never at-most-once.
- **Event ID = `chainId:blockHash:txHash:logIndex` (E-3)**, the idempotency key
  at every hop. `MessageDeduplicationId = sha256(eventId)` (E-18) because the raw
  ID exceeds SQS's 128-character limit.
- **SQS FIFO "exactly-once" is a 5-minute window and is NOT the idempotency
  mechanism (E-17).** Business-level idempotency lives in the Solidity contract
  (`uetr` → processed, E-9).
- **Single-writer nonce management (E-8)** for transaction submission — a
  structural constraint in the same spirit as the H1 validator rolling rule, not
  operational discipline.
- **The SQS delete is gated on the receiving system's DURABLE ack (E-20)**, never
  on a transport-level acknowledgement.
- **Scheduled chain-vs-archive-vs-downstream reconciliation is mandatory (E-12)**,
  with the cursor-rewind procedure as the ultimate backstop. Write it as a runbook.
- **No transport-specific concepts in the envelope schema or consumer logic
  (E-5).** Amazon MSK is retained as option 2 (E-19); keeping the seam clean means
  switching stays a decision rather than a rebuild.
- ~~**The listener runs in the APPLICATION cluster (E-14)**, reaching the chain over
  PrivateLink. This makes PrivateLink a **data-path** dependency.~~ **RE-SCOPED by CT-5
  (D-28):** the listener runs in the **application namespace**, reaching the chain
  **in-cluster**. The intent — never sharing a failure domain or a node with the
  validators — is unchanged, but it now rests on `NetworkPolicy` (H6/D-9) and the #28 node
  taint rather than on a cluster boundary. **PrivateLink is no longer a data-path
  dependency, so the Stage 3.0 risk this raised is void.**

---

## 7. Version policy and the validator rolling rule

- **Besu:** latest stable, resolved then PINNED. Deploy the official image, mirrored
  into ECR.
- **EKS:** 1.35 default. Fallback ladder on incompatibility: 1.35 → 1.34 → …
  **Falling out of standard support raises the control plane from $0.10/hr to
  $0.60/hr** — version currency now has a direct cost, per cluster.
- **QBFT rolling-upgrade caveat:** 25.x → 26.x needs
  `--Xbft-legacy-protocol-encoding` for wire compatibility. Fresh single-version
  deploys are unaffected.

### NEVER upgrade validators all at once — HARD RULE

QBFT with N=3F+1 needs a quorum of 2F+1 online (4 validators ⇒ 3 of 4). **Exactly one
validator may be down at a time.** A blanket `terraform apply` that bumps the image
updates every validator in parallel → all restart together → quorum lost → **chain
HALT**.

**This is structurally prevented (H1):** validators live in their own
`helm_release.validator` with `lifecycle { ignore_changes = [values] }`, and the chart
pins them to `updateStrategy: OnDelete`. A blanket apply is a no-op on validators.

Make any validator-affecting change **only** through
`scripts/maintenance/rolling-besu-apply.sh` (or the `rolling-besu-upgrade.sh` wrapper
for a plain image bump): helm-upgrade, then delete **one** validator pod at a time,
verifying the chain kept producing and the node caught up before the next.

**The PDB does not protect against this.** `maxUnavailable=0` gates *evictions and
drains*, not StatefulSet image updates. H1's `ignore_changes` plus `OnDelete` is what
closes the gap.

**Node upgrades:** the validator PDB deliberately blocks automatic eviction, so node
rotation stalls on validator nodes by design. Rotate one at a time with a controlled
cordon / verify-quorum / drain. **NEVER `--force` a node-group update** — it ignores
PDBs and can drop a validator.

---

## 8. Baseline to port from `besu-aws`

Do not rediscover any of this. Port it, and preserve the reasoning comments.

- **C6** file-based account permissioning, including F32/F32b file ownership.
- **C10** startup gate — closes F27, a non-deterministic DNS race that halted a chain.
  This was a go-live blocker; it must be present.
- **C12** KMS CMK node-key custody, with scoped IRSA.
- **H1–H27** hardening items, prod-validated 2026-07-11. H27 was deferred (risky
  secret rename); H17 is partial. **H5** includes an IAM permissions boundary on all
  chain roles plus an escalation-proof runner policy — static-validated only, so
  apply-validation is an open gap to close on the first deploy-test here.
- **F1–F33** deploy-test findings. The ones most likely to bite in this build:
  **F19** (issue RPC server certs and push the JWT *between* the AWS-layer apply and
  the in-cluster apply — node permissioning resolves allowlist enode DNS once at
  startup, so a TLS pool that boots late is rejected forever), **F20** (genesis
  funding), **F30** (bare `xargs` state-rm strips `for_each` quotes and silently
  skips resources), and the Secrets Manager 30-day-deletion collision trap.
- `scripts/validation/hardening-validation.sh` — prod-safe, read-only.

---

## 9. Teardown

Same-day teardown is mandatory. Order: `app` → `chain` → `runner` → `shared`.

The laptop cannot reach the private EKS endpoint, so in-cluster resources must be
`state rm`'d before destroying the AWS layer, then EBS swept by `DeletionGroup` tag,
then zero-checked.

**`full-delete.sh` changes for a shared VPC:**

1. **Drop the NAT and EIP sweep** — neither exists.
2. **Add a resource-type denylist enforced on the tag-API results, and ABORT on a
   hit.** In a shared VPC a tag collision on the cloud team's side means we delete
   **their network**. Abort if any returned ARN is a `vpc`, `subnet`, `route-table`,
   `internet-gateway`, `transit-gateway*`, `vpc-peering-connection`, or
   `dhcp-options`. **Abort, never skip-and-continue** — a collision means the tagging
   assumption is broken and nothing after it is trustworthy.
3. **Add a leaked-ENI sweep**, and add it to zero-check. Orphaned load-balancer and
   endpoint ENIs used to be cosmetic; against the cloud team's scarce address space
   a leak is a cross-team incident.

Append a row to `docs/test-run-log.md` for every apply/destroy cycle.

---

## 10. Definition of done for a stage

Code written and commented · `terraform fmt` and `validate` pass · docs updated ·
`plan` shown to the human · `network-contract` assertions pass · `verify-images.sh`
passes — **and, under CT-5, so do `verify-cluster.sh`, `verify-admission.sh` and
`verify-pull-canary.sh`; `verify-images.sh` alone no longer proves the supply chain
(D-38), and `scripts/validation/verify-deployed.sh` is the post-deploy half (D-36).
A WARN from any of them is not a pass** · and, with human approval, verify-deployed and then torn down within the cost
guardrail. Then — and only then — move to the next stage.

---

## 10a. Region portability

**All three environments run in `af-south-1`** (Cape Town) — `sit` (Octopus
**SIT**), `uat` (Octopus **UAT**) and `prod` (Octopus **PROD**). Three environments
as of 2026-09-09; af-south-1 confirmed enabled on the target bank account the same
day. Deploy-tests previously ran in
`us-east-1`; that is retired, because a test in another region does not prove the
things most likely to break in af-south-1 — endpoint-service availability, per-AZ
instance-type availability, and the AZ IDs themselves.

Two consequences, both hard:

- **af-south-1 is an OPT-IN region — ✅ VERIFIED ENABLED 2026-09-04.**
  `scripts/preflight/verify-region.sh af-south-1 m6i.xlarge 1.35` returned 7 passed /
  0 failed: region enabled, 3 AZs, `m6i.xlarge` offered in all three, all 15 interface
  endpoint services plus both gateway services available, EKS 1.35 offered.
  `az_ids = ["afs1-az1","afs1-az2","afs1-az3"]`. Re-run the gate on any region or
  instance-family change — it is free and read-only.
- **It costs ~31% more than us-east-1**, so the per-run cost guardrail (§0.3) buys
  fewer hours. Same-day teardown matters more, not less.

**Switching region is a tfvars change, never a code change.** Nothing in the
Terraform hardcodes a region — every region-scoped value is derived from
`var.primary_region`, including VPC endpoint service names and the DHCP domain
name. `primary_region` has **no default** in any root: for a financial ledger the
region carries data-residency consequences and must be an explicit, reviewed
choice, not something a forgotten variable decides.

### The one input that does not travel

`az_ids`. AZ IDs are region-scoped (`use1-az1` vs `afs1-az1`), so a region switch
with stale AZ IDs is the obvious failure. Two gates catch it:

- `modules/network-contract` **Gate 7** asserts the AZ IDs exist in the configured
  region, and that they match the AZs the supplied subnets are actually in — the
  latter catches a stale `network-handover.auto.tfvars` from a previous region.
- The mimic project has the equivalent gate on its own inputs.

### Procedure

```bash
# 1. Prove the target region can host the design (read-only, ~10s, free)
scripts/preflight/verify-region.sh af-south-1 m6i.xlarge 1.35
```

It checks opt-in status, AZ count, **per-AZ** instance-type availability (a family
offered in only 2 of 3 zones breaks validator spread even though it "exists" in the
region), all 14 interface endpoint services plus the two gateway services, and the
EKS version. It prints the `az_ids` line to paste into tfvars.

```bash
# 2. Enable the region if needed  (takes a few minutes)
aws account enable-region --region-name af-south-1

# 3. Switch tfvars: primary_region + az_ids. Re-request the network hand-over
#    from the cloud team for the new region — subnet IDs do not travel either.
```

**Note for af-south-1:** it has exactly three AZs, so the design consumes all of
them. Unlike a larger region there is no fourth zone to grow into; the address
reserve exists for an additional workload tier, not another AZ.

---

## 10b. CI/CD — GitHub Actions + Octopus Deploy

Full record: **`docs/CICD_DESIGN_NOTES.md`** (decisions CD-1..CD-64, cloud-team
questions CQ-1..CQ-8, R-1..R-10). Load it before touching a workflow or an Octopus project.

- **Octopus deploys BOTH the Terraform applies and the Helm releases** (CD-1). GitHub
  Actions never touches a cluster or an AWS environment (CD-2) — it mirrors, packages
  and publishes. Actions runners have internet; the VPC does not. That boundary is the
  control, not ceremony.
- **The workflows live at the MONOREPO root**, `../.github/workflows/`, not under
  `sbsa_besu/` — GitHub ignores any other location. Each job sets
  `working-directory: sbsa_besu` and its path filters carry the `sbsa_besu/` prefix;
  the scripts resolve their own files from `${BASH_SOURCE[0]}`, so they need nothing.
- **Three Octopus projects** (CD-4): `besu-infra` (Terraform, in apply order),
  `besu-workloads` (in-cluster Helm), and **`besu-validators` — separate on purpose**.
- **THE VALIDATOR RELEASE IS NEVER DEPLOYED BY A HELM STEP** (CD-5). A standard "Deploy
  Helm Chart" step updates all four StatefulSet templates at once → they restart together
  → quorum lost → **chain halt**. The only path is `rolling-besu-apply.sh` behind a
  mandatory manual-intervention gate, in ALL THREE environments, plus the H38 plan-safety CI
  check that fails a build which would restart more than one validator.
- **Octopus IS Octopus Cloud (SaaS), and it reaches the private endpoint through a
  POLLING TENTACLE WORKER ON THE IN-VPC EC2 RUNNER, via the bank's SHARED EGRESS PROXY**
  (R-9 closed 2026-09-14 on option 1 — CD-55; mechanism CD-57; §7 of the design notes).
  Not the Kubernetes Agent. The runner is therefore both the Octopus worker AND the
  break-glass shell (CD-53) — never remove it. The rules that fall out, all decided
  because the cloud team will not describe the egress internals (CD-56..CD-62):
    * explicit `CONNECT` proxy at `egress_proxy_host:port` from the hand-over file
      `terraform/egress-handover.auto.tfvars` (mimic: `mimic_egress`; prod: typed from
      the R-10 ticket reply);
    * **Tentacle `polling-proxy` ON, `proxy` (web-request) OFF, and NEVER a host-wide
      `HTTP(S)_PROXY` on the runner** — the web-request proxy is exported to every step
      and would send terraform/aws/kubectl at the bank proxy instead of the VPC endpoints;
    * **no TLS interception** on the two Octopus hostnames — protocol requirement, not
      preference; `scripts/preflight/verify-egress-proxy.sh` probe 7 proves it and
      `install-tentacle.sh` refuses to register if it fails;
    * port **443**, exactly **two** hostnames (`<instance>.octopus.app`,
      `polling.<instance>.octopus.app`); the Tentacle tarball ships in the S3 bundle
      (manifest row `tentacle`) so no download host ever joins the allowlist;
    * the runner's IP is **pinned** (`runner_private_ip`, defaulting to the hand-over's
      `egress_allowed_source`) — the allowlisted /32;
    * **stop/start the runner between deployments** where you can. A re-created runner
      needs `install-tentacle.sh` re-run; the certificate comes back from its secret
      (CD-61), so `--force` updates the same worker with the same thumbprint (proven
      2026-10-10). Its pinned IP must be free: B43, `terraform/runner/ip-guard.tf`.
  Sequence: `docs/RUNBOOK.md` Phase E.1 (✅ 2026-09-17) and E.3. **Mock-deployed end to end
  2026-10-10:** all three projects from GitHub releases, OIDC at both hops
  (`docs/deploy-run-2026-10-10-octopus-phase4.md`). **2026-10-11: the chain itself** — the in-cluster
  layer from `besu-workloads` on the runner, air-gapped; a transaction seen in Blockscout. Platform
  state lives in the deploy region (B49); the runner plans the in-cluster layer only, `-refresh=false`
  behind a CD-53 gate (B50) (`docs/deploy-run-2026-10-11-chain-explorer.md`, RUNBOOK E.4).
- **No bank-specific value is ever committed** (CD-10) — account IDs, registry hosts,
  org names, runner labels, Octopus URL/space are all GitHub secrets/variables or tfvars.

---

## 11. Open questions inherited from the design phase

> **2026-09-21:** every row below is answered, moot or re-scoped by CT-5. **The live
> questions are Q-8..Q-18** in `docs/CLOUD_TEAM_REDESIGN_NOTES.md` §12.11, and they are
> answered by the three command outputs in `docs/CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md` §4.

These are **parameters, not structural forks**. Build with the air-gapped assumption
as the default and capture each unknown as an explicit variable plus a preflight
assertion.

| # | Question | What changes |
|---|---|---|
| ~~Q-0~~ | **ANSWERED: `af-south-1`.** Opt-in region — enable on the account first. Exactly 3 AZs, all consumed by the design. Verify `m6i.xlarge` is offered in **all three** AZs before committing the node group. | RESOLVED |
| ~~Q-1~~ | **ANSWERED (assumed): our own account, not RAM-shared.** ~~PrivateLink is unconstrained; Stage 3.0 remains a gate.~~ **CT-5: PrivateLink and Stage 3.0 are deleted (D-28).** The tenancy question itself still matters — it decides what we may create *beside* the cluster (KMS, NLBs, IAM) — and is tracked as R-3. | RESOLVED (assumption) |
| ~~Q-2~~ | ~~Do centralised interface endpoints exist?~~ | **ANSWERED by CT-5.** Their cluster's tenants need the same endpoints, so they exist and are theirs; `shared` creates none in the bank (CD-39 already made this the production setting). Requirement #15 withdrawn; **#20/#22/#23 remain as verifications.** |
| Q-2a | **Which AWS account OWNS the VPC** (i.e. is it RAM-shared into ours)? | **Largely defused by CT-5** — we create no endpoints, route tables, NACLs or subnet flow logs either way, so the RAM restrictions have nothing left to forbid and #4/#10/#13/#14 have all moved to the cloud team regardless. What the answer still decides is what we may create **beside** the cluster — KMS keys, Secrets Manager, NLBs, IAM roles, S3 — which is why it stays open as **R-3**. Security groups stay ours. |
| ~~Q-3~~ | **ANSWERED 2026-09-14: a shared, LB-fronted egress proxy exists (option 1, CD-55).** Design for air-gap STANDS (D-3): the ONLY consumer of the proxy is the Tentacle's polling channel on the runner. No proxy plumbing in containerd, kubelet, the SDKs or any pod — a specific-prefix route in the ledger tables, never a default route. | RESOLVED |
| ~~Q-4~~ | **ANSWERED 2026-09-09: a central shared-services account, in `af-south-1`, with tag immutability on and no lifecycle expiry** (CD-27, CD-28). CVE gating and pipeline ownership are still unconfirmed — tracked as Q-4c/Q-4d in the requirements document §8.4. **CT-5 adds #38:** the repository policies must grant pull to **their** node role, not ours. | RESOLVED (topology) |
| ~~Q-5~~ | ~~Golden AMI mandated, and which OS family?~~ | **MOOT under CT-5** — the nodes are the cloud team's, so the AMI, its patching and `ami_type` are all theirs. What replaces it is **#36**: their Kubernetes version and upgrade cadence, because Besu must be compatibility-tested before each of their upgrades. |

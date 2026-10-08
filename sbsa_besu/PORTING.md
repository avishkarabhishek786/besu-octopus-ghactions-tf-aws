# Porting status — `besu-aws` → `sbsa_besu`

Forked from `besu-aws@prod` (`83661d6`), which already carries the C6/C10/C12 +
H1–H27 hardening baseline. `upstream` still points at the source repo, so later
fixes can be cherry-picked.

**Guiding rule (CLAUDE.md): this is a PORT, not a rewrite.** The reasoning
comments in the inherited modules encode findings F1–F33 and hardening items
H1–H39. Preserve them.

> **⚠️ CT-5 — 2026-09-21: paused at item 4.** The cloud team provides a **shared EKS cluster
> and a namespace**; we no longer build EKS. Items **5** (second cluster, Stage 3.0) and **6**
> (node group + per-tier SGs) are **superseded as written**; item **4**'s remaining work (OCI
> charts, chart-image overrides, B13) mostly disappears if the cloud team confirms they provide
> the four add-ons (#30); item **7** gains an EKS/namespace denylist. The replacement work —
> `modules/cluster-contract`, the cluster hand-over, `verify-subnet-rules.sh`, `mimic_eks`, and
> the removal of `modules/eks` / `storage-csi` / the four add-on releases — is listed in
> `docs/CLOUD_TEAM_REDESIGN_NOTES.md` **§12.6** and starts once **§9 of the requirements
> document is answered**. Branch `shared-eks-namespace`; the pre-CT-5 build is frozen on
> `own-eks-cluster-design`.

---

## Done

| | |
|---|---|
| ✅ | Forked from the clean deployable line; `origin` → `upstream`, branch `main` |
| ✅ | `CLAUDE.md` replaced with the platform brief |
| ✅ | `docs/NETWORK_REQUIREMENTS_CLOUD_TEAM.md`, `docs/CLOUD_TEAM_REDESIGN_NOTES.md` |
| ✅ | **`modules/network-contract`** — creates nothing, asserts everything, 8 gates |
| ✅ | **`terraform/handover.tf`** — the input contract + the gate wiring |
| ✅ | **`module "network"` DELETED** and `modules/network/` removed — this project can no longer create a VPC |
| ✅ | EKS rewired to **ledger** subnets (#11); `rpc-access` rewired to **lb** subnets (#4) |
| ✅ | `terraform validate` passes |

### The eight gates in `modules/network-contract`

Implemented with `terraform_data` + `lifecycle` preconditions, **not** `check`
blocks — `check` only warns, and these must block the plan. Each failure message
cites the requirement number so it can be quoted back to the cloud team.

1. VPC attributes — `instance_tenancy=default` (#1), both DNS attributes (#2), CIDR matches the contract
2. AZ placement — exactly 3 AZ IDs (#5), subnets belong to the VPC, no public-IP-on-launch
3. Load-balancer discovery tag (#4) — *the nastiest failure in the contract: without it everything provisions cleanly and the SWIFT NLB simply never appears, days later*
4. No egress — no `0.0.0.0/0` route (#12), no IGW route, no NAT route
5. Capacity — free-IP floors per subnet (#11)
6. EKS service CIDR overlap (#9) — **immutable after cluster creation**, so tested with real integer CIDR arithmetic rather than eyeballed
7. Region portability — the `az_ids` are valid in the deploy region AND match the subnets' actual AZs
8. Region agreement — `deploy_region == network_region` (the hand-over carries the region it was emitted from)

---

## Remaining — in dependency order

### 1. Split into four roots (§2 of CLAUDE.md) — ✅ DONE 2026-08-30

| Root | Backend key | Contains |
|---|---|---|
| `shared` | `besu/<env>/shared.tfstate` | interface + gateway endpoints, Route 53 PHZ |
| `runner` | `besu/<env>/runner.tfstate` | in-VPC SSM runner (already its own root) |
| `chain` | `besu/<env>/chain.tfstate` | ledger cluster + Besu + access + observability + Blockscout |
| `app` | `besu/<env>/app.tfstate` | application cluster |

*(`<env>` = `sit` | `uat` | `prod`. Added 2026-09-07, environments renamed 2026-09-09 — the keys previously had no environment
segment, so the environments would have shared all four state files.)*

Endpoints belong in `shared`, **not** `chain`: both clusters depend on them, so
tearing down the ledger must not remove the app cluster's route to KMS.

Done: the inherited root moved to `terraform/chain/` (module sources rewritten to
`../modules/`), `handover.tf` extracted to `terraform/contract/` and **symlinked**
into each network-consuming root so the contract cannot drift between them, and
`emit-handover.sh` now recreates both symlinks (they are gitignored by
`*.auto.tfvars`, so a fresh clone would otherwise be unwired).

Moving the root cost nothing because no state existed yet. After the first apply
it would have been a state-migration exercise.

**`app/` is deliberately not created yet** — an empty root is noise. It lands in
item 5, where it gets real content.

**Defect found and fixed while wiring this:** `module "network_contract"` was the
only module in the repo not given `providers = { aws = aws.primary }`, so the
eight gates ran against the **default** provider — whose region comes from the
shell, not from `var.primary_region`. Both were `us-east-1` during Phase C, so it
passed either way. At go-live (`af-south-1`) the gates would have validated the
wrong region, and gate 8 could not have caught it: it compares two variables, not
the provider's actual region.

### 2. `shared` root — the endpoints — ✅ DONE 2026-08-30

15 interface endpoints × 3 AZ in the **endpoint** subnets, behind a 443-only SG
scoped to the primary **and** secondary VPC CIDRs (so enabling CNI custom
networking later does not silently break every AWS API call from a pod). Skipped
entirely when `central_interface_endpoints = true` (Q-2). Gateway endpoints
created only when `gateway_endpoints_exist = false` (#10), associated to the
ledger/app/lb/endpoint route tables — not `data`, which hosts managed databases
needing neither service.

Deliberately excluded: `eks-auth` (IRSA, not Pod Identity) and `autoscaling` (no
Cluster Autoscaler deployed). A validation rejects `s3` in the interface list —
it is the free gateway endpoint, and an interface endpoint for it would bill per
AZ for nothing.

Also added: the **private hosted zone**. `scripts/pki/issue-app-rpc-cert.sh`
issues the RPC server certificate for `rpc.chain.internal`, but nothing resolved
that name — the old two-VPC design got it from PrivateLink private DNS, and that
tree was stripped from the `prod` branch. In one shared VPC there is no such
mechanism, so without a zone every TLS client fails hostname verification. The
zone is created in `shared`; the `rpc` record is written by `chain`, the only
root that knows the NLB. That split keeps name resolution alive across a chain
teardown.

**Not yet applied** — `terraform validate` only.

### 3. Dead network variables — ✅ DONE 2026-08-30

Removed `single_nat_gateway`, `enable_flow_logs`, `primary_vpc_cidr` and
`availability_zone_count` — all orphaned when `modules/network` was deleted, and
all still being set in the tfvars, so they read like live configuration.

`primary_vpc_cidr` was not merely dead: `output "vpc_cidr"` was returning it, so
the chain plan reported **`10.0.0.0/16` for a VPC that is actually
`10.60.0.0/20`** — the variable's stale default, with nothing in this project able
to set it correctly any more. No root consumed that output yet, so it was latent;
it now reads `var.vpc_cidr_primary` from the hand-over. Anything scoping a
security group or NACL to that value would have been silently wrong.

**Noted, not changed:** `server_cert_ca_override`, `rpc_dual_pool`,
`swift_rpc_hostname` and `swift_permitted_methods` are declared with zero
Terraform references — but they are equally unreferenced in `besu-aws`, so this is
an upstream condition and not a wire the port dropped. `swift_permitted_methods`
is worth a look on its own merits, since method-scoped authorization is described
as a live control: whatever enforces it, it is not this variable.

### 4. Air-gapped supply chain (§5) — PARTIAL

**Done 2026-08-30 — image parameterisation:**

Every image is now declared once, as data, in `var.container_images` (host,
repository, tag, optional digest), resolved through `local.image_ref` with
`registry_host` + `registry_repo_prefixes`. Both layouts work: one group
repository mirroring upstream paths 1:1, or a proxy repo per upstream
(`docker.io -> docker-hub`). Verified by resolving both.

Three images were **not parameterised at all** — `stats`, `visualizer` and the
`nginx` proxy came from the Blockscout chart's `values.yaml`, hardcoded to
ghcr.io and docker.io. In a VPC with no egress those three pods would have hung
on ImagePullBackOff while every other component pulled from the mirror. `tools_image`
was equally broken in a quieter way: the module declared it, but the root never
set it, so it silently used the module default.

Also removed the duplicate Besu version: the tag was written both in
`local.besu_pinned_version`'s fallback and in the image list, free to disagree.

Three plan-time guards (`terraform_data.image_supply_chain`), all behaviour-tested
via `terraform console`:
- `require_image_digests` — refuses tag-pinned images, naming them (H38)
- an empty resolved reference
- **`environment = "prod"` with no `registry_host`** — the one that matters, since
  the default is upstream pulls and the symptom in the real VPC is a hang

`scripts/preflight/verify-images.sh` resolves the list *from Terraform* rather
than restating it (a second copy is a copy that can drift), pulls each manifest
via crane/skopeo/docker, and prints digests ready to paste back. Run it from the
in-VPC runner, which proves reachability from where the pulls happen.

**Done 2026-08-30 — containerd CA trust:**

`registry_ca_cert_pem` installs the private CA into every node's OS trust store
via launch-template user data, before the first image pull. Carried inline rather
than fetched at boot from Secrets Manager: a CA certificate is not secret, and a
boot-time fetch would make image-pull trust depend on a network call made before
trust exists — if it failed the node would join and then fail every pull with a
generic `ImagePullBackOff` naming nothing.

**AL2023 requires MIME multipart user data.** A bare shell script is not merged
with EKS's `NodeConfig` part, the node never finishes bootstrapping, and the node
group rolls back after ~15 minutes with no useful message. `ami_type` is now set
explicitly (`AL2023_x86_64_STANDARD`, validated) rather than left to the API
default, because the user_data contract depends on it.

The rendering was **verified, not assumed** — rendered with a sample PEM and
checked with Python's `email` parser: multipart with one `text/x-shellscript`
part, every boundary at column 0, the interpolated PEM's continuation lines
surviving the `<<-` stripping, the shell heredoc terminator at column 0, and the
fragment passing `bash -n`.

A fourth guard refuses `environment = "prod"` + `registry_host` with no CA, with
`registry_cert_publicly_trusted` as an explicit opt-out — a decision on the
record rather than an omission. All four guard paths behaviour-tested.

**Still to do in item 4** (see the CT-3a update below for the full list):
- Push the 5 upstream charts to ECR as OCI artefacts and repoint the `helm_release`
  blocks at `oci://`
- ~~`scripts/supply-chain/` — the mirror itself~~ ✅ built 2026-09-09 (CD-46); workflow at
  the monorepo root since 2026-09-18. **Never yet run** — needs the GitHub-side wiring
  (variables, secrets, OIDC role) and a first `workflow_dispatch --dry-run`.
- ~~`modules/registry`~~ — **deliberately not built** (CD-27): ECR is a central
  shared-services account in the bank, so repositories are requested, not created.
  In the personal environment `mirror.sh --create-repos` creates them.

*(A `dockerconfigjson` pull secret is no longer needed: kubelet's ECR credential
provider authenticates from the node role.)*

- **GAP found 2026-08-30 — the five upstream charts carry their own images, and
  nothing overrides them.** `var.container_images` covers only the 8 images this
  repository names directly. `kube-prometheus-stack` (86.2.3),
  `aws-load-balancer-controller` (3.4.0), `aws-for-fluent-bit` (0.2.0),
  `secrets-store-csi-driver` (1.6.0) and `secrets-store-csi-driver-provider-aws`
  (3.1.1) between them pull a dozen or more images from `quay.io`,
  `registry.k8s.io`, `public.ecr.aws` and `docker.io` — Prometheus, Grafana,
  Alertmanager, kube-state-metrics, node-exporter, the operator, the CSI
  node-driver-registrar and livenessprobe, and each controller's own image.

  In an air-gapped VPC every one of them hangs. Each chart needs its image values
  overridden to the ECR mirror, which is per-chart work — the key differs
  (`image.repository`, `global.imageRegistry`, `prometheus.image`, …).

  Enumerate them authoritatively rather than from memory, per chart:
  `helm template <chart> --version <pinned> --repo <url> | grep -E '^\s*image:'`

  **Not** in scope: the EKS addons (VPC CNI, kube-proxy, CoreDNS, EBS CSI) pull
  from an AWS-managed ECR in-region and reach it through the `ecr.api`/`ecr.dkr`
  endpoints, so they need no mirroring.

**UPDATE 2026-09-04 — the registry is Amazon ECR (CT-3a, DECIDED).**

Full
analysis, obstacles and decisions D-16..D-22 are in
`docs/CLOUD_TEAM_REDESIGN_NOTES.md` §11; the asks that go back to the cloud team are
`docs/NETWORK_REQUIREMENTS_CLOUD_TEAM.md` §8 (requirements #20-#26).

**Nothing above is invalidated.** The registry abstraction built on 2026-08-30 already
covers ECR with no code change — `registry_host` becomes
`<acct>.dkr.ecr.<region>.amazonaws.com`, `registry_ca_cert_pem` becomes empty and
`registry_cert_publicly_trusted = true`. The chart-image gap below is
registry-independent and stands verbatim.

What changes, once D-16 is confirmed:

- **Two still-to-do items disappear.** The `dockerconfigjson` pull secret is unnecessary
  (kubelet's ECR credential provider authenticates from the node role), and the chart
  proxying is replaced by OCI charts pushed to ECR.
- **New: `modules/registry`** — ECR repositories, `for_each` over the image list, tag
  immutability ON, no lifecycle expiry (a validator replaced months later must still find
  its digest), optional CMK.
- **New: `scripts/supply-chain/mirror-images.sh`** — `crane copy` / `skopeo copy --all`
  **only**. `docker pull`/`tag`/`push` re-manifests and **changes the digest**, silently
  invalidating every H38 pin (D-18).
- **Five `helm_release` blocks move to `oci://`** — `rpc-access:75`, `secrets:330`,
  `observability:278`, `observability:344`, `storage-csi:174` — with
  `repository_username`/`repository_password` from `data.aws_ecr_authorization_token`
  (12-hour validity). This is the one place a chart-proxying repository would have
  been less work.
- ✅ **Runner bootstrap rewritten — DONE 2026-09-07 (D-21).** All five internet hosts and
  the GitHub clone are gone. The chain root creates `<prefix>-runner-artifacts`;
  `scripts/runner/push-runner-bundle.sh` resolves the pinned toolchain from
  `scripts/runner/runner-tools.manifest`, verifies each sha256, unpacks on the laptop and
  uploads `tools/tools.tar.gz` + `source/source.tar.gz` (`git archive` HEAD). The runner
  pulls both over the S3 gateway endpoint; its only prerequisites are `aws`, `tar` and
  `gzip`, all in the AL2023 base AMI. **The GitHub PAT and its Secrets Manager secret are
  deleted** — and with them the F28/H18/H39 findings the credential kept generating.
  Verified by rendering the user_data and parsing it: shebang at column 0, `bash -n`
  clean, zero internet hosts. Tool versions resolved from source 2026-09-07 (kubectl
  v1.35.8, helm v3.21.4 — the Helm 3 line, not the v4 major — terraform 1.16.1, Corretto
  17.0.20.10.1). ✅ **Digests recorded 2026-09-10** (`push-runner-bundle.sh --record`), so both the
  bundle build and the CI workflow verify against our own pin rather than a vendor-served
  checksum file. Re-run `--record` only when a pinned version changes.
- **Terraform providers → `.terraformrc` `filesystem_mirror`** from an S3-delivered
  directory (D-20), not a network mirror.
- **`network-contract` gains a gate:** Private DNS enabled on `ecr.api` and `ecr.dkr`.
- ✅ **Prod guard reworded** at `terraform/chain/main.tf` — the error message now names
  the ECR registry, and the CA-cert guard notes that ECR is publicly trusted.

Pull-through cache is **not** an option (D-17): AWS requires an internet route on the
first pull through a PTC rule when ECR is reached via an interface endpoint, which CT-2
forbids. The supply chain is an explicit replication pipeline, and that is a standing
operational commitment, not a one-off setup.

### 5. Second EKS cluster (`app` root) + Phase 3

**Stage 3.0 first: the same-VPC PrivateLink smoke test.** It is a gate, not a
formality — AWS documents neither permit nor forbid a consumer endpoint in the
same VPC as the provider NLB.

### 5a. Event pipeline — NEW BUILD, not a port

`docs/EVENT_LISTENER_DESIGN_NOTES.md` (E-1..E-20). Nothing in `besu-aws`
corresponds to this; the Stage-8 listener was a throwaway single pod.

Components: `chain-tailer` (durable cursor in DynamoDB) → SNS FIFO → SQS FIFO
queues + poller consumers → archiver pod → S3 Parquet. **No Lambda, no Firehose
(E-15).** Runs in the **application** cluster (E-14).

Contract impact already folded in: `sqs` added to the endpoint list (`sns` was
already there for Alertmanager, so the pipeline costs **one** new endpoint, not
two). IRSA: one role **per queue**, not one shared role. CMK on the topic, every
queue, and the archive bucket.

### 6. Isolation model (§6)

NetworkPolicy default-deny **mandatory** (ships opt-in as H6 upstream) · validator
node group + taints · namespaces + ResourceQuota · per-tier SGs · NACL rules on
the ledger subnets (`var.ledger_nacl_ids`) · subnet-level flow logs (#14).

### 6a. Inherited docs describing the pre-split layout — ✅ RESOLVED 2026-08-30

Resolved by **deletion, not rewriting** (human decision): `besu-aws` is the frozen
reference repo and holds every one of them, so keeping a second, wrong copy here
bought nothing and risked being read and believed.

Removed: `manual-deployment-guide.md`, `docs/explained/*`,
`architecture-for-beginners.md`, `claude-code-setup.md`, `cost-estimate.md`,
`stage-8-design-notes.md`, `PRODUCTION-DEPLOYMENT.md`,
`PRODUCTION_HARDENING_INSTRUCTIONS.md`, `CHANGELOG.md`, the architecture diagram,
and every deploy-run / test-run / pentest log.

Kept, because they still govern live code: the H-series and C-series backlogs, the
hardening validation plan, the C12 key-custody analysis, and the Blockscout notes.

The root `README.md` was **rewritten** rather than deleted — a repository needs a
front door — and `docs/test-run-log.md` was **recreated empty** for this project's
own runs, since the cost guardrail depends on it and nothing here has been applied.

`CLAUDE.md` now carries a standing rule: any `docs/…` path that does not resolve
here documents the pre-redesign build and lives in `../../besu-aws`. That is one
durable rule instead of rewriting several dozen inherited code comments.

### 7. Teardown (§9)

`full-delete.sh`: drop the NAT/EIP sweep; add a **resource-type denylist that
ABORTS** on `vpc`/`subnet`/`route-table`/`internet-gateway`/`transit-gateway*`
(a tag collision in a shared VPC means deleting the cloud team's network); add a
leaked-ENI sweep.

### 8. Cost guardrail

Two-cluster burn ≈ **USD 2.40/hour** in af-south-1 (2026-09-04; was ~$1.85 in
us-east-1), so the inherited USD 15 cap
buys ~8 hours. **Needs human sign-off** before raising to USD 25.

---

## Gate proven — 2026-08-30

The recommended first step (prove the gate before building anything) is **done**:

1. ✅ `mimic_vpc` applied in us-east-1 — `vpc-083910a0dc47618aa`, 65 resources
2. ✅ `verify-contract.sh` — **27/27** live-AWS assertions
3. ✅ `emit-handover.sh` → `network-handover.auto.tfvars` consumed here
4. ✅ Platform root plans clean, **all 8 gates passing** against the live VPC
5. ✅ **Negative test passed** — dropping `kubernetes.io/role/internal-elb` from
   `subnet-01a884a80ecaa2ac3` aborted the plan citing #4; tag restored

Step 5 mattered more than it looks. Four gate bugs surfaced during construction
and **two of them passed silently** — a gate observed only passing is not yet
known to work. This was the first observed *failure*, and it failed closed with
the intended message.

The mimic stays up through Phase D (~$0/mo — flow logs only).

---

## Next: the port

Work `Remaining` above in order. The four-root split comes first because every
later item lands in one of the roots it creates.

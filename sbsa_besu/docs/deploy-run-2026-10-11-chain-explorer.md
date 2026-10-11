# Deploy run — 2026-10-11 (Octopus) — the chain itself: a transaction, seen in Blockscout

> **Live log, written as the run goes.** Times UTC. **Who ran what:** *operator* = in GitHub,
> the Octopus UI, an SSM shell, or a `terraform apply`; *Claude* = code, read-only API/AWS
> calls and plans from the laptop. Secrets are read into variables and unset; never printed.

**Source under test:** `shared-eks-namespace` @ `f8ad533`.

**What it must show:**
1. The chain root's **in-cluster layer** — never applied in this repository before — deploys
   from Octopus (`besu-workloads`, on the runner's Tentacle), air-gapped: every chart and
   image from the ECR mirror, every provider from the bundle's mirror.
2. A chain: 4 validators producing blocks, Ready on 4 distinct nodes (`verify-deployed.sh`).
3. A transaction from the operator's funded account (`0x9f7e…b248`, genesis-funded, F20),
   visible in Blockscout through the runner.

**Outcome:** *(in progress)*

---

## 0. Before anything billable (≈ 10:30 → 11:55, Claude, local and free)

Yesterday's sequence could not produce a chain: `besu-workloads` was smoke-only, and the
in-cluster apply had two hangs waiting in it. Found and fixed before spending anything —
`docs/build-findings.md` B13, B44–B48; RUNBOOK E.4:

- The five upstream charts came from `https://…github.io` (PORTING item 4) → OCI from ECR,
  every chart image overridden (`var.chart_images`).
- Rendering the mirrored charts with Terraform's exact overrides (evaluated in a scratch root)
  and checking every image against ECR found **B44** (`prometheus-config-reloader` never
  mirrored) and **B45** (node-exporter `…-distroless-distroless`).
- **B46**: D-20 was never built — `terraform init` on the runner would have hung. Provider
  mirror now in the bundle; offline init from it tested (5 providers, 194 MB).
- **B47/B48**: namespace disagreements (Octopus `besu-ledger` vs chain `besu`; IRSA literal).
- New step `octopus/steps/workloads-incluster.sh`, with a CD-5 plan gate.

Deploy config (gitignored): SIT `chain.tfvars` gains the registry settings and
`genesis_funded_accounts`; deletion groups bumped to `sbsa-sit-2026-10-11`,
`sbsa-net-sit-2026-10-11`, `sbsa-egress-sit-2026-10-11`.

Committed `f8ad533`; **operator pushed ≈ 11:57**.

## 1. Run steps

| Time | Step | Who | Result |
|---|---|---|---|
| 11:57 | 0 — push `f8ad533` | operator | ✅ `shared-eks-namespace` = `origin` |
| 12:00 | 3 — `octopus/terraform` plan (SIT) | Claude | ✅ **1 add, 3 change, 0 destroy**: + step `terraform: chain in-cluster`; ~ workloads steps order; ~ project description; ~ `Besu.LedgerNamespace` `besu-ledger` → `besu` (B47). Nothing else |
| 12:01 → done | 1 — `supply-chain.yml` dispatch, `images-only`, `create_repos` (run 38137676458) | operator | ✅ success on `f8ad533`. ECR: `mirror/prometheus-operator/prometheus-config-reloader:v0.91.0` = `sha256:7d9e4eea…d8c1`, the manifest's pin, by digest (B44 closed in the registry) |
| 12:03:41 | 2 — `push-deploy-config.sh` | operator | ✅ new version `AWSCURRENT` 12:03:41: registry settings, `genesis_funded_accounts = [0x9f7e…b248]`, DG `sbsa-sit-2026-10-11`. (Claude's first read, ~12:02, preceded the push and wrongly reported it missing.) The network hand-over inside is still **yesterday's** (`vpc-08e7261…`, deleted) — **re-push after step 4's `emit-handover.sh`** |
| 12:06 | 3 — `octopus/terraform` apply | operator | ✅ 1 added, 3 changed. Claude, via the API: `besu-workloads` (`Projects-43`) = 1 smoke → 2 `terraform: chain in-cluster`, both on `Besu.RunnerPool`, scripts as committed; `Besu.LedgerNamespace` = `besu` |
| 12:09 | 4a — `mimic_vpc` plan (`flows`, DG `sbsa-net-sit-2026-10-11`) | Claude | ✅ **347 add**, 0 change/destroy: 273 NACL rules, 15 subnets/RTs/NACLs, 2 gateway endpoints, **1 subnet CIDR reservation** (B43, now owned by the mimic — no hand-made `scr-` today). +2 vs 10-10's 345 |
| ~12:15 | 4a — `mimic_vpc` apply | operator | ✅ `vpc-02f11b8fc3c3f6ad8` (10.60.0.0/20), 350 state entries. Runner /32 reserved by the mimic: `10.60.0.250/32` explicit, `scr-03184ac90d138690d` in `subnet-0bf473cf8c5fd8123` (B43) |
| ~12:16 | 4b — `mimic_egress` plan (DG `sbsa-egress-sit-2026-10-11`) | Claude | ✅ **29 add**, 0 change/destroy — same 29 as 10-10: proxy VPC + IGW, Squid instance, NLB, peering, PHZ record |
| 12:16 → 12:17 | 4b — `mimic_egress` apply | operator | ❌ **22 of 29 created**; `CreateVpcPeeringConnection` → `InvalidVpcID.NotFound vpc-08e7261…` and the PHZ association → 401 on the same ID. **Cause — Claude's sequencing:** the egress plan was made before the network hand-over existed for today, and `mimic_egress/terraform/` keeps its **own copy** of `network-handover.auto.tfvars` (README: `cp ../mimic_vpc/…`), which still held 10-10's VPC. Claude's command list omitted that `cp`. Correct order: VPC apply → VPC `emit-handover` → `cp` → egress plan |
| 12:18 | 4c — both `emit-handover.sh`; 2 — `push-deploy-config.sh` (2nd) | operator | ✅ network hand-over `vpc-02f11b8fc3c3f6ad8`; egress `proxy.egress.mimic.internal`, source `10.60.0.250/32`; bundle pushed 12:18:44 |
| 12:21 | 4b′ — `cp` today's hand-over into `mimic_egress/terraform/`, re-plan | Claude | ✅ **7 add** = exactly what failed: peering + options, 4 routes, PHZ association — all to `vpc-02f11b8…`. Nothing to change or clean up |
| 12:22 | 4b′ — `mimic_egress` apply (7) + egress `emit-handover.sh` | operator | ✅ `pcx-023cb77542939fa7c` **active** (`vpc-02568da7…` ↔ `vpc-02f11b8…`), proxy `i-0666e931c2f15f78f`. Re-emitted hand-over differs from the pushed one **only in its timestamp comment**; network hand-over identical → no re-push needed |
| 12:25 | 5 — `release` → `besu-infra` (run 38139179529) | operator | `check` job ✅ in CI on `f8ad533`: fmt, validate, helm lint, **shellcheck** (new scripts within the 22-warning baseline), **manifest ↔ Terraform drift incl. the 16 chart images**. Release `2026.10.11.9` assembled 12:26:17 → `ServerTasks-1533` |
| 12:26 → 12:49:40 | 5 — `ServerTasks-1533` (besu-infra 2026.10.11.9) | Octopus (hosted worker) | ✅ **all four steps, first time**: `shared` 12:26:26–12:29:06; `chain` 12:29:06–12:45:20 (cluster `sbsa-besu-primary-eks`); **runner bundle 12:45:20–12:48:30** (now incl. the provider mirror, +≈2 min); `runner` 12:48:30–12:49:40. GitHub run green incl. "The deployment must have succeeded" |
| 12:52 | runner check over SSM (read-only `send-command`) | Claude | ✅ `i-01b651d7d9d7077f1` on **pinned `10.60.0.250` — no B43 clash** (the mimic's reservation held). `BOOTSTRAP_STATUS: OK: tools=5 source=f8ad533/2026.10.11.9 deploy-config: extracted`. **B46 live:** `/usr/local/besu-tools/terraformrc` (filesystem mirror only) + 5 provider zips (aws 5.100.0, helm 2.17.0, kubernetes 2.38.0, tls 4.3.0, random 3.9.0); profile exports `TF_CLI_CONFIG_FILE`; terraform 1.16.1 = pin; `jq`, `python3` present |
| 12:54:49 | 6 — `install-tentacle.sh` (1st) | operator | ❌ **refused, correctly**: probes 1–6 PASS; probe 7 compared the cert through the proxy with the literal text `<same value as yesterday>` — a placeholder in Claude's command, pasted as given. The gate did its job: no registration on an unproven tunnel |
| 12:56 | baseline measured from the laptop, direct (`openssl s_client … polling.<instance>.octopus.app`) | Claude | `9B:A5:3F:3C:…:BC:54:F3:78` (CN Octopus Portal) — **identical** to what the runner saw through the proxy → no interception. Re-run with it |
| ~12:58 | 6 — `install-tentacle.sh` (2nd, real baseline) | operator | ✅ **7/7 probes**, registered. Same hostname `ip-10-60-0-250` and thumbprint `55A0F453…` (CD-61: cert from its secret) → existing `Workers-1` updated in place, pool `besu-runner-sit` (`WorkerPools-43`) |
| 13:00 | health check `ServerTasks-1534` | Claude | ✅ `Workers-1` **Healthy** (was Unavailable from 10-10; "old version of Tentacle (11.0.4398)" = the manifest pin, warning only) |
| 13:00 → 13:03:18 | 7 — `release` → `besu-workloads` (run 38141303688, `ServerTasks-1535`, 2026.10.11.10) | Octopus (runner Tentacle) | Step 1 smoke ✅ (nodes, #38 canary, C-2). Step 2 ❌ at `terraform init`: `retrieving caller identity from STS … Post "https://sts.us-east-1.amazonaws.com/": dial tcp …:443: i/o timeout` after 3 min. **B49:** the state bucket `besu-tfstate-867728055761` is in **us-east-1** (`Besu.StateRegion = us-east-1`); the runner is air-gapped in af-south-1, whose S3 gateway endpoint serves same-region buckets only and whose STS endpoint is af-south-1's. **First Terraform ever run inside the VPC**, so first exposure. Also a residency defect: af-south-1 ledger key material in US-region state. Nothing was created; the stack is intact |
| 13:16 | B49 fix — new bucket `besu-tfstate-867728055761-afs1` + copy `besu/sit/{shared,chain,runner}.tfstate` | operator (laptop) | ✅ Claude verified: `af-south-1`, versioning Enabled, AES256, public access blocked ×4; all three objects **identical** to the us-east-1 originals (size + MD5 ETag: shared 134210 `cfa4d916…`, chain 445217 `1727e834…`, runner 76937 `b449a29a…`) |
| 13:18–13:22 | B49 — originals parked (`MOVED-2026-10-11/besu/sit/…`, us-east-1), push `dbb169a`, Octopus apply (2 variables) | operator | ✅ verified: `besu/sit/{shared,chain,runner}` gone from the old bucket's live keys; `Besu.StateBucket = …-afs1`, `Besu.StateRegion = af-south-1` |
| 13:20 → 13:27:44 | 5′ — `release` → `besu-infra` again (run 38142724561, `dbb169a`, `ServerTasks-1536`, 2026.10.11.11) | operator | ✅ `shared` **No changes**; `chain` **No changes** — the copied state in the af-south-1 bucket matches the live stack exactly; `runner` **1 in-place**: `aws_iam_policy.runner_deploy[0]` (S3 scope → the new bucket). No instance change: the Tentacle stays registered |
| 13:30 → 13:54 | 7′ — `release` → `besu-workloads` again (run 38143517044, `ServerTasks-1537`, 2026.10.11.12) | operator / Claude | Smoke ✅. In-cluster: `init` ✅ against the af-south-1 bucket (**B49 proven from inside the VPC**); **F19 ✅** RPC server keystore issued for `rpc.yournet.internal` 13:33:48; then **hung in plan refresh** from 13:33:58. Runner (`ss`, read-only SSM): AWS provider `SYN-SENT` to `13.247.131.166:443` = the runner's own resolution of `resource-groups.af-south-1`; `cloudtrail`, `iam` also public-only, every other service the root uses on 10.60.11.x. **B50.** Claude cancelled the task 13:54 (Canceled; nothing created). Stale plan lock `chain.tfstate.tflock` (ID `7765ea56…`, `tentacle@ip-10-60-0-250`), no surviving process |
| 13:55 → 14:05 | B50 fix | Claude | runner plans `-refresh=false` + CD-53 gate (only `helm_release`/`kubernetes_*` may change); `modules/eks` drops the public-HTTPS `tls_certificate` data source — **laptop plan of live SIT: `No changes`**. Gates tested both ways on synthetic plans |

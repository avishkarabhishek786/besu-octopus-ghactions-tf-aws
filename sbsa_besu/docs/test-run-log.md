# Deploy-test run log

One row per apply/destroy cycle, so elapsed billable time and the running total
against the cost cap stay visible. **Append a row for every cycle** — this is the
cost guardrail's evidence, not a formality.

The inherited `besu-aws` log covered a different architecture and was not carried
over; it is in the frozen reference repo. **This log starts empty because nothing
of this platform has been applied yet.**

## Standing rules

- **Same-day teardown is mandatory.** Nothing is left running overnight.
- Run `terraform plan` before every `apply` and surface resource counts and
  expensive items first.
- Teardown order is the reverse of apply: `app` → `chain` → `runner` → `shared`.
- After teardown, sweep orphaned EBS by `DeletionGroup` tag, then zero-check.
- `deletion_group` must be **unique per deployment** — `full-delete.sh` targets
  exactly that value.

## What bills, and how fast

> **CT-5, 2026-09-21.** The lines below are the *own-cluster* cost model, and the runs
> recorded further down were billed under it. In production the EKS control plane, the
> worker nodes and the interface endpoints move to the cloud team's bill; what remains
> ours is KMS, Secrets Manager, NLBs, the runner, CloudWatch and S3. **Deploy-tests are
> unchanged in kind** — `mimic_eks` still bills a cluster and nodes, slightly less than
> two did. Re-cost on the first post-CT-5 run; see `CLOUD_TEAM_REDESIGN_NOTES.md` §12.9.


| Resource | Rate (af-south-1) | Note |
|---|---|---|
| Interface endpoints | **~$0.45/hr** | 15 services × 3 AZ; the `shared` root's whole cost |
| EKS control plane | ~$0.10/hr | per cluster — two clusters once the app root exists |
| Worker nodes | dominant | sized by the node group |
| NLBs, EBS | small but non-zero | EBS survives a careless teardown |
| VPC (the mimic) | ~$0 | flow logs only; no NAT, no IGW |

Two-cluster burn is roughly **USD 2.40/hour** in af-south-1 (~31% above the us-east-1
figure of $1.85 these rates were first sized against — re-cost them on the first real
run). The inherited cap is **USD 15/run**, now ~6 hours rather than 8;
raising it to USD 25 for two clusters **needs explicit human sign-off** and is
tracked as item 8 in `PORTING.md`.

> The `shared` root alone is ~$11/day. It is the one root whose cost accrues with
> nothing running on it, so it should be the last thing applied and the first
> thing torn down if a test stalls.

## Runs

| Date / window | Action | Roots | What was up | Est. spend | Outcome |
|---|---|---|---|---|---|
| 2026-08-30 → 2026-09-04 | apply → destroy | `mimic_vpc` (us-east-1) | VPC + 15 subnets + 15 route tables + 9 NACLs + 2 gateway endpoints + flow log — **65 resources, no NAT/IGW/EKS** | **~$0** (flow logs only; 1-day retention) | ✅ **65 destroyed, zero-check clean.** Torn down to migrate the region to af-south-1 — a provider-region change would have orphaned them. Tag API still listed 3 already-deleted ARNs afterwards (**B16**). |
| 2026-09-14 14:4x → 15:4x UTC | apply → destroy | `mimic_vpc` (af-south-1, sit) | 65 resources, no NAT/IGW/EKS | ~$0 (flow logs, 1-day) | ✅ **65 destroyed, direct-describe zero-check clean** (only the account-default VPC's IGW remains — not ours). verify-contract 27/27. First `emit-handover.sh` run left a **0-byte** file + stale us-east-1 hand-over in the platform (**B19**, fixed same day: atomic render). **Mock for the R-9 Tentacle path (RUNBOOK E.1).** |
| 2026-09-14 15:10 → 15:4x UTC | apply → destroy | `mimic_egress` (af-south-1, sit) — **first ever run** | egress VPC + IGW + Squid 6.13 `t3.micro` + internal NLB + PHZ + peering `pcx-0fa9b8aa26515d73f` + 3 ledger routes — 29 resources | **≈ $0.6/day** (NLB $0.0225/h + t3.micro $0.0104/h + PHZ) | ✅ plan matched the checklist (3 ledger routes, single 0/0 in the egress VPC only); Squid bootstrapped (`squid -k parse` OK), NLB target healthy; from a non-allowed source every request `TCP_DENIED/403`. Found **B20** — probes read `%{http_code}` (000 on a refused CONNECT) instead of `%{http_connect}`; fixed + re-verified live. **29 destroyed, zero-check clean** (VPC/ENI/NLB/peering/PHZ/log group/EBS all empty). ≈ **$0.05** total for the day. **Stopped by the operator before `shared`/`chain`; the two `sbsa-besu-primary-*` secrets are KEPT (~$0.03/day) so the Octopus key need not be re-issued. RESUME at RUNBOOK E.1 step 1** (re-apply both mimics — IDs change, hand-overs regenerate), then `shared` → `chain` (4-node override) → `runner` → 8 probes → `install-tentacle.sh`. |
| 2026-09-17 14:3x → 17:18 UTC | apply → destroy | `mimic_vpc` (af-south-1, sit, DG `sbsa-net-sit-2026-09-17`) | 65 resources, `vpc-0aa3d48cec8421f9e` | ~$0 | ✅ verify-contract 27/27; hand-over 3363 B. **R-9 mock, RUNBOOK E.1 — full run** (`docs/deploy-run-2026-09-17-r9-mock.md`). |
| 2026-09-17 14:5x → 17:17 UTC | apply → destroy | `mimic_egress` (DG `sbsa-egress-sit-2026-09-17`) | 29 resources; `pcx-053085dc71c5f6bba`, proxy `i-0b95c6e5f185c0613` | ≈ $0.6/day | ✅ plan = checklist; NLB target healthy; hand-over 1440 B. **B23** found live (probe 8 hairpinned through the NLB from a target — now direct to Squid); after the fix **8/8 probes** incl. no-interception (CD-58). |
| 2026-09-17 15:09 → 17:13 UTC | apply → destroy | `sbsa_besu/shared` (**first ever platform apply in af-south-1**; key moved to `besu/sit/shared.tfstate`) | 27 resources — 15 interface endpoints (45 ENIs), SG, PHZ `chain.internal`; gateways correctly absent | **≈ $0.45/h** | ✅ after two pre-plan fixes (gitignored `common.tfvars` said `environment = "dev"` → `sit`; state keys gained the `<env>` segment) and **B21** (NAT gate `coalesce("","")` crashed on the first non-local route). |
| 2026-09-17 ~15:35 → 17:06 UTC | apply → destroy | `sbsa_besu/chain` AWS layer (4-node override, KMS 7 d, secret recovery 0) | 106 resources — private EKS 1.35 `sbsa-besu-primary-eks`, 4 × m6i.xlarge, 2 CMKs, 23 secrets, RPC NLB shell, CloudTrail, 2 buckets | **≈ $1.1–1.4/h** | ✅ plan reviewed by type (no NAT/IGW/helm/k8s; only deletion-protection flag = `false`; H5 boundary on 9 roles). `name_prefix = sbsa-besu-primary`, endpoint `ACTIVE False True`. All 4 nodes later **Ready** (CNI pulled via ECR endpoints — #20/#23 clear). |
| 2026-09-17 15:52 → 16:57 UTC | apply → destroy | `sbsa_besu/runner` (**first ever init**, `besu/sit/runner.tfstate`) | 11 resources — `i-02afc47d1256be9c0` @ pinned `10.60.0.250`, EKS access entry, boundaried deploy policy | ≈ $0.03/h | ✅ bootstrap `tools=5 source=b9e5b66 deploy-config: extracted` (D-21 in af-south-1). **B22** (deploy-config bundle listed a non-existent `primary.tfvars`) fixed before the push. **B24** (`/etc/octopus` index; config-file ≠ instance) fixed across 3 installer attempts. Octopus: service account `besu-register` needed a team + **Environment manager scoped to Default** (SAVE the team!) — then `register-worker` OK via Squid, thumbprint `55A0F453…6B8F` stored (CD-61), worker **Healthy**, Script Console `kubectl get nodes` = 4 Ready, **stop/start kept identity**. E.1 steps 1–10 **PASSED**. **Teardown 16:57→17:18, all five roots destroyed (11/106/27/29/65), direct-describe zero-check CLEAN 17:20** (only the 2 kept secrets + 2 CMKs PendingDeletion 7 d remain). ≈ **$3.0 for the day** at ≈ $1.9/h while up. |
| 2026-10-09 09:53 → 12:11 UTC | apply → destroy | `mimic_vpc` (DG `sbsa-net-sit-2026-10-09`, key **moved** to `besu/sit/network.tfstate`) | 321 resources (D-32 restrictive NACLs, first live); switched to `nacl_mode=permissive` 11:10 | ~$0 | ✅ verify-contract 27/27. **B27**: restrictive NACLs omit the cluster's own flows. Run log: `docs/deploy-run-2026-10-09-ct5-gates-and-regression.md` |
| 2026-10-09 10:01 → 12:06 UTC | apply → destroy | `sbsa_besu/shared` | 27 resources, 45 ENIs | ≈ $0.94 | ✅ |
| 2026-10-09 10:05 → 11:37 UTC | apply → destroy ×3 | `mimic_eks` — **first ever** (local state, DG `mimic-eks-sit-2026-10-09`) | us-east-1 strays (13, **B25**); hostile 1.37, 3 nodes (2 joined, B27); strict 1.36, 8 nodes | ≈ $1.8 | ✅ all 12 cluster-contract gates driven to failure; **B28, B29, B31, P-1** found and fixed; B30 open |
| 2026-10-09 10:13 → 12:09 UTC | apply → destroy | `mimic_egress` (key moved to `besu/sit/egress.tfstate`) | 29 resources | ≈ $0.06 | ✅ 8/8 probes |
| 2026-10-09 11:32 → 12:00 UTC | apply → destroy | `sbsa_besu/chain` AWS layer (4-node override) | 106 resources | ≈ $0.60 | ✅ regression vs 09-17 |
| 2026-10-09 11:49 → 11:54 UTC | apply → destroy | `sbsa_besu/runner` | 11 resources, `i-0c2f73922bd85d754` | ≈ $0.01 | ✅ bootstrap `tools=5 source=7b9b41d`; `kubectl get nodes` 4 Ready from the runner. **Day total ≈ $3.4; zero-check CLEAN 12:12** |
| 2026-10-10 07:18 → 08:11 UTC | apply → destroy | `mimic_vpc` on **`nacl_mode=flows`** (DG `sbsa-net-sit-2026-10-10`) | 333 resources (261 NACL rules incl. C-1..C-4); C-1 broken and restored twice | ~$0 | ✅ verify-contract 27/27; checker live **46/0/12/4** = offline prediction, break → exactly C-1 ×6 + F-7 ×3. Destroy blocked 10 min by **B34**. Run log: `docs/deploy-run-2026-10-10-b27-live.md` |
| 2026-10-10 07:26 → 07:59 UTC | apply → destroy | `sbsa_besu/shared` (DG `sbsa-sit-2026-10-10`) | 27 resources, 45 ENIs | ≈ $0.25 | ✅ |
| 2026-10-10 07:29 → 07:54 UTC | apply → destroy | `mimic_eks` hostile (DG `mimic-eks-sit-2026-10-10`) | 1.37, 3 × m6i.xlarge in the app subnets; control-plane ENIs az1+az2 only | ≈ $0.25 | ✅ **B27 closed live**: 3/3 nodes joined (az3 across a NACL); C-3 live; C-1 removed → only the az3 node NotReady, restored → Ready. **B34** found (leaked CNI ENI + cluster SG). **Day total ≈ $0.5; zero-check CLEAN 08:13** |
| 2026-10-10 08:33 → 09:20 UTC | apply (long-lived) + 4 CI runs | `mimic_registry` (push role, `besu/sit/registry.tfstate`) + `supply-chain.yml` on GitHub-hosted runners | 1 IAM role + policy (applied by the operator — the permission layer refused it for Claude); 28 ECR repositories, 23 images, 5 charts | ≈ $1/month ECR storage; CI free | ✅ first CI mirror. Runs: 38039325083 (assume refused: ID-suffixed `sub`), 38039952570 (dry run died on missing repos — fixed), 38040147028 (dry run green), **38040455269 (mirror green, 9m28s)**. Not torn down: the registry has no expiry by design |
| 2026-10-10 09:37 → 10:13 UTC | apply → destroy | `mimic_vpc` (flows) + `shared` + `mimic_eks` **strict** (`node_count=3`, public endpoint) — DGs `…-2026-10-10b` | 333 + 27 + 22 resources; 6 nodes in the ledger subnets | ≈ $0.6 | ✅ **#38 pull canary PASS** (alpine/k8s, besu — by digest, as the node role); **C-2 live** (UDP+TCP 20/20; cut → UDP 0/20); **B35, B36** found and fixed; B34 sweep clean. Zero-check CLEAN 10:13. Run log: `docs/deploy-run-2026-10-10-pull-canary-c2.md` |

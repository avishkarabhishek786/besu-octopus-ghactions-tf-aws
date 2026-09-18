# Production-hardening backlog (H1–H39)

> **Purpose.** A prioritized, ready-to-execute task list from a full-codebase security /
> robustness / upgrade-safety audit of branch **`feature/c6-c12-combined`** (2026-07-06).
> It complements the app-deployment backlog (`app-deployment-backlog.md`, C1–C12): the
> C-series got the chain + app running on prod; **this H-series is what stands between
> "it runs" and "it is safe to run as production financial infrastructure."**
>
> **Method.** Five parallel audits (Terraform AWS-layer, Helm/blockchain layer, bash
> scripts, app/RPC/mTLS plane, and a dedicated cross-cutting upgrade/update fail-safety
> pass), each evaluating the 7 themes the human asked for:
> (1) vulnerabilities/bugs, (2) pentest surface, (3) **fail-proof cluster + blockchain
> upgrade/update**, (4) data-corruption / infra-breakdown risk, (5) production robustness,
> (6) general improvements, (7) input/invalid-parameter handling.
>
> **Standing rules still apply:** [[prod-testing-practice]] ($15/run, same-day teardown,
> prod-only), [[deployment-advise-only-mode]] (advise; the human runs deploys), and
> [[no-hardcoding-rule]].
>
> **Status (updated 2026-07-11):** **P0 (H1–H4), P1 (H5–H12) and P2 (H13–H27) are IMPLEMENTED** on
> branch `feature/production-hardening`, plus the 2026-07-06 whitebox-pentest remediation. A chain-only
> mock on **2026-07-11 LIVE-CONFIRMED H1/H2/H3/H5/H6/H7/H10/H12/H13/H14/H19/H21/H26 + the C10 startup
> gate** (FULL PASS, `docs/prod-deploy-run-2026-07-11-hardening.md`); the app-layer + no-CMK + rolling
> items (H4/H8/H9-pin/H15/H16/H17/H18/H20/H22/H23/H24/H25/H27) remain statically-validated / deferred —
> see the **Implementation status** section and the per-item notes. **Only P3 (H28–H39) remains a task
> list.**
>
> **2026-08-10:** the **H5 residual** — until now the standing "#1 go-live task" — is **closed in code**
> (IAM permissions boundary on every stack role + a rewritten, resource-scoped, escalation-proof runner
> deploy policy). Statically validated; apply-validation on the next mock is the open item.

## Verification status

Items marked **✅VERIFIED** were confirmed against source in the audit session (file+line
re-read). Items marked **⚠️TRIAGE** carry the auditing agent's confidence and should be
re-confirmed at implementation time. All findings are file-anchored.

The four P0 items and H6/H8 were personally verified:
- **H1/H2** — validator releases restart in bulk on a routine apply, and the genesis
  release/Job re-runs on a `besu_version` bump (`terraform/modules/besu/main.tf:73` couples
  `images.besu` into genesis; `helm/charts/besu-genesis/templates/job.yaml` has **no**
  `helm.sh/hook`, only `ttlSecondsAfterFinished: 3600`; `local.peers` at
  `terraform/modules/besu/main.tf:41-42,151` injects app/explorer pools into every validator).
- **H3** — the account-allowlist ConfigMap is mounted **only** on the `build-config` init
  container (`helm/charts/besu-node/templates/statefulset.yaml:197`), copied once to
  `/data`; the main besu container does not mount it (`:365-369`), so a hot reload reads a
  frozen file.
- **H6** — `grep -rln 'kind: NetworkPolicy' helm/` returns **0 files**.
- **H8** — `terraform/environments/prod/primary.tfvars:73` sets
  `account_permissioning_mode = "local"` (deny-by-default active).

## Implementation status

| Tier | Items | State |
|------|-------|-------|
| **P0** | H1, H2, H3, H4 | ✅ IMPLEMENTED 2026-07-06 → **H1/H2/H3 LIVE-CONFIRMED 2026-07-11**; H4 (app tx-API) deferred with the app layer (chain-only run) |
| **P1** | H5–H12 | ✅ IMPLEMENTED 2026-07-06 → **H5/H6/H7/H10/H12 LIVE-CONFIRMED 2026-07-11**; H8/H9-pin deferred (app / known-clients), H11 n/a on a fresh 26.x deploy. **H5 residual closed in code 2026-08-10** (permissions boundary + rewritten scoped policy) — statically validated, apply-validation pending |
| **P2** | H13–H27 | ✅ IMPLEMENTED 2026-07-06 — 14/15 (H27 DEFERRED; H17 partial) → **H13/H14/H19/H21/H26 LIVE-CONFIRMED 2026-07-11**; H15/H16/H18/H20/H22/H23/H24/H25 still statically-validated/deferred (app-layer + no-CMK + rolling not exercised this run) |
| P3 | H28–H39 | ⬜ Not started (task list) |
| **Pentest** | H1–H27 whitebox red-team | ✅ **DONE 2026-07-06** + **remediation LIVE-CONFIRMED 2026-07-11** (H3/H5-deny/H6/H6-jwt/H21/H26 attacked and held); log `docs/hardening-pentest-run-2026-07-06.md`, mock `docs/prod-deploy-run-2026-07-11-hardening.md` |

> **Live confirmation (2026-07-11 chain-only mock, branch `feature/production-hardening`, FULL PASS,
> `docs/prod-deploy-run-2026-07-11-hardening.md`).** LIVE-CONFIRMED: **H1, H2, H3, H5, H6, H7, H10, H12,
> H13, H14, H19, H21, H26** (+ the C10/F27 startup gate held on fresh genesis). Deferred / not exercised
> this run (remain statically-validated): **H4, H8, H9-pin, H15, H16, H17, H18, H20, H22, H23, H24, H25,
> H27** — app-layer items need `enable_app_rpc=true`; H16 skipped (H1 covers the structural guarantee);
> H20 skipped (no `data_cmk_arn`).
>
> **UPDATE 2026-08-10 — the H5 residual (the "#1 go-live task") is CLOSED IN CODE.** A permissions
> boundary now caps every stack-created role (`terraform/iam-boundary.tf`, threaded into 10 roles
> across 6 modules) and the runner's deploy policy was rewritten around it: explicit service
> allowlist, resource-scoped Secrets Manager/KMS/S3/IAM, and denies that make
> `iam:CreateRole`/`PutRolePermissionsBoundary` impossible without exactly that boundary. Statically
> validated + rendered-JSON reviewed; **apply-validation on the next mock is the open item** (harness
> checks `H5-boundary` + `H5-escalate` were added for it). See the H5 entry below.

**Whitebox pentest remediation (2026-07-06).** A 3-agent adversarial audit of the landed P0/P1/P2
found 10 controls PARTIAL/BYPASSABLE/BROKEN (rest HOLD). Follow-up fixes applied same session
(branch `feature/production-hardening`, static-validated: `terraform validate` 3 roots + `helm
template` + `bash -n` + `node --check` all clean; **the H3/H5-deny/H6/H6-jwt/H21/H26 remediations were
mock-deployed + attacked and HELD on 2026-07-11**; the H16/H17/H18/H22/H23 remediations remain
statically-validated — not exercised this chain-only run):
- **9 fully fixed:** H22 (fail-CLOSED insecure-TLS guard), H12(d) (CIDR `>= /8` + well-formedness,
  was exact-string), H14 (init containers no longer unbounded root — `wait-peer-dns` fully non-root,
  `build-config` root+CAP_CHOWN-only), H23 (CORS default `none` + host-allowlist a settable value,
  was hardcoded `*`), H6 (Terraform precondition binds `network_policy.enabled ⇒ enable_network_policy`
  and gates `ops_rpc_allow_no_jwt`), H3 (validator under-count fail-open closed via
  `require_full_validator_set` name-pattern cross-check), H18 (PAT off git argv via GIT_ASKPASS +
  credential-free clone URL/log), H16 (resume-skip requires Ready, not just target image), H17
  (guaranteed sm_put temp-file cleanup).
- **H5 — was partial, now FULLY REMEDIATED IN CODE (2026-08-10).** The 2026-07-06 pass only added a
  `Deny` on attaching AWS-managed admin policies + an honest header warning, leaving the policy
  PowerUser-EQUIVALENT and escalatable (CreateRole+PutRolePolicy+PassRole `*`). The follow-up shipped
  what that entry called the **#1 go-live task**: a permissions BOUNDARY on every stack role plus
  scoped PassRole/secretsmanager/kms and boundary-enforcing denies. Still needs apply-validation.
- **Not changed by directive:** H19 Object-Lock / deny-delete and H13 deletion-protection are
  EXCLUDED — the operator directive (2026-07-06) forbids any property that blocks immediate teardown.

**P2 per-item (all `feature/production-hardening`; live-confirmed 2026-07-11 = H13/H14/H19/H21/H26, rest statically validated):**
- **H13** — NLB `enable_deletion_protection` var (prod true). `prevent_destroy` on the CMK/secrets/CloudTrail
  bucket CANNOT be variable-gated (Terraform literal) → documented as a go-live add; KMS deletion window +
  secrets recovery window + H19 `force_destroy=false` are the gateable protections.
- **H14** — pod `seccompProfile: RuntimeDefault` + besu-container `securityContext` (runAsNonRoot 1000, drop
  ALL caps, no-priv-esc, seccomp). NOT `readOnlyRootFilesystem` (Besu writes scratch); build-config init
  stays root (needs chown).
- **H15** — RPC-role pods (rpc/app-rpc/explorer/ops-validator) readiness now on the RPC port (not just P2P) so
  the NLB/PrivateLink doesn't route to a pod whose listener isn't up. Liveness kept on P2P (conservative).
- **H16** — rolling gate: bounded catch-up POLL (CATCHUP_TIMEOUT) instead of a single read (fixes the
  half-rolled false-abort) + idempotent RESUME (skip validators already on the target image). Full
  RPC-based-height rewrite deferred (still log-parsed).
- **H17** — **partial:** `sm_put` now passes the secret via a 0600 temp file (`file://`), off the `aws` argv
  (the PAT-tarball leak). The `cast --private-key` / `openssl`/`keytool` argv items (deploy-test throwaway
  keys/passwords) remain — noted as follow-up.
- **H18** — runner clone-error output is SCRUBBED (`sed` `://<creds>@` → `://***@`) before it lands in the
  status marker / cloud-init log / console (the F28 leak path).
- **H19** — CloudTrail bucket: `force_destroy` gated (`cloudtrail_force_destroy`, prod false) + versioning +
  SSE (SSE-KMS via `cloudtrail_kms_key_arn`, else AES256) + trail `kms_key_id`. Object Lock deferred (needs
  bucket recreation).
- **H20** — **parameterized:** `data_cmk_arn` → chain-data PVC (StorageClass `kmsKeyId`) + node root EBS
  `kms_key_id`. Default "" (AWS-managed). RPC/JWT secrets, log groups, SNS remain a documented follow-up;
  a dedicated multi-service CMK policy is the go-live completion.
- **H21** — node LT IMDSv2 `http_put_response_hop_limit = 1` (a pod can no longer steal the node role).
- **H22** — `start.sh` + listener HARD-FAIL on `RPC_TLS_INSECURE=true` when `APP_ENV=prod`; gen-app-identity
  writes `APP_ENV=<env>` into the `.env`.
- **H23** — `--rpc-http-cors-origins` is now the `corsOrigins` value (was hardcoded `*` in 4 places); set
  "none" on the server-to-server pools. host-allowlist already a value.
- **H24** — signer writes serialized through one promise chain (`serializeWrite`) so concurrent `set()`s get
  sequential nonces; `FetchRequest` timeout + bounded `tx.wait(1, txTimeoutMs)`.
- **H25** — bootstrap persists the deployed `CONTRACT_ADDRESS`/`DEPLOY_BLOCK` back to the app-env secret
  (+ `secretsmanager:PutSecretValue` on the instance role) so an instance replacement doesn't redeploy an
  empty contract.
- **H26** — `full-delete.sh`: account+region **denial guard** (`EXPECT_ACCOUNT_ID`/`EXPECT_REGION` must match
  the live caller — deploy-test-only, never prod), `DeletionGroup` regex validation, and EIP `release-address`
  after NAT teardown (was leaking billable EIPs).
- **H27** — **DEFERRED.** A safe fix is a coordinated rename of every `besu-node-*` secret + the genesis-Job
  prefixes + the SecretProviderClass + the IRSA scope with a `name_prefix`; done inconsistently it bricks the
  deploy (pods can't find their keys), and it can't be apply-validated here. Not currently hit (one deployment
  per account/region). Left as a documented, apply-tested go-live task.

**P1 per-item (all on `feature/production-hardening`; live-confirmed 2026-07-11 = H5/H6/H7/H10/H12, rest statically validated):**
- **H5** — `terraform/runner` authors a scoped deploy policy and defaults to it; AdministratorAccess is
  a `use_admin_deploy_policy` break-glass. **Rewritten 2026-08-10** around a permissions boundary
  (`terraform/iam-boundary.tf`): explicit service allowlist + resource-scoped
  SecretsManager/KMS/S3/IAM + boundary-enforcing and self-mutation denies. ⚠️ Live-validated in its
  2026-07-11 (looser) form; the tightened version is NOT yet apply-validated — run the mock, and use
  `deploy_extra_actions` (not a code edit) to absorb any denied action.
- **H6** — new `networkpolicy.yaml` (per-role ingress: P2P+metrics always, RPC only from the role's
  client, validator ops gets NO RPC rule) gated `network_policy.enabled` (OFF; needs the VPC CNI
  agent via `enable_network_policy`). Ops-listener JWT is now a render-time precondition
  (`ops_rpc_allow_no_jwt` escape hatch). ⚠️ NetworkPolicy needs client-CIDR set + connectivity
  validation on a mock.
- **H7** — dedicated `encryption_config` CMK on the cluster (`enable_secrets_encryption`, default true,
  one-way); confirmed + commented that the SecretProviderClass is file-mount-only (no `secretObjects`
  → keys never enter etcd).
- **H8** — new `app_signer_account`; the root unions it into `initial_account_allowlist` +
  `genesis_funded_accounts` (additive/distinct); `gen-app-identity.sh` writes it and the stale
  "permissioning OFF" comments are fixed.
- **H9** — JWT hardened (default 90d TTL + `aud`/`jti`/`iat`/`nbf`, configurable); opt-in client-cert
  pinning (`mtls.knownClientsSecret` + `caClientsEnabled`). ⚠️ dedicated client CA + CRL/OCSP revocation
  deferred; verify Besu's known-clients/ca-clients semantics before relying on strict pinning.
- **H10** — core addons pinnable (`addon_versions`/`ebs_csi_addon_version`, resolve-then-pin) +
  `resolve_conflicts_on_update = PRESERVE`; wired the VPC CNI NetworkPolicy agent for H6.
- **H11** — wired the `bft.legacyProtocolEncoding` chart flag (was echo-only) + `LEGACY_PROTOCOL_ENCODING`
  in the rolling script; new `rolling-besu-rollback.sh`. EKS no-downgrade + rollback runbook → guide §10.
- **H12** — validations added: `validator_count` 3F+1≥4, `chain_id`>0 & not a public ID, block-period≥1,
  `gas_limit` hex, address regex on admin/allowlist/funded/app-signer, reject `0.0.0.0/0` in the CIDR
  lists, fixed the `worker_node_count` condition/message mismatch. (Permissioning-mode enums already existed.)

The four P0 fixes landed on branch `feature/production-hardening`. They are validated
statically only — the pentest plan below (run on a mock `feature/c6-c12-combined` deploy)
is how they get *confirmed* end-to-end. **A full executable mock-deploy + pentest runbook for
all 27 landed items (P0–P2) is in `docs/hardening-validation-plan.md`** — it flips the P2
opt-in toggles ON (they are all at default in `primary.tfvars`, so a plain deploy tests none of
H6/H13/H19/H20), maps every item to an inline `▶ CHECK` or a §3 pentest scenario, and unwinds
the H13 deletion-protection before the mandatory same-day teardown. Per-item "IMPLEMENTED" notes
are inline in each entry. Design calls worth knowing: H1 uses `ignore_changes=[values]`+`OnDelete` (the peer
ConfigMap decoupling, backlog item 3, was deferred — the two guards already meet the
acceptance criteria and the ConfigMap refactor risked the C10 DNS gate); H2 uses
`ignore_changes`+a Job ConfigMap guard (the canonical chain-manifest, item 5, and defaulting
`use_provided_validator_keys=true`, item 4, were deferred as larger follow-ups); H4 adds
app-level auth (the authoritative control) + one cycle-free SG narrowing (full SG lockdown
noted as follow-up).

---

## Priority summary

| ID | Title | Sev | Themes | Status |
|----|-------|-----|--------|--------|
| **H1** | Routine `terraform apply` restarts ALL validators at once → QBFT halt | **Critical** | 3,4 | ✅VERIFIED · **DONE** |
| **H2** | Genesis Job re-runs → mismatched genesis/pubkeys → chain brick | **Critical** | 3,4 | ✅VERIFIED · **DONE** |
| **H3** | C6 `hot` allowlist reload silently no-ops on validators (revocation not enforced) | **Critical** | 1,4 | ✅VERIFIED · **DONE** |
| **H4** | App tx-submitting API is unauthenticated, whole-VPC reachable, CSRF-able | **High** | 1,2,7 | ⚠️TRIAGE · **DONE** |
| **H5** | In-VPC runner hardwired to `AdministratorAccess`, no scope-down path | **High** | 1,2 | ⚠️TRIAGE · **DONE — boundary + scoped policy landed 2026-08-10; needs apply-validation** |
| **H6** | No NetworkPolicies over privileged RPC listeners (QBFT/ADMIN/PERM/DEBUG); ops JWT optional | **High** | 1,2 | ✅VERIFIED · **DONE (opt-in)** |
| **H7** | EKS Secrets not envelope-encrypted with CMK; CSI `syncSecret`→etcd risk | **High** | 1,4 | ⚠️TRIAGE · **DONE** |
| **H8** | App signer funded but never allowlisted under `local` default → `set()` denied | **High** | 1,4,7 | ✅VERIFIED · **DONE** |
| **H9** | SWIFT mTLS: shared infra CA, no client-cert pinning, no revocation, 1-yr JWT | **High** | 1,2 | ⚠️TRIAGE · **DONE (partial)** |
| **H10** | EKS core addons unpinned + `OVERWRITE` → silent CoreDNS/kube-proxy/CNI/CSI upgrades | **High** | 3 | ✅VERIFIED · **DONE** |
| **H11** | No rollback per upgrade type; QBFT 25→26 wire-compat flag not wired | **High** | 3,5 | ⚠️TRIAGE · **DONE** |
| **H12** | Sparse input validation across Terraform/chart variables | **High** | 7 | ✅VERIFIED · **DONE** |
| **H13** | No `prevent_destroy`/`create_before_destroy` on critical stateful resources | **Medium** | 4 | ✅VERIFIED · **DONE (NLB; rest doc'd)** |
| **H14** | Containers lack `securityContext` hardening | **Medium** | 1,5 | ⚠️TRIAGE · **DONE** |
| **H15** | Probes check only the P2P TCP port, not RPC/consensus health | **Medium** | 5 | ⚠️TRIAGE · **DONE** |
| **H16** | Rolling-upgrade gate brittle: log-parsed height, single-shot catch-up, no resume | **Medium** | 3,5 | ⚠️TRIAGE · **DONE (poll+resume)** |
| **H17** | Secrets passed on process argv (faucet key, keystore pw, PAT tar) | **Medium** | 1 | ⚠️TRIAGE · **PARTIAL (sm_put)** |
| **H18** | GitHub PAT can leak into cloud-init logs / status marker via git clone error | **Medium** | 1 | ⚠️TRIAGE · **DONE** |
| **H19** | CloudTrail audit bucket: `force_destroy`, no versioning/Object-Lock/SSE-KMS | **Medium** | 1,4 | ⚠️TRIAGE · **DONE (Obj-Lock doc'd)** |
| **H20** | Data-at-rest CMK inconsistency (chain-data/node EBS, RPC keystore/JWT, logs, SNS) | **Medium** | 1 | ⚠️TRIAGE · **DONE (PVC+EBS; rest doc'd)** |
| **H21** | Worker IMDSv2 hop limit = 2 lets a pod steal the node role | **Medium** | 1 | ⚠️TRIAGE · **DONE** |
| **H22** | `RPC_TLS_INSECURE=true` disables TLS process-wide, lives in the prod path | **Medium** | 1,7 | ✅VERIFIED · **DONE** |
| **H23** | `--host-allowlist=*` + `--rpc-http-cors-origins=*` on every listener | **Medium** | 1,2 | ✅VERIFIED · **DONE (CORS)** |
| **H24** | No signer nonce/concurrency control; no RPC/tx timeouts | **Medium** | 4,5 | ⚠️TRIAGE · **DONE** |
| **H25** | Bootstrap auto-redeploys contract, overwrites `CONTRACT_ADDRESS`, no durable store | **Medium** | 4 | ⚠️TRIAGE · **DONE** |
| **H26** | `full-delete.sh` leaks EIPs, defaults to `us-east-1`, leaves VPC/IGW/IAM | **Medium** | 4,7 | ⚠️TRIAGE · **DONE** |
| **H27** | Static Secrets Manager names → cross-deployment IRSA read + collision | **Medium** | 1,4 | ⚠️TRIAGE · **DEFERRED** |
| **H28** | App API hygiene: error disclosure, no body cap/rate limit, uint256 bounds, listener leak | **Low** | 1,7 | ⚠️TRIAGE |
| **H29** | Allowlist address case normalization inconsistent (add vs remove) | **Low** | 4,7 | ⚠️TRIAGE |
| **H30** | NLBs: no access logging / deletion protection; RPC ingress on shared cluster SG | **Low** | 2,5 | ⚠️TRIAGE |
| **H31** | `grafana_admin_password` may be empty → chart default credential | **Low** | 1,7 | ⚠️TRIAGE |
| **H32** | Runner tar-extraction unsanitized; `sm_get` swallows errors; port-forward readiness | **Low** | 1,5 | ⚠️TRIAGE |
| **H33** | Consensus alerting + doc/comment correctness (round-change alert, stale comments) | **Low** | 5,6 | ⚠️TRIAGE |

**Theme coverage:** (1) vulns/bugs → H3–H9,H14,H17–H23,H27,H28,H31,H32; (2) pentest → H4,H5,H6,H9,H23,H30 + the PT plan below; (3) **upgrade/update fail-safety → H1,H2,H10,H11,H16**; (4) data-corruption/breakdown → H1,H2,H3,H7,H8,H13,H19,H24,H25,H26,H29; (5) robustness → H11,H14,H15,H16,H24,H30,H32,H33; (6) improvements → H33 + the "adopt regardless" items; (7) input validation → H4,H8,H12,H22,H26,H28,H29,H31.

---

## P0 — Critical (chain-halt / data-loss / takeover). Do these before any real go-live.

### H1 — Make validator releases immune to bulk mutation by a routine `terraform apply`
- **Source.** Upgrade F-A1/F-A3 + Helm #1. ✅VERIFIED.
- **Problem.** Every validator is its own 1-replica StatefulSet/Helm release
  (`terraform/modules/besu/main.tf:118-119`, `for_each = local.nodes`), all reading the
  same `besuImage` (`:131`) **and** the same `peers = local.peers` (`:151`). The StatefulSet
  sets **no `updateStrategy`** (`helm/charts/besu-node/templates/statefulset.yaml`) so it
  defaults to `RollingUpdate`, and the validator PDB `maxUnavailable=0` does **not** gate
  StatefulSet template updates (only evictions). There is **no `ignore_changes`** on the
  image or values anywhere (the only one in the repo is on `desired_size`,
  `terraform/modules/eks/main.tf:325`). So a single `terraform apply` that (a) bumps
  `besu_version`, or (b) scales `app_rpc_count`/`explorer_rpc_count` 0→N — which rewrites
  `local.peers` (`:41-42`) on **every** validator — or (c) changes any other shared node
  value (`toolsImage`, resources, cert names, chart version) re-renders and restarts **all
  four validators in parallel** → quorum (3 of 4) lost → **chain halts**. The safe path
  (`scripts/maintenance/rolling-besu-upgrade.sh`) is opt-in and enforced only by a doc note
  (CLAUDE.md §6). Adding the app layer — a documented operation — trips this.
- **Change.**
  1. Add `lifecycle { ignore_changes = [values, set] }` (or a targeted image/peers key) to
     `helm_release.node` for the validator role so Terraform **cannot** push validator pod-
     template changes in bulk.
  2. Set `updateStrategy.type: OnDelete` on the validator StatefulSet so even an out-of-band
     `helm upgrade` restarts a validator pod only when an operator deletes it (one at a time,
     under the existing quorum gate).
  3. Decouple peer topology from the validator pod spec (read `peers` from a ConfigMap the
     init consumes) so adding a non-validator pool doesn't mutate validator manifests.
  4. Generalize `rolling-besu-upgrade.sh` into a `rolling-besu-apply.sh` that accepts
     arbitrary `--set` overrides and applies them one-validator-at-a-time with the quorum
     gate — the single supported path for any validator-affecting change.
  5. Add a plan-time **preflight** (external data source / `precondition`) that fails the
     plan if >1 validator release would change image/values in one apply.
- **Acceptance.** [ ] A `besu_version` bump via `terraform apply` is a no-op on the validator
  releases (image only moves through the rolling script). [ ] Scaling `app_rpc_count` 0→N
  leaves validator pods running (no restart). [ ] `helm template`/`terraform validate` pass.
- **Files.** `terraform/modules/besu/main.tf`, `helm/charts/besu-node/templates/statefulset.yaml`,
  `scripts/maintenance/rolling-besu-upgrade.sh` (→ `rolling-besu-apply.sh`), docs 02 + guide §10.
- **✅ IMPLEMENTED (2026-07-06).** Validators split into `helm_release.validator` with
  `lifecycle{ ignore_changes=[values] }`; a shared `local.node_values` keeps both node
  resources byte-identical; chart pins `updateStrategy: OnDelete` for `role=validator`
  (RollingUpdate for the rest). New `scripts/maintenance/rolling-besu-apply.sh` (arbitrary
  `--set`, OnDelete-aware: helm-upgrade → delete pod → wait Ready → quorum/catch-up gate);
  `rolling-besu-upgrade.sh` is now a back-compat wrapper. **Deferred:** peer ConfigMap
  decoupling (item 3) — `ignore_changes` already makes a bulk apply a no-op on validators; and
  the plan-time preflight (item 5) — `ignore_changes` makes a bulk validator change impossible
  via Terraform, which is stronger. **Migration:** for a fresh chain, none is needed. For an
  already-applied chain, run `scripts/maintenance/migrate-h1-validator-split.sh` first — it
  discovers `helm_release.node["besu-validator-*"]` in state and `terraform state mv`s each to
  `helm_release.validator[...]` (idempotent, dry-run by default, state-only, leaves non-validators
  alone), so the apply re-homes rather than destroy+recreates them. Safe no-op on fresh state.

### H2 — Guard the genesis Job against destructive re-runs on a live chain
- **Source.** Upgrade F-A2 + Helm #2. ✅VERIFIED.
- **Problem.** The genesis `helm_release` includes `images = { besu = var.besu_image, ... }`
  (`terraform/modules/besu/main.tf:73`), so a `besu_version` bump upgrades the genesis
  release and re-runs the Job. The Job has **no `helm.sh/hook`** annotation (only
  `ttlSecondsAfterFinished: 3600`, `helm/charts/besu-genesis/templates/job.yaml:30`) despite
  a comment claiming it's a hook — so whether an upgrade fails on the immutable Job template
  or silently recreates+re-runs it depends on whether the prior Job was TTL-reaped
  (nondeterministic). `skipExistingKeys=true` protects the **keys** in Secrets Manager but
  the Job **unconditionally** regenerates `genesis.json` + `node-pubkeys.json` from freshly
  generated identities and `kubectl apply`s the `besu-genesis` ConfigMap (`job.yaml:239-244`).
  With the prod default `use_provided_validator_keys=false`, the republished `extraData`
  references discarded validator addresses → validators compute a genesis hash that no longer
  matches their RocksDB → **Besu refuses to start; the chain is bricked**. Even with provided
  keys, bootnode/RPC/app/explorer pubkeys are regenerated and mismatch their live keys.
- **Change.**
  1. Gate `helm_release.genesis` behind `re_genesis_allowed` (default false) **or** add
     `lifecycle { ignore_changes = [values] }` so a node image bump never re-renders genesis.
  2. Remove `images.besu` from the genesis release inputs (decouple genesis from `besu_version`).
  3. Make genesis publication **read authoritative pubkeys from Secrets Manager**, not from
     freshly generated keys; and make the Job no-op when the `besu-genesis` ConfigMap already
     exists with a matching `genesis.json` (detect "chain exists" via validator PVCs / height).
  4. Default `use_provided_validator_keys=true` for a long-lived prod chain (idempotent genesis).
  5. **(Recommended mechanism)** back the guard with a durable, versioned **canonical chain-manifest**
     — genesis SHA-256, chain-id, validator addresses in canonical order, secret-ARN→address map,
     init Besu version, permissioning mode + initial allowlists, approved commit SHA — that every
     plan / Helm upgrade / node startup verifies and refuses to mutate on mismatch.
- **Acceptance.** [ ] A re-apply against an existing chain does not overwrite `genesis.json`
  or restart validators into a mismatched genesis. [ ] Re-genesis requires an explicit,
  documented, guarded flag that also wipes node-key secrets **and** PVCs together.
- **Files.** `terraform/modules/besu/main.tf`, `helm/charts/besu-genesis/templates/job.yaml`,
  `helm/charts/besu-genesis/values.yaml`, `terraform/environments/prod/primary.tfvars(.example)`.
- **✅ IMPLEMENTED (2026-07-06).** `helm_release.genesis` gets `lifecycle{ ignore_changes=[values] }`
  (a `besu_version` bump no longer re-runs the Job). The Job's publish step now REFUSES to
  overwrite an existing `besu-genesis` ConfigMap unless `allowRegenesis=true` (new root var
  `allow_regenesis` → module → chart, default false; genesis SA already has `get configmaps`).
  The false "post-install hook" comment (`job.yaml:17`) is corrected. **Deferred:** the canonical
  chain-manifest (item 5) and defaulting `use_provided_validator_keys=true` (item 4) — the
  ignore_changes + ConfigMap guard already close the routine-apply brick; those two are larger,
  separately-tracked robustness follow-ups. Re-genesis stays a manual, documented op (state rm the
  release + delete the ConfigMap + wipe node-key secrets + validator PVCs).

### H3 — Fix (or remove) the C6 `hot` account-allowlist reload — it silently no-ops on validators
- **Source.** Helm #3 + Bash #1 + Bash #3. ✅VERIFIED.
- **Problem.** Besu enforces the accounts-allowlist from `/data/permissions_accounts.toml`, a
  **boot-time copy** the `build-config` init makes from the ConfigMap
  (`helm/charts/besu-node/templates/statefulset.yaml:171`). The main besu container does
  **not** mount the ConfigMap (`:365-369`). `scripts/permissioning/_perm-lib.sh:137-162`
  (`PROPAGATE=hot`) patches the ConfigMap, waits, then calls `perm_reloadPermissionsFromFile`
  — which re-reads the **stale `/data` copy** and returns `Success`. So onboarding via `hot`
  never authorizes the new sender on validators, and — the security-critical case —
  **revoking a compromised account via `hot` does not take effect on the validators** (the
  block-inclusion enforcement point), while reporting success. `list-accounts.sh --live` reads
  `/config/perm-accounts/...` inside the besu container (`list-accounts.sh:22-31`), a path that
  doesn't exist there → always `<unreadable>`, so the drift is invisible to the operator.
- **Change.**
  1. Make `hot` real: use `perm_addAccountsToAllowlist` / `perm_removeAccountsFromAllowlist`
     (mutate in-memory + persist to the writable `/data` file), **or** deprecate `hot` and
     document `restart` (which re-copies at boot) as the only supported propagation.
  2. After any reload, **read back** the enforced list (`perm_getAccountsAllowlist`) and
     **fail loudly** on mismatch, on every enforcing node.
  3. Fix `list-accounts.sh --live` to read `/data/permissions_accounts.toml`.
- **Acceptance.** [ ] A revocation via the supported path is provably enforced on all 4
  validators (a subsequent tx from the revoked account is rejected — verified in a deploy-test).
  [ ] `--live` shows the actually-enforced list.
- **Files.** `scripts/permissioning/{_perm-lib.sh,add-account.sh,remove-account.sh,reload-permissions.sh,list-accounts.sh}`,
  docs 02 §2.5 + guide runbook.
- **✅ IMPLEMENTED (2026-07-06).** `hot` no longer calls the no-op `perm_reloadPermissionsFromFile`.
  It now RECONCILES each validator's in-memory allowlist to the patched ConfigMap via
  `perm_getAccountsAllowlist` → `perm_add/removeAccountsFromAllowlist` (mutate memory AND persist
  to the writable `/data` file), then READS BACK `perm_getAccountsAllowlist` and fails loudly on
  mismatch. The `restart` path gains a `/data` read-back verify (`verify_via_file`). `perm_rpc`
  polls the port for readiness (no fixed sleep — also H32). `list-accounts.sh --live` now reads
  `/data/permissions_accounts.toml` (was the unmounted `/config/perm-accounts/...` → always
  `<unreadable>`). All-4-validator revocation enforcement must still be confirmed on a mock deploy.

### H4 — Authenticate the app's tx-submitting API and narrow its network reach
- **Source.** App #1. ⚠️TRIAGE (High).
- **Problem.** `POST /api/value` (`app/web/src/app/api/value/route.js:29-56`) signs and submits
  a `set()` tx with the server-side EOA with **no authn/authz**. The instance SG
  (`app/infra/main.tf:66-79`) and ALB SG (`:96-102`) allow ingress from the **entire**
  `app_vpc_cidr`, so any ENI/workload in the app VPC (not just the SSM operator) can originate
  transactions as the signer (which under Option A is also the admin/allowlist account). A
  `text/plain` POST skips CORS preflight and `req.json()` parses it anyway → **CSRF**: a
  malicious page can drive `set()` while the operator holds the port-forward open.
- **Change.** Require auth on all mutating routes (operator bearer/HMAC, SigV4, or ALB
  client-cert); add an Origin/CSRF-token check on POST; narrow the instance + ALB SGs to only
  the operator ingress path; treat "internal" as defense-in-depth, not authentication.
- **Acceptance.** [ ] An unauthenticated in-VPC POST to `/api/value` is rejected. [ ] A
  cross-origin `text/plain` POST cannot submit a tx.
- **Files.** `app/web/src/app/api/value/route.js` (+ other mutating routes), `app/infra/main.tf`.
- **✅ IMPLEMENTED (2026-07-06).** New `app/web/lib/apiauth.mjs` `guardMutation(req)` runs first on
  POST `/api/value`: requires `Content-Type: application/json` (kills the text/plain CSRF simple-
  request), rejects non-same-origin via `Sec-Fetch-Site`/`Origin`, and requires
  `Authorization: Bearer <APP_API_TOKEN>` (constant-time compare, **fail-closed** 503 when unset).
  `config.mjs` gains `apiToken`/`allowedOrigin`; `gen-app-identity.sh` provisions a 256-bit
  `APP_API_TOKEN`; the UI adds an operator-token field (kept in sessionStorage, not the served
  HTML). SG: the instance's Next.js UI ingress is narrowed from the whole app-VPC CIDR to the ALB
  SG (cycle-free). **Follow-up (noted):** full SG lockdown (ALB←app, listener NLB) + rate-limit/body-cap (H28).

---

## P1 — High (privilege, exposure, upgrade-safety, input-validation)

### H5 — Give the in-VPC runner a least-privilege deploy role (not `AdministratorAccess`)
- **Source.** TF #1. ⚠️TRIAGE (High).
- **Problem.** `terraform/modules/runner/variables.tf:46-56` defaults the instance profile to
  `arn:aws:iam::aws:policy/AdministratorAccess`, and `terraform/runner/main.tf:17-34` provides
  **no override variable** — so prod cannot narrow it without editing module code. The runner
  is reachable by anyone with `ssm:StartSession`, pulls its toolchain over the network
  (`curl … | bash`), and holds account-wide admin → SSM access or a supply-chain compromise =
  full account takeover, not just cluster admin.
- **Change.** Add `deploy_policy_arn` to `terraform/runner` and thread it into the module;
  author a least-privilege policy (only the `ec2/eks/iam/secretsmanager/elbv2/kms/logs/s3`
  actions the stack needs) and make it the prod default.
- **Acceptance.** [x] Runner applies/destroys the stack with the scoped policy (live 2026-07-11,
  looser version); `AdministratorAccess` is never the prod default. **Files.**
  `terraform/modules/runner/*`, `terraform/runner/*`.

**RESIDUAL CLOSED IN CODE 2026-08-10 (the "#1 go-live task").** The 2026-07-06 whitebox pentest
rated the first scoped policy PowerUser-EQUIVALENT and escalatable (`CreateRole` +
`PutRolePolicy` + `PassRole "*"` ⇒ mint an admin role, pass it to EC2 ⇒ account takeover). That
is now closed by two coupled halves — **neither works alone**:

1. **Permissions boundary on every stack role** — new `terraform/iam-boundary.tf` creates
   `<name_prefix>-role-boundary` (allow-all `NotAction [iam:*, organizations:*, account:*]`, plus
   read-only IAM + `iam:CreateServiceLinkedRole` which `AmazonEKSClusterPolicy` and the LBC policy
   need). Threaded as `permissions_boundary` into all **9** chain-created roles across
   `modules/{network,eks,iam,storage-csi,observability,rpc-access}` (the 10th, the runner's own
   role, is excluded by design — see below). New root vars
   `enable_iam_permissions_boundary` (default **true**) and `iam_permissions_boundary_arn`
   (bring-your-own); new output `iam_permissions_boundary_arn`. The runner's own role is
   deliberately **not** capped (it needs IAM write) — it is constrained by (2) instead.
2. **Rewritten `terraform/runner/deploy-policy.tf`** — four layers:
   (a) explicit **service allowlist** (`deploy_service_actions`, derived from the stack's resource
   inventory) replacing the `NotAction` PowerUser shape; (b) **resource-scoped sensitive stores**
   — Secrets Manager on `besu-*`/`<name_prefix>-*`, KMS on keys tagged `Project=<project>` (ABAC),
   S3 on the state bucket + the stack's own buckets; (c) **resource-scoped IAM** — writes only on
   `<name_prefix>-*`, SLRs only under `/aws-service-role/`, OIDC only for this region's EKS issuer,
   `PassRole` only to `<name_prefix>-*`; (d) **anti-escalation denies** —
   `iam:CreateRole`/`iam:PutRolePermissionsBoundary` denied unless the request carries exactly the
   boundary ARN (`StringNotEquals` is true when the key is absent, so a boundary-less create is
   denied too), `iam:DeleteRolePermissionsBoundary` denied outright, no self-mutation of the runner
   role/profile/policy or of the boundary policy, and no attaching AWS-managed
   Administrator/PowerUser/IAMFull.
   Escape hatches that do **not** re-open escalation (denies always win): `deploy_extra_actions`,
   `deploy_extra_secret_arns`, `deploy_extra_s3_arns`. Two plan-time preconditions fail loudly if
   the chain has no boundary (override: `allow_unbounded_deploy_policy`) or no `project_name`
   output, plus a third that catches the 6,144-char managed-policy limit (rendered: **~4.6k**).

- **Verified statically:** `terraform validate` clean on both roots; the policy document was
  rendered offline and inspected — 18 statements, 4,575 chars, all four denies present with the
  expected conditions.
- **Accepted residual (documented in the file header, not hidden):** `ec2:*`/`eks:*`/
  `elasticloadbalancing:*` stay account-wide (dynamically created resources cannot be pre-scoped);
  the runner can read this stack's validator-key secrets and decrypt its CMKs (inherent — it
  deploys them); it can stop this stack's CloudTrail (Object Lock excluded by the
  no-deletion-protection directive, see H19); and it can create a boundary-capped role with an
  external trust principal (IAM has no condition key for trust-policy principals). Guarantee is
  precise: **blast radius stays inside this stack; account admin is unreachable.**
- **NOT YET APPLY-VALIDATED — this is the remaining acceptance gap.** Exercise on the next mock:
  the harness now runs `H5-boundary` (every `<name_prefix>-*` role except the runner carries the
  expected boundary) and `H5-escalate` (five `simulate-principal-policy` what-ifs: off-prefix
  CreateRole, boundary-less CreateRole, boundary lift, self `PutRolePolicy`, off-scope
  `GetSecretValue` — all must come back denied). Adopting on an already-applied chain adds the
  boundary in place on the next chain apply. **Related: F33** — a Phase-C apply that tries to change
  the boundary policy is now denied by design, so root-cause the laptop↔runner plan divergence in
  the same run.

### H6 — Add NetworkPolicies over the privileged RPC listeners; require ops JWT
- **Source.** Helm #4. ✅VERIFIED (0 NetworkPolicy files).
- **Problem.** The ops listener (`QBFT,ADMIN,DEBUG,TXPOOL,PERM`, `values.yaml:164-172`, with
  `jwtPubkeySecret: ""` = no auth by default) and explorer listener (`DEBUG,TRACE`) are plain
  ClusterIP services (`service-rpc.yaml`), reachable by **every pod in the cluster** — there
  are **no NetworkPolicies** in the repo. A single compromised pod (Blockscout frontend, app
  reach) can call `qbft_proposeValidatorVote` to alter the validator set, `perm_*` to mutate
  permissioning, or `debug_*/trace_*`. The "reached only via port-forward" comment is wrong —
  port-forward is how the operator reaches it; ClusterIP doesn't restrict other callers.
- **Change.** Add NetworkPolicies scoping each internal listener's ingress to its intended
  client only (ops → operator/runner identity; explorer-rpc → Blockscout pods; app-rpc → the
  edge Service; swift-rpc → the NLB). Make a non-empty `jwtPubkeySecret` a hard precondition
  when `ops_rpc_enabled=true`. Consider default-deny ingress/egress for the `besu` namespace.
- **Acceptance.** [ ] A pod outside the allowed set cannot reach the ops/explorer listeners.
  [ ] Enabling ops without a JWT secret fails render-time. **Files.** new
  `helm/charts/besu-node/templates/networkpolicy.yaml`, `values.yaml`.

### H7 — Enable EKS Secrets envelope encryption (CMK) and keep node keys out of etcd
- **Source.** TF #2. ⚠️TRIAGE (High base gap; Medium on the etcd escalation).
- **Problem.** `terraform/modules/eks/main.tf:115-153` has no `encryption_config {}`, so K8s
  Secrets in etcd are protected only by the AWS-managed EKS layer, not the C12 CMK. The
  Secrets Store CSI driver is installed with `syncSecret.enabled=true`
  (`terraform/modules/storage-csi/main.tf:172-179`); if any Besu `SecretProviderClass` uses
  `secretObjects:`, the decrypted secp256k1 node key is mirrored into an etcd Secret,
  bypassing the CMK custody C12 relies on.
- **Change.** Add `encryption_config { provider { key_arn = <cmk> }, resources = ["secrets"] }`
  (reuse the C12 CMK or a dedicated one). Confirm the SecretProviderClass mounts keys as
  files only (no `secretObjects`) so keys stay in tmpfs, and document that.
- **Acceptance.** [ ] Cluster shows Secrets encryption enabled with the CMK. [ ] No node-key
  Secret is synced to etcd. **Files.** `terraform/modules/eks/main.tf`, `helm/charts/besu-node/templates/secretproviderclass.yaml`.

### H8 — Reconcile the app signer with `account_permissioning_mode="local"` (funded ≠ allowlisted)
- **Source.** App #2 + Bash #10. ✅VERIFIED (prod tfvars `local`).
- **Problem.** `terraform/environments/prod/primary.tfvars:73` runs deny-by-default account
  permissioning, but `app/scripts/gen-app-identity.sh` was frozen at the "permissioning is OFF"
  assumption: it writes the fresh signer only to `genesis_funded_accounts` (a balance), never
  to `initial_account_allowlist`, and its header/comments (and the tfvars "unused while account
  mode = off" comment) are now false. On a fresh prod deploy the new signer is funded but not
  authorized → its `set()` and the Storage contract-create tx are **rejected**; no
  `add-account.sh` step exists in the app deploy path. The committed tfvars only "works"
  because one address was hand-pasted into both lists — brittle.
- **Change.** Either emit the signer into `initial_account_allowlist` too, or wire the runtime
  onboarding (`add-account.sh`, per the H3-fixed path) into the app deploy after chain start;
  fix the stale "OFF" comments in the script and tfvars.
- **Acceptance.** [ ] Fresh prod deploy with `local` mode: the app signer's `set()` mines.
  **Files.** `app/scripts/gen-app-identity.sh`, `terraform/environments/prod/primary.tfvars(.example)`, doc 03.

### H9 — Harden the SWIFT mTLS trust model (pinning, dedicated client CA, revocation, short JWT)
- **Source.** App #3. ⚠️TRIAGE (Medium–High).
- **Problem.** The SWIFT edge authenticates clients purely by "chains to a CA in the
  truststore" (`statefulset.yaml:250-255`), and that truststore is our **single infra CA**
  (`scripts/pki/issue-server-cert.sh:66-67`) — the same CA that signs server/app-rpc/node
  certs. So **any** clientAuth cert the CA ever signs is accepted as a valid SWIFT client;
  there is no `known-clients-file` pinning and no CRL/OCSP, so a compromised client cert can't
  be revoked within its ~1-yr validity. The method-scoping JWT is a static bearer valid a full
  year (`scripts/access/make-join-pack.sh:48`) with no `aud`/`jti`/`nbf`.
- **Change.** Pin SWIFT's client cert via `--rpc-http-tls-known-clients-file` (fingerprint) or
  issue SWIFT client certs from a **dedicated client CA** distinct from the server/infra CA;
  add revocation (CRL/OCSP or short-lived certs); shorten the JWT TTL and add `aud`/`jti`.
- **Acceptance.** [ ] A cert signed by the infra CA but not the pinned SWIFT client is rejected.
  **Files.** `helm/charts/besu-node/templates/statefulset.yaml`, `scripts/pki/*`, `scripts/access/make-join-pack.sh`.

### H10 — Pin EKS core addons and stop silent `OVERWRITE` upgrades
- **Source.** TF #11 + Upgrade F-A4. ✅VERIFIED.
- **Problem.** `vpc-cni`, `coredns`, `kube-proxy` (`terraform/modules/eks/main.tf:335-367`) and
  `aws-ebs-csi-driver` (`terraform/modules/storage-csi/main.tf:87-97`) are created with **no
  `addon_version`** and `resolve_conflicts_on_update = "OVERWRITE"` — violating the §6 "pin
  explicitly" policy. A `kubernetes_version` bump (or a default change) silently upgrades and
  restarts CoreDNS/kube-proxy with no pin to roll back to; a validator restarting during a
  CoreDNS rollout can't resolve peers for its C10 `wait-peer-dns` gate → `Init:Error`.
  Separately (invisible in the plan), the addons can fall outside the new K8s version's skew.
- **Change.** Add `addon_version` variables (resolve-then-pin), surface in `primary.tfvars`,
  set `resolve_conflicts_on_update = "PRESERVE"`, and sequence addon upgrades as their own
  reviewed step (addons → control plane → nodes one at a time), never bundled with a
  `cluster_version` bump.
- **Acceptance.** [ ] Addon versions are pinned + visible in the plan; a cluster-version bump
  does not silently move them. **Files.** `terraform/modules/eks/main.tf`,
  `terraform/modules/storage-csi/main.tf`, `terraform/variables.tf`, `primary.tfvars(.example)`, guide §10.

### H11 — Define + script rollback per upgrade type; wire the QBFT 25→26 wire-compat flag
- **Source.** Upgrade F-A5/F-A6. ⚠️TRIAGE (High).
- **Problem.** No tested rollback exists for any upgrade type. EKS control-plane **cannot be
  downgraded** (`terraform/modules/eks/main.tf:117`) — never documented as a hard constraint.
  `rolling-besu-upgrade.sh` rolls forward only and aborts mid-roll leaving a **mixed-version**
  validator set with no revert path. The QBFT 25→26 wire-compat flag
  `--Xbft-legacy-protocol-encoding` is **echo-only** — printed in the script's trailing note
  (`scripts/maintenance/rolling-besu-upgrade.sh:129`) and prose, but **not wired** into the
  chart args (`statefulset.yaml:205-236`) — so a real cross-major roll breaks wire-compat
  during the mixed window and the roll stalls.
- **Change.** Author + test `rolling-besu-rollback.sh` (mirror, pinned to the prior image); add
  a chart value `bft.legacyProtocolEncoding` that appends the flag, and have the rolling script
  auto-set it when from/to versions cross 25↔26 (then clear it after). Document the EKS
  "no-downgrade / one-minor-at-a-time" preflight and a per-type rollback runbook.
- **Acceptance.** [ ] A mock 25→26 roll keeps quorum through the mixed window. [ ] A failed roll
  has a tested revert. **Files.** `scripts/maintenance/*`, `helm/charts/besu-node/templates/statefulset.yaml` + `values.yaml`, guide §10.

### H12 — Add input validation across Terraform and chart variables
- **Source.** TF #6/#7/#8/#13 + Helm #7. ✅VERIFIED (16 `validation{}` blocks across ~281 vars).
- **Problem.** Sparse validation lets invalid/insecure values silently break or weaken the
  system. Specifics: `validator_count` accepts non-3F+1 / <4 (`terraform/variables.tf:245`,
  `modules/besu/variables.tf:56`) → no fault tolerance / halts on one loss during the very
  rolling upgrades the design assumes; `chain_id` defaults to `0` and is unvalidated
  (`variables.tf:210`) → replay-protection semantics off; `block_period_seconds`/`gas_limit`
  unvalidated → `requesttimeoutseconds=0` or invalid genesis; the two permissioning modes
  accept any string (a typo like `"local "` silently disables enforcement); `swift_sipn_allowed
  _cidrs`/`app_rpc_allowed_cidrs`/`eks_public_access_cidrs` accept `0.0.0.0/0`
  (`variables.tf:493,620,189`); `worker_node_count` validation says ">=4" but checks ">=2"
  (`variables.tf:124-127`); admin/allowlist addresses aren't regex-checked.
- **Change.** Add `validation{}` blocks: `validator_count >= 4 && (validator_count-1)%3==0`;
  `chain_id > 0` (and exclude known public IDs); `block_period_seconds >= 1`;
  `can(regex("^0x[0-9a-fA-F]+$", gas_limit))`; enum checks for both permissioning modes;
  reject `0.0.0.0/0`/`::/0` in the CIDR lists (and require non-empty when the ingress is on);
  `alltrue([for a in concat([admin], allowlist): can(regex("^0x[0-9a-fA-F]{40}$", a))])`;
  reject `account_permissioning_mode="local"` with an empty seed at plan time; fix the
  `worker_node_count` condition/message mismatch.
- **Acceptance.** [ ] Each invalid value fails `terraform plan` with a clear message.
  **Files.** `terraform/variables.tf`, `terraform/modules/besu/variables.tf`, `app/infra/variables.tf`.

---

## P2 — Medium (defense-in-depth, robustness, correctness)

### H13 — `prevent_destroy` / `create_before_destroy` on critical stateful resources
- **Source.** TF #12. ✅VERIFIED (zero `prevent_destroy` in tree).
- **Problem.** No backstop against accidental destroy/replace of the C12 CMK
  (`terraform/kms.tf` — deleting it makes every encrypted secret unrecoverable), the CloudTrail
  bucket, the node-key secrets, or the SWIFT NLB (`rpc-access/main.tf` — new DNS name breaks
  SWIFT). Separately, any change reordering `private_subnet_ids` (editing `availability_zone_
  count`/VPC CIDR) **force-replaces** the node group (ForceNew `subnet_ids`) → all workers
  destroyed at once → chain halt, with no `create_before_destroy`.
- **Change.** Add `lifecycle { prevent_destroy = true }` (gated by a var so deploy-tests can
  still tear down) to the CMK, CloudTrail bucket, node-key secrets, and NLBs for go-live;
  document AZ-count/CIDR edits as node-group-replacing and route them through a blue/green
  node-group procedure. **Files.** `terraform/kms.tf`, `modules/observability`, `modules/secrets`, `modules/rpc-access`, `modules/eks`.

### H14 — Container `securityContext` hardening
- **Source.** Helm #6. ⚠️TRIAGE (Medium).
- **Problem.** Only a pod-level `fsGroup: 1000` is set (`statefulset.yaml:36-37`); the besu
  container and init containers have no `runAsNonRoot`, `allowPrivilegeEscalation:false`,
  `capabilities.drop:[ALL]`, `seccompProfile`, or `readOnlyRootFilesystem`. `build-config`
  runs as **root** to `chown /data` (F32b). PSA "restricted" would reject this.
- **Change.** Add container `securityContext` (`runAsNonRoot`, `runAsUser:1000`,
  `allowPrivilegeEscalation:false`, `capabilities.drop:[ALL]`, `seccompProfile:RuntimeDefault`,
  `readOnlyRootFilesystem` + tmpfs scratch); scope root strictly to the init that needs it
  (or replace the chown with `fsGroupChangePolicy`). **Files.** `helm/charts/besu-node/templates/statefulset.yaml`, `besu-genesis/templates/job.yaml`.

### H15 — Probes that reflect RPC/consensus health, not just the P2P socket
- **Source.** Helm #5. ⚠️TRIAGE (Medium).
- **Problem.** Readiness/liveness are `tcpSocket: p2p-tcp` (`statefulset.yaml:351-358`). RPC
  pods are "Ready" (and get NLB/PrivateLink traffic) before their mTLS/HTTP listener is up or
  when it's wedged; a validator hung on RocksDB but holding the P2P socket is never restarted;
  an out-of-sync validator still reports Ready.
- **Change.** Use Besu's HTTP `/liveness`+`/readiness` (or an `eth_blockNumber`/`net_peerCount`
  exec probe) for RPC-role readiness; add a sync/peer-count readiness signal for validators.
  **Files.** `helm/charts/besu-node/templates/statefulset.yaml`, `values.yaml`.

### H16 — Make the rolling-upgrade gate robust (RPC-based height, bounded catch-up, resume)
- **Source.** Upgrade agent + Bash #4. ⚠️TRIAGE (Medium).
- **Problem.** The quorum/catch-up gate parses `grep 'block #'` from `--tail=200` logs
  (`rolling-besu-upgrade.sh:50-66,96-102`; same in `_perm-lib.sh:93-135`). It fails *closed*
  (good) but yields **false-negative aborts**: GATE 2 reads `latest_block "$v"` once right
  after restart (startup noise → low/zero → spurious `ABORT: has not caught up`), leaving a
  **half-rolled** fleet with no resume; a Besu log-wording change aborts every step; the
  catch-up math passes trivially when `head < tolerance`.
- **Change.** Gate on `eth_blockNumber` via the in-cluster ops/explorer RPC instead of logs;
  make GATE 2 a bounded poll loop before aborting; add an idempotent resume (skip validators
  already on `NEW_BESU_IMAGE`). **Files.** `scripts/maintenance/rolling-besu-upgrade.sh`, `scripts/permissioning/_perm-lib.sh`.

### H17 — Stop passing secrets on process argv
- **Source.** Bash #5. ⚠️TRIAGE (Medium).
- **Problem.** Private material is visible in `/proc/<pid>/cmdline`: the funded faucet key
  (`scripts/permissioning/fund-account.sh:79,100-102`, `cast … --private-key "$FAUCET_KEY"`),
  keystore/truststore passwords (`scripts/pki/issue-server-cert.sh:62,67`,
  `issue-app-rpc-cert.sh:77`, `openssl … pass:$KS_PASS` / `keytool -storepass`), and the
  PAT-containing tarball via `sm_put` positional argv (`scripts/lib/common.sh:26-30` reached by
  `scripts/runner/push-deploy-config.sh:50`).
- **Change.** `cast` → stdin/`--interactive`/keystore; `openssl` → `-passout env:`/`-passin`;
  `keytool` → feed via stdin; `sm_put` → `--secret-string file://<fd>`/`fileb://` (as
  `sm_put_file` already does). **Files.** `scripts/permissioning/fund-account.sh`, `scripts/pki/*`, `scripts/lib/common.sh`.

### H18 — Scrub the GitHub PAT from runner cloud-init logs and the status marker
- **Source.** Bash #2. ⚠️TRIAGE (Medium).
- **Problem.** The clone URL embeds `x-access-token:$TOKEN@github.com`; on auth failure git
  prints it to stderr, captured to `/var/log/besu-clone.err`, then `tail -1` is echoed into the
  `BOOTSTRAP_STATUS` marker and stdout (`terraform/modules/runner/main.tf:206-214`) → the token
  lands on disk and in `get-console-output`. This is exactly the F28 rotated-PAT path. Lesser
  exposure in `app/infra/main.tf:260-264`.
- **Change.** Scrub credentials before echoing (`sed -E 's#(x-access-token:)[^@]*@#\1***@#g'`);
  never write raw `besu-clone.err` to the marker/stdout; prefer
  `git -c http.extraHeader="AUTHORIZATION: bearer $TOKEN" clone https://github.com/org/repo` so
  the token is never in the URL. **Files.** `terraform/modules/runner/main.tf`, `app/infra/main.tf`.

### H19 — Harden the CloudTrail audit bucket for prod
- **Source.** TF #4. ⚠️TRIAGE (Medium).
- **Problem.** `terraform/modules/observability/main.tf:176-238`: audit bucket `force_destroy=
  true`, no versioning, no Object Lock, no SSE-KMS; the trail sets no `kms_key_id`. A `terraform
  destroy` or a mistaken delete wipes the forensic record of the incident itself; nothing
  prevents log tampering/deletion.
- **Change.** For prod: `force_destroy=false`, add versioning + Object Lock (governance/
  compliance) + SSE-KMS + lifecycle, and set `kms_key_id` on the trail; gate `force_destroy`
  behind a deploy-test-only var. **Files.** `terraform/modules/observability/main.tf`.

### H20 — Bring all sensitive data-at-rest under a customer CMK (consistency with C12)
- **Source.** TF #5/#14/#15. ⚠️TRIAGE (Medium/Low).
- **Problem.** After CMK-guarding the node **keys** (C12), the actual **chain data** PVCs
  (`storage-csi/main.tf:134-143`, no `kmsKeyId`) and node root volumes
  (`eks/main.tf:232-240`), the RPC/app-RPC keystores + JWT-signing keys
  (`secrets/main.tf:235-309`), and the CloudWatch log groups + SNS alerts topic
  (`network/main.tf:245`, `eks/main.tf:106`, `observability/main.tf:27-58`) all use
  AWS-managed keys — an audit-consistency gap that forfeits controlled key policy + per-decrypt
  CloudTrail visibility.
- **Change.** Set `kmsKeyId` on the gp3 StorageClass + `kms_key_id` on the node LT EBS block +
  the RPC/JWT secrets + log groups + SNS topic (grant the relevant IRSA roles); add
  `aws:SourceAccount` to the SNS topic policy. **Files.** `terraform/modules/{storage-csi,eks,secrets,network,observability}`.

### H21 — Set worker IMDSv2 hop limit to 1
- **Source.** TF #3. ⚠️TRIAGE (Medium).
- **Problem.** `terraform/modules/eks/main.tf:243-247` sets `http_put_response_hop_limit = 2`,
  letting a container reach node IMDSv2 and assume the node role (ECR/SSM/CNI) — undermining
  the IRSA isolation the secrets design depends on. Pods use IRSA, not IMDS.
- **Change.** Set `http_put_response_hop_limit = 1` on the node LT (runner can stay 2 — no
  pods). **Files.** `terraform/modules/eks/main.tf`.

### H22 — Remove the global `RPC_TLS_INSECURE` TLS-disable footgun from the prod path
- **Source.** App #6 + Bash #9. ✅VERIFIED.
- **Problem.** `app/web/scripts/start.sh:31-33` sets `NODE_TLS_REJECT_UNAUTHORIZED=0`
  process-wide (also `listener/index.mjs:133`, `lib/provider.mjs:28-30`) when
  `RPC_TLS_INSECURE=true`, disabling cert verification for the whole Node process while it
  sends the app JWT and broadcasts signed txs → MITM. It defaults false but is a live env-flip
  in the shipped `.env` with no prod guard.
- **Change.** Remove the global-disable path (rely on the scoped `NODE_EXTRA_CA_CERTS`), or
  hard-fail startup if `RPC_TLS_INSECURE=true` while an `env=prod` marker is set; never emit it
  in a prod `.env`. **Files.** `app/web/scripts/start.sh`, `app/web/listener/index.mjs`, `app/web/lib/provider.mjs`, `app/scripts/gen-app-identity.sh`.

### H23 — Scope `--host-allowlist` and `--rpc-http-cors-origins` (drop the `*`)
- **Source.** Helm #8 + App #7. ✅VERIFIED.
- **Problem.** `--host-allowlist=*` (`statefulset.yaml:216`, `values.yaml:105,132,155`) disables
  Besu's DNS-rebinding protection on all listeners, and `--rpc-http-cors-origins=*`
  (`statefulset.yaml:243,271,311,326`) allows any origin — on the app-rpc (server-TLS+JWT),
  explorer (no auth), and ops listeners that lack mTLS's browser barrier.
- **Change.** Pin `host-allowlist` to the actual service DNS/SANs per pool; scope CORS to the
  known app origin on the app pool and drop it entirely on server-to-server pools. Make these
  values, not hardcoded `*`. **Files.** `helm/charts/besu-node/templates/statefulset.yaml`, `values.yaml`.

### H24 — Serialize signer writes (nonce) and add RPC/tx timeouts
- **Source.** App #4. ⚠️TRIAGE (Medium).
- **Problem.** Each POST builds a fresh Wallet+provider and auto-fetches the nonce
  (`app/web/lib/provider.mjs:40-43`, `api/value/route.js:46-47`); two concurrent `set()`s grab
  the same nonce → one write silently lost. `tx.wait()` and the `FetchRequest` have no timeout
  → a chain stall hangs the HTTP request indefinitely.
- **Change.** Serialize writes through a single submitter with a managed nonce (mutex/queue);
  set a `FetchRequest` timeout and a bounded `tx.wait(confirms, timeoutMs)` returning 5xx on
  timeout. **Files.** `app/web/lib/provider.mjs`, `app/web/src/app/api/value/route.js`.

### H25 — Make contract deployment idempotent + persist the address durably
- **Source.** App #5. ⚠️TRIAGE (Medium).
- **Problem.** `app/scripts/app-ec2-bootstrap.sh:58-74` redeploys a new Storage whenever
  `CONTRACT_ADDRESS` is the zero address and writes the real address only to the EC2-local
  `.env`; the durable app-env secret still says `0x000…`. Instance replacement → a new empty
  contract at a new address; prior value + `ValueChanged` history orphaned; the listener
  backfills an empty history.
- **Change.** After deploy, persist `CONTRACT_ADDRESS`/`DEPLOY_BLOCK` back to the app-env secret
  or an SSM parameter and prefer it on boot; or make contract deploy a one-time explicit step.
  **Files.** `app/scripts/app-ec2-bootstrap.sh`, `app/web/scripts/deploy-contract.mjs`, `app/scripts/push-app-env.sh`.

### H26 — Fix `full-delete.sh`: release EIPs, require region, close the VPC/IGW/IAM gap
- **Source.** Bash #6 + #11. ⚠️TRIAGE (Medium).
- **Problem.** The "release EIPs" section (`scripts/maintenance/full-delete.sh:93-96`) deletes
  NAT gateways only — no `release-address` anywhere → unassociated EIPs keep billing; VPC/SG/
  IGW/IAM are left (acknowledged, lines 137-138). `AWS_REGION` defaults to `us-east-1`
  (`common.sh:9`), so forgetting to export it runs the irreversible nuke against the wrong
  region (dry-run mitigates). `DG` is interpolated unvalidated into a JMESPath string
  (`:110-111`).
- **Change.** After NAT deletion, `describe-addresses` filtered by the DeletionGroup tag and
  `release-address` each; add EIPs to the leftover report; require an explicit `AWS_REGION` (no
  silent default) for this script; validate `DG` against `^[A-Za-z0-9._-]+$`. **Files.**
  `scripts/maintenance/full-delete.sh`, `scripts/lib/common.sh`.
- **Decision (2026-07-06, human): `full-delete.sh` is a DEPLOY-TEST-ONLY teardown backstop and must
  NOT be part of / runnable against the production account.** So the control here is not the
  cgpt-style prod-hardening of the script but an explicit **account+region denial guard**: it
  refuses to run unless `AWS_ACCOUNT_ID`/`AWS_REGION` match the designated deploy-test account, and
  it is excluded from any prod deploy bundle (cross-ref C9 test-only-artifact audit). The EIP /
  region / `DG` fixes above still apply — the script stays in use for deploy-test teardown.

### H27 — Namespace Secrets Manager names + tighten IRSA so deployments can't read each other's keys
- **Source.** TF #10. ⚠️TRIAGE (Medium).
- **Problem.** Node-key etc. secrets have static names (`besu-node-validator-1`,
  `besu-ca-private-key`, `secrets/main.tf:42-309`) and the pod IRSA is scoped to `besu-node-*`
  (`terraform/main.tf:22`). Two deployments in one account/region collide, and deployment A's
  pods could `GetSecretValue` on deployment B's node keys — the KMS *alias* was prefixed
  (`kms.tf:60-63`) but the secrets were not.
- **Change.** Prefix secret names with `name_prefix`/`deletion_group` and tighten
  `secrets_arn_prefix` to that prefix. **Files.** `terraform/modules/secrets/main.tf`, `terraform/main.tf`.

---

## P3 — Low (hygiene, grouped)

### H28 — App API hygiene
- **Source.** App #8/#9/#10. Return generic errors to clients (log detail server-side with a
  correlation id) instead of raw ethers/RPC strings (`api/value/route.js:25,54`,
  `api/events/route.js:21`); cap request-body size + add rate limiting on `/api/value`
  (`route.js:32`); enforce `0 <= v <= 2^256-1` and reject non-string/number `body.value`
  (`route.js:36-44`); bound/rotate the listener `seen` Set in lockstep with the 500-entry
  `events` buffer (`listener/index.mjs:31,44,54`). **Files.** `app/web/src/app/api/*`, `app/web/listener/index.mjs`.

### H29 — Consistent allowlist address case-normalization
- **Source.** Bash #7. `add-account.sh:29-31` preserves input case and `cm_write` does a
  case-sensitive `sort -u` (`_perm-lib.sh:67-81`), while `remove-account.sh:24-28` lowercases —
  so a checksummed add can create a duplicate entry and may not match the lowercase `from` of a
  signed tx. Lowercase every address once at ingestion in `cm_write` before dedup/sort.
  **Files.** `scripts/permissioning/{_perm-lib.sh,add-account.sh}`.

### H30 — NLB observability + SG scoping
- **Source.** TF #16/#17. Enable `access_logs` + `enable_deletion_protection` on the SWIFT/app
  NLBs (`rpc-access/main.tf:153-164,270-283`); move the NLB→pod ingress off the shared cluster
  SG (`:171-181,286-296`) onto a dedicated RPC-pod SG. **Files.** `terraform/modules/rpc-access/main.tf`.

### H31 — Enforce a real Grafana admin password
- **Source.** TF #9. `grafana_admin_password` defaults to `""` (`variables.tf:656-661`) → the
  chart falls back to the well-known `prom-operator`. Validate non-empty + min length, or source
  from Secrets Manager; fail the plan if empty in prod. **Files.** `terraform/variables.tf`, `terraform/modules/observability/main.tf`.

### H32 — Script robustness nits
- **Source.** Bash #8/#11. Extract the deploy-config tar with `--no-same-owner
  --no-same-permissions` + validate members against an expected-path allowlist
  (`scripts/runner/fetch-deploy-config.sh:30`); make `sm_get` distinguish "not found" from "call
  failed" and reject a `None`/empty payload (`common.sh:20-23`); poll the local port for
  readiness instead of a fixed `sleep 3` before curl/cast (`_perm-lib.sh:141` — **DONE** via H3's
  `perm_rpc` port-readiness poll; `fund-account.sh:69-72` still pending); log/assert the CSR subject
  in `sign-client-csr.sh` before signing.
  **Files.** `scripts/runner/fetch-deploy-config.sh`, `scripts/lib/common.sh`, `scripts/permissioning/*`, `scripts/access/sign-client-csr.sh`.

### H33 — Consensus alerting + doc/comment correctness
- **Source.** Helm #10 + TF #13/#18 + Bash #10. Add PrometheusRule alerts for validator-set
  size / signer participation / round-change rate and raise the `peer_count < 2` threshold
  (`besu-monitoring/templates/prometheusrule.yaml:27-32`); fix the genesis "post-install hook"
  comment (there is no hook, `besu-genesis/templates/job.yaml:17` — **DONE** via H2's comment
  rewrite); align the stale comments in
  `gen-app-identity.sh:12-13,39-40` (it *does* write `app-identity.tfvars`) and the
  `enable_kms_data_events`/`dynamodb_table` example drift (`primary.tfvars.example`,
  `variables.tf:469`); add the app UI ALB HTTPS listener if the app is ever promoted
  (`app/infra/main.tf:284-320`). **Files.** as listed.

---

## Penetration-testing plan (theme #2) — validate on a mock deploy of `feature/c6-c12-combined`

The mock deployment is optional but is the right way to *confirm* the highest-severity findings
rather than reason about them. Follow the standing prod-testing practice ($15/run, same-day
teardown). Attempt, from an in-VPC test pod / the runner:

1. **In-cluster privileged RPC (H6):** from a non-ops pod, call `qbft_proposeValidatorVote`,
   `perm_getAccountsAllowlist`, `debug_traceTransaction` against the ops/explorer ClusterIP
   Services. *Expected today: reachable (finding stands). After H6: blocked by NetworkPolicy.*
2. **App tx-submission without auth (H4):** from another ENI in the app VPC, `POST /api/value`;
   and simulate a `text/plain` CSRF POST. *Expected today: tx mines.*
3. **Permissioning revocation drift (H3):** `remove-account.sh … PROPAGATE=hot` a sender, then
   submit a tx from it to a validator. *Expected today: tx still mines (silent failure).*
4. **mTLS trust breadth (H9):** present a client cert signed by the infra CA but *not* SWIFT's
   to the SWIFT NLB. *Expected today: accepted.*
5. **Upgrade blast radius (H1) — SAFE variant:** on the mock, `terraform plan` a `besu_version`
   bump and a `app_rpc_count` 0→N change; confirm the plan shows all 4 validator releases
   changing. *Do not apply the halting version on a chain you care about; the plan alone proves it.*
6. **IMDS pivot (H21):** from a test pod, curl `169.254.169.254` (IMDSv2) and try to read node
   role creds. *Expected today: reachable at hop-limit 2.*
7. **Secrets on argv (H17):** while `fund-account.sh` runs, `cat /proc/<pid>/cmdline` from
   another shell. *Expected today: faucet key visible.*

Capture each result in a new `docs/pentest-run-<date>.md` (mirroring the deploy-run logs) and
flip the corresponding H-item's status once fixed + re-tested.

---

## Follow-up additions (H34–H39) — from the cross-review with the cgpt audit brief (2026-07-06)

> After cross-reviewing `docs/production-handling-backlog-cgpt.md`, the human ruled on each
> candidate. **Added below:** H34 (backup/restore), H35 (fork-detection probe), H36 (validator
> QoS/shutdown), H37 (image digest-pinning), H38 (branch protection + CI), H39 (secret scan +
> PAT rotation). **Handled outside this doc:** Terraform-state / CA custody — the human applies a
> **custom production CA manually** (no task, no change from here). **Reframed, not added as
> hardening:** `full-delete.sh` — deploy-test-only, kept out of prod (see the decision note on H26).
> The cgpt doc's audit-program apparatus (threat-model doc, 16 deliverables, definition-of-done)
> is intentionally NOT folded in — see "Where I'd push back" in the review.

| ID | Title | Sev | Themes | When |
|----|-------|-----|--------|------|
| **H34** | In-region backup / restore + tested recovery (chain data + validator/CA keys) | **High** | 4,5 | Later (backlog) |
| **H35** | Automated chain-integrity / fork-detection probe | **Medium** | 4,5 | Add |
| **H36** | Validator graceful shutdown + Guaranteed QoS + PriorityClass | **Medium** | 4,5 | Add |
| **H37** | Pin container images by digest + SBOM + signature verification | **Medium** | 1,6 | Later (backlog) |
| **H38** | Branch protection + plan-safety CI gate (enforcement backstop for H1/H2) | **Medium** | 3,5,6 | Later (backlog) |
| **H39** | Full-history secret scan + rotate the runner PAT | **High** | 1 | Rotate now; scan quick |

### H34 — In-region backup, restore, and tested recovery (chain data + validator/CA keys)
- **Source.** cgpt H-12 / §7.3. Human: add to backlog, address later.
- **Problem.** No backup/restore story for a financial ledger. DR removal took out cross-region
  *failover*, not in-region *recoverability*. Two traps: (a) an online EBS snapshot of a **live
  RocksDB** is not application-consistent, so "we have EBS snapshots" is a false backup; (b)
  validator/CA keys have no tested recovery path.
- **Change.** Encrypted, access-controlled, audited validator + CA key backup with a
  **restore-to-clean-environment test** that never exposes key material; a documented + tested
  node-recovery path (rebuild a non-validator from peers; restore/rebuild a validator from
  genesis + peer-sync; recover Terraform state); a consistent chain-data backup method (quiesced /
  synced snapshot or a Besu export, not a raw live snapshot); document the accepted **RPO/RTO** and
  the business owner who accepts single-region risk.
- **Acceptance.** [ ] One clean recovery proven in a mock for each of {non-validator rebuild,
  validator restore, Terraform-state recovery}. [ ] RPO/RTO documented + signed off.
- **Files.** new `docs/audit/data-integrity-and-recovery-runbook.md` (or guide §recovery),
  `scripts/maintenance/`, key-backup tooling.

### H35 — Automated chain-integrity / fork-detection probe
- **Source.** cgpt §7.5 / §11. Human: add.
- **Problem.** Readiness is P2-socket only (H15), so a forked / divergent-head / mismatched-genesis
  node reports Ready while the ledger diverges. No cross-node consistency check exists.
- **Change.** A probe (in-cluster CronJob via pod IRSA, or a Lambda) that queries ≥2 validators + an
  RPC node and compares **chain-id, genesis block hash, validator set, latest + finalized block
  number/hash, peer count, sync status**; it **alerts (via the existing SNS→email) and fails when
  nodes disagree even if all pods are "Ready."** Wire into observability alongside H33's alerts.
- **Acceptance.** [ ] Injecting a divergent / halted node raises an alert though pods stay Ready.
- **Files.** new probe (module or `helm/charts/besu-monitoring`) + PrometheusRule; docs.

### H36 — Validator graceful shutdown + Guaranteed QoS + PriorityClass
- **Source.** Helm audit finding #9 (dropped when consolidating H1–H33) + cgpt H-07. Human: add.
- **Problem.** Validators are **Burstable** (`helm/charts/besu-node/values.yaml:175-177`: cpu req
  250m, mem req 1Gi / limit 4Gi, no cpu limit), with **no `terminationGracePeriodSeconds` / `preStop`**
  and **no `priorityClassName`** (`statefulset.yaml`). Under cluster memory pressure the kubelet can
  OOM-kill / evict **more than one validator at once → quorum loss**, and an abrupt SIGKILL can leave
  RocksDB mid-write.
- **Change.** Set validator memory `requests == limits` (Guaranteed QoS), sized from a load test; add
  a `PriorityClass` so validators aren't first-evicted; add a `terminationGracePeriodSeconds`
  generous enough for a clean Besu / RocksDB flush (Besu handles SIGTERM) + optional `preStop`.
- **Acceptance.** [ ] Validators show QoS `Guaranteed`; a memory-pressure test evicts non-validators
  first and never >1 validator; shutdown flushes cleanly.
- **Files.** `helm/charts/besu-node/{values.yaml, templates/statefulset.yaml}`, new PriorityClass.

### H37 — Pin container images by digest + SBOM + signature verification
- **Source.** cgpt H-08 / §5.7. Human: add to backlog.
- **Problem.** Besu / tools / Blockscout / Postgres images are **tag-pinned** (e.g.
  `hyperledger/besu:26.6.1`), not digest-pinned; no SBOM, no provenance/signature check. A retagged
  upstream image silently changes what runs under the same tag — violates §6's "PIN explicitly".
- **Change.** Resolve each image tag to an immutable `@sha256:` digest and pin it; generate CycloneDX
  / SPDX **SBOMs** stored with release evidence; verify signatures/provenance with **cosign** where
  available; scan with Trivy/Grype and gate critical/high (time-bounded signed exceptions only).
- **Acceptance.** [ ] All workload images reference digests; SBOM produced; scan clean or exception.
- **Files.** Helm values (image fields), CI (H38), docs.

### H38 — Branch protection + a plan-safety CI gate (enforcement backstop for H1/H2)
- **Source.** cgpt H-10 / §12 (narrow slice only). Human: add to backlog, implement later — plans to
  use **Octopus Deploy** in future.
- **Problem.** The H1/H2 guardrails are code + doc, but nothing prevents a regression or an unsafe
  merge/apply; no branch protection, no required checks (CLAUDE.md §3 already forbids pushing without
  confirmation, but that's operator discipline, not enforcement).
- **Change (minimum — NOT the full audit-CI program).** Branch protection on `master`/`prod` (no
  direct/force push; required review via **CODEOWNERS** on `terraform/`, `helm/`,
  `scripts/maintenance/`, `scripts/permissioning/`, PKI/IAM/KMS/genesis paths); **one** required CI
  check running `terraform fmt/validate` + `helm lint/template` + `shellcheck`, plus a **plan
  assertion that no apply changes >1 validator image / pod-template at once** (the automated backstop
  behind H1/H2); OIDC short-lived AWS creds, never long-lived keys. When **Octopus Deploy** is
  adopted, enforce the same gates in the pipeline (approvals, plan-artifact review, serialized
  concurrency, a post-deploy H35 chain-integrity check).
- **Acceptance.** [ ] A PR that would restart >1 validator fails the check. [ ] Force-push to
  `prod`/`master` is blocked.
- **Files.** new `.github/workflows/*`, `CODEOWNERS`, branch-protection settings; later, the Octopus pipeline.

### H39 — Full-history secret scan + rotate the runner PAT
- **Source.** cgpt §5.1 + the known PAT exposure. Human asked for a recommendation → captured here.
- **Preliminary scan done (2026-07-06).** A full-history scan (154 commits, all refs) found **no real
  secret committed** — the only PAT-pattern hit is the deliberate fake
  `github_pat_DEAD_TOKEN_FOR_FAILCASE_TEST` in a deploy-run log; no PEM/EC/RSA keys, no AWS access
  keys, no raw `0x`+64-hex signer keys; `.gitignore` correctly excludes `*.tfstate*`, prod tfvars,
  app `.env`, `app-identity.tfvars`, `*.pem`, `*.p12`, `app/.identity/`. So **no history rewrite is
  needed.** The exposure is *operational*, not a git leak: the runner PAT lives in the local
  gitignored `primary.tfvars`, is embedded in `git clone` URLs, pushed to Secrets Manager, and (per
  **H18**) can echo into cloud-init/console logs on a clone error.
- **Change (recommendation).**
  1. **Rotate the PAT now, regardless** — revoke the classic PAT in GitHub and issue a **fine-grained
     token scoped to only this repo with `contents:read`** and a short expiry; keep it only in
     Secrets Manager (already the delivery path); land **H18** so it can't leak on a clone error.
     Confirm the repo is private; if it was ever public, treat the token as fully compromised.
  2. **Institutionalise the scan** — add `gitleaks detect --log-opts=--all` (and/or
     `trufflehog git file://.`) as a **pre-commit hook + the H38 CI gate**, covering PATs, PEM keys,
     PKCS12/JKS, tfstate, join packs, and `0x`+64-hex signer keys, so history stays clean going forward.
- **Acceptance.** [ ] PAT rotated to a fine-grained read-only token. [ ] gitleaks wired into
  pre-commit + CI. [ ] a documented one-line scan command in the runbook.
- **Files.** token rotation (ops), new `.gitleaks.toml` + pre-commit config, CI (H38), guide runbook.

---

## Suggested execution order

1. **P0 first (H1→H4).** H1 and H2 are the enforcement gaps behind every "a routine apply broke
   the chain" scenario — fixing them (ignore_changes + OnDelete + genesis guard) closes the
   largest blast radius. H3 fixes a *silent security failure* in the just-shipped C6. H4 is the
   only unauthenticated tx path.
2. **P1 privilege/exposure (H5,H6,H7,H8,H9)** — these are exploitable, not nits; cheap relative
   to impact. Then the upgrade-safety pair **H10,H11** and the input-validation sweep **H12**.
3. **P2** as a hardening pass before go-live; **P3** as cleanup.
4. Run the **pentest plan** on a mock deploy after P0+P1 land, to confirm the fixes and catch
   anything the static audit missed. Re-log findings and update statuses.

> These tasks are additive to and independent of C1–C12. **P0 (H1–H4) + P1 (H5–H12) + P2 (H13–H27)
> are implemented** (2026-07-06, branch `feature/production-hardening`) and a chain-only mock on
> **2026-07-11 LIVE-CONFIRMED H1/H2/H3/H5/H6/H7/H10/H12/H13/H14/H19/H21/H26 + the C10 gate** (FULL PASS,
> `docs/prod-deploy-run-2026-07-11-hardening.md`); the rest remain statically-validated / deferred
> (app-layer H4/H8/H22/H24/H25, H9-pin, H15, H16, H17 partial, H18, H20, H27; several CMK/deletion-
> protection controls ship parameterized default-off — see the per-item notes); **P3 (H28–H39) remains.**
> **The H5 residual (permissions boundary) landed 2026-08-10** and needs apply-validation on the next
> mock. Produced by the 2026-07-06 whole-codebase audit.

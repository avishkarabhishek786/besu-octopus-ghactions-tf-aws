# App-layer deployment backlog (C1–C12)

> **Purpose.** Single ready-to-execute reference for the code/design work that the
> 2026-06-28 deploy-test surfaced (findings F1–F13; the log and the chain docs it
> refers to live in the frozen `besu-aws` reference repo — see `docs/README.md`).
> This backlog is the **app-layer + structural** work, and it is the C-series the
> code's `(C…)` comments cite. Each item lists the source finding, the problem, the change, acceptance
> criteria, and files touched.
>
> **Standing context (2026-06-28):** testing now runs against **prod** (step-by-step prod
> process), **$15/run budget, same-day teardown**, **non-prod archived**. The
> no-hardcoding rule applies to every change here.

> **BUILD STATUS (2026-06-29, prod deploy-tests #3 + #4 — app layer NOW VERIFIED end-to-end).**
> Live-verified in run #4 (`prod-deploy-run-2026-06-29b.md`): **F15/F16** runner code+config
> delivery (GitHub token + deploy-config in Secrets Manager; runner self-clones at boot).
> **C2** — `gen-app-identity.sh --env prod` writes `app/web/.env` **and** `app-identity.tfvars`
> with `genesis_funded_accounts` (**F20** — the signer needs a genesis balance even with
> permissioning off; run it BEFORE the chain apply). **C3** — `app/infra/prod.tfvars(.example)`.
> **C5** — app EC2 self-bootstrap (`app/scripts/{push-app-env,app-ec2-bootstrap}.sh`, app-env
> secret, prebuilt `app/web/contract/Storage.json`); the bootstrap normalises the `.env`
> trailing newline (**F18**). **C1** (runner own state) DONE.
>
> **Three findings fixed + verified this round (commit `ac0478d`):**
> - **F18** — `.env` trailing-newline: `aws secretsmanager … --output text` strips the trailing
>   `\n`, so `echo VAR=val >> .env` concatenated onto the prior line and corrupted
>   `NODE_EXTRA_CA_CERTS` → `SELF_SIGNED_CERT_IN_CHAIN`. Fix: `ensure_nl` in `app-ec2-bootstrap.sh`.
> - **F19** — late-booting TLS pools (app-rpc/SWIFT) are permanently rejected: Besu node
>   permissioning resolves the allowlist enode DNS once, at node startup. Fix (sequence): issue
>   the app-rpc/SWIFT certs + push the JWT BETWEEN the AWS-layer apply and the in-cluster apply.
> - **F20** — unfunded signer on the zero-gas chain → its tx never mines. Fix: new
>   `genesis_funded_accounts` var (decoupled from permissioning) → `app-identity.tfvars`.
>   **This supersedes C4's "re-genesis to seed the app EOA" concern** — funding is now a clean
>   genesis var applied with the chain, no in-place re-genesis needed.
>
> Still OPEN: **C4** (re-genesis safety — largely moot; funding now via `genesis_funded_accounts`),
> **C6** (file-based account permissioning — since PROD-VERIFIED 2026-07-05, see the C6 section),
> and including the **SWIFT rpc-pool cert**
> (`issue-server-cert.sh`) in a future test so `rpc-1/2` also come up (scoped out in both runs).

---

## C1 — Move the runner into its own Terraform root/state  ✅ DONE (2026-06-28)
- **Source:** F5.
- **Problem:** the runner lived in the chain's state, gated by `deploy_runner`; *every*
  runner-side apply had to pass `-var deploy_runner=true` (after `-var-file`, F4) or it
  destroyed the runner mid-apply (F5).
- **Done:** new **`terraform/runner/`** root with its **own state** (`besu/prod/runner.tfstate`),
  mirroring `app/infra`. It reads the chain outputs (`name_prefix`, `vpc_id`,
  `private_subnet_ids`, `eks_cluster_name`, `eks_node_security_group_id`, the runner secret
  names + `runner_repo_url`) via `terraform_remote_state` and instantiates `modules/runner`.
  Removed `module.runner`, `var.deploy_runner`, `var.runner_instance_type`, and the
  `runner_ssm_command` output from the chain root; added chain outputs
  `eks_node_security_group_id`, `name_prefix`, `project_name`. The two bootstrap SECRETS
  (token + deploy-config) stay in the chain state (AWS-layer, shared with the app EC2).
- **Acceptance:** ✅ runner root validates + applies/destroys independently; ✅ chain apply no
  longer plans the runner; ✅ in-cluster apply drops `-var deploy_runner=true`; ✅ docs 01 §3
  Phase 3/4 + CLAUDE.md §3 updated; teardown order documented (runner first).
- **Files:** new `terraform/runner/{main,variables,outputs,backend,versions}.tf`;
  `terraform/{main,variables,outputs}.tf`; `environments/prod/primary.tfvars`; doc 01 §3; CLAUDE.md §3.

---

## C2 — Prod app-identity flow + the prod identity MODEL
- **Source:** F7 (+ resolves the "how do future dApps work" question).
- **Problem:** `app/scripts/gen-app-identity.sh` is hardcoded to **non-prod** paths; there's
  no prod app-identity flow. Deeper: **Option A** (app signer = admin = sole allowlist
  entry) is a throwaway shortcut that does **not** generalize to multiple dApps.
- **The resolved model (build this, not Option A):**
  - **Genesis seeds exactly ONE thing: a durable, managed ADMIN account** (the on-chain
    account-permissioning contract owner). Its key lives in **KMS / Secrets Manager**, never
    in the repo. This is the only identity that must exist at the chain's **first** genesis.
  - **Each dApp has its OWN signer EOA**, generated independently and **added to the
    allowlist at RUNTIME** by the admin via `scripts/permissioning/add-account.sh`
    (`addAccountsToAllowlist`). **No re-genesis** — that is the whole point of
    `account_permissioning_mode = onchain`.
  - **Option A is explicitly test-only** and must not be used for real dApps (signer ≠ admin).
- **Change:**
  - Parameterize `gen-app-identity.sh` by env (e.g. `ENV=prod`) → writes
    `environments/prod/app-identity.tfvars` + the prod `.env`. (Post-archive, prod is the default target.)
  - Implement/confirm the **account-ingress contract deploy + bind** to genesis
    `permissioning` config (the one-time setup `add-account.sh` depends on).
  - Document the per-dApp runtime onboarding flow (generate signer → admin `add-account`).
- **Acceptance:**
  - [ ] A new dApp can be onboarded **with no chain restart / no re-genesis** (admin adds its signer at runtime).
  - [ ] Admin key is in KMS/Secrets Manager; no signer/admin private key in the repo.
  - [ ] `gen-app-identity.sh` targets prod; Option-A path is labeled test-only.
- **Files:** `app/scripts/gen-app-identity.sh`; account-ingress contract + genesis
  `permissioning` wiring; `scripts/permissioning/` (add a `remove-account.sh`/`list` if useful); doc 03.

### C2a — Clean the prod tfvars admin/allowlist (immediate)
- **Source:** F8.
- **Problem:** `environments/prod/primary.tfvars` `permissioning_admin_account` +
  `initial_account_allowlist` are **leftover LOAD-TEST "spam" addresses** with no managed
  keys — yet they *are* prod's entire allowed-sender set (deny-by-default).
- **Change:** replace with the intentional managed **admin** (from C2) and a minimal,
  intentional initial allowlist (or clearly-marked placeholders). Remove the
  "# LOAD-TEST: 5 senders for parallel spam" set.
- **Acceptance:** [ ] prod tfvars carries only intentional, key-managed accounts.
- **Files:** `terraform/environments/prod/primary.tfvars`.

---

## C3 — `app/infra` per-environment tfvars
- **Source:** F9 + F13.
- **Problem:** `app/infra` defaults are **non-prod-baked** (`project_name=besu-aws-nonprod`,
  `chain_state_key=besu/non-prod/main.tfstate`, `deletion_group=nonprod-app-test`), and two
  required vars have **no var-file/example** (`chain_state_bucket`, `owner`). Doc 03 §3
  Step 5 (`terraform apply`) targets the wrong chain or fails outright.
- **Change:** add `app/infra/env/prod.tfvars` (and keep an archived non-prod copy for
  reference) carrying **every** value: chain state bucket/key/region, project_name,
  deletion_group, region, owner, app VPC CIDR. Remove environment-baked defaults.
- **Acceptance:**
  - [ ] `cd app/infra && terraform init -backend-config=... && terraform apply -var-file=env/prod.tfvars` works with **nothing hardcoded, nothing missing**.
  - [ ] No non-prod default remains in `app/infra/variables.tf`.
- **Files:** `app/infra/variables.tf`, new `app/infra/env/prod.tfvars`; doc 03 §3 Step 5.

---

## C4 — Make the genesis Job build extraData from PROVIDED validator keys  ✅ IMPLEMENTED (2026-06-29, pending live verify in the rehearsal)
- **Source:** F10.
- **Problem:** the genesis Job always regenerated fresh validator keys and built
  `extraData`/enodes from them, but `put_key` (`skipExistingKeys: true`) kept the **provided**
  keys in Secrets Manager → `extraData` referenced addresses the validator pods don't have →
  **broken consensus** when `use_provided_validator_keys=true`.
- **Change (DONE):** when `use_provided_validator_keys=true`, a new **`fetch-provided-keys`**
  init container (tools image) pulls the supplied validator keys from Secrets Manager into
  `/work/provided/`; the **`generate`** container then rebuilds the validator key set from them
  (`besu public-key export` + `export-address`), recomputes the QBFT extraData
  (`besu rlp encode --type=QBFT_EXTRA_DATA`, validators sorted ascending) and patches it into
  `genesis.json` (`jq '.extraData=…'`). The random-gen path (`use_provided_validator_keys=false`)
  is **unchanged**. Wired: `providedValidatorKeys` chart value ← `var.use_provided_validator_keys`
  (root → `module.besu` → genesis release). Validated: `terraform validate`, `helm lint`,
  `helm template` (renders only when true; default path untouched).
- **Acceptance:**
  - [x] Code: provided keys drive `extraData`; default path unchanged; validate/lint pass.
  - [ ] **Live (rehearsal):** with provided keys, all 4 validators produce blocks (validator set matches).
  - [ ] A guarded `force_regenesis` / re-genesis-on-existing-chain path (the *re-run* safety half of
        F10 — wipe node-key secrets **and** PVCs together) — still **OPEN** as a follow-up; C4 here
        covers the provided-keys consistency, not the in-place re-genesis reset.
- **Files (touched):** `helm/charts/besu-genesis/templates/job.yaml`, `values.yaml`;
  `terraform/{variables.tf,main.tf,modules/besu/{variables,main}.tf}`.

---

## C5 — Secure app-deploy delivery to the app EC2
- **Source:** F11.
- **Problem:** the app EC2 installs only node/git; "app code + `.env` delivered via SSM by
  the Phase-6 deploy step" but **no step does it**. The `.env` carries the **signer key**, so
  it can't be `git clone`d (gitignored) nor baked into the AMI.
- **Change:** document + implement the app-deploy step:
  1. `git clone` the app code on the EC2 (committed).
  2. **Fetch the signer + JWT keys from Secrets Manager** via the EC2 instance role to
     assemble `.env` locally — never via SSM-command logs or the AMI/user-data.
  3. `forge` deploy the contract; write `CONTRACT_ADDRESS` into `.env`.
  4. `./scripts/start.sh`.
- **Acceptance:**
  - [ ] App comes up on the EC2 with the signer key **only** sourced from Secrets Manager.
  - [ ] No private key appears in user-data, AMI, or SSM command history.
  - [ ] Reachable via the documented SSM port-forward; `set()`/events work end-to-end.
- **Files:** `app/infra/main.tf` (EC2 role read-policy + user-data), new
  `app/web/scripts/deploy.sh` (or similar); doc 03 §3 Steps 6–8.

---

## C6 — Account permissioning  ✅ PROD-VERIFIED file-based (2026-07-05)
> **STATUS 2026-07-05:** the file-based redesign below is **built AND prod-verified** in the
> combined C6+C12 deploy-test (`docs/prod-deploy-run-2026-07-05-c6c12.md`, branch
> `feature/c6-c12-combined`): a non-allowlisted sender is rejected, an allowlisted one mines,
> and add/remove onboarding works end-to-end (restart-based path). F32/F32b (allowlist file
> must be writable + besu-owned) were found and fixed in that run — build-config now copies
> the ConfigMap to `/data/permissions_accounts.toml`. Default stays
> `account_permissioning_mode="off"` (opt-in; prod tfvars set `"local"`).
>
> **What was built** (diverges from the original sketch in two deliberate ways):
> - **Model B, ConfigMap source of truth** (decided with the human): the allowlist is the
>   `besu-account-allowlist` ConfigMap (genesis chart, seeded from admin + initial_account_allowlist),
>   mounted read-only into each enforcing pod's **build-config init container, which copies it to a
>   writable, besu-owned `/data/permissions_accounts.toml`** (F32/F32b) — NOT the RPC-write-back
>   model (A), which our regenerate-on-boot init container would wipe.
> - **Separate file** `/config/perm-accounts/permissions_accounts.toml` for `accounts-allowlist`
>   (its own ConfigMap), distinct from the PVC `/data/permissions_config.toml` that holds the
>   dynamically-assembled `nodes-allowlist`. Besu's two `--permissions-*-config-file` flags are
>   independent, so this is clean.
> - **Enforce on all tx-accepting nodes**; **render-time preflight** blocks enabling `local` with an
>   empty seed; **PERM** exposed only on the internal ops listener (never the SWIFT/app edge).
> - **Onboarding tooling:** `scripts/permissioning/{add,remove,list}-account.sh` + `reload-permissions.sh`
>   (patch the ConfigMap → rolling restart [default, validators one-at-a-time under the quorum gate]
>   or hot reconcile via `perm_add/removeAccountsToAllowlist` + read-back — H3 replaced the original
>   `perm_reloadPermissionsFromFile` hot path, which was a silent no-op; the pentest fix added the
>   `require_full_validator_set` cross-check so revocation can't fail open). Docs: 02 §2.5 + the guide runbook.
> - **Residual risk (auditor line):** file-based enforcement is node-local, not consensus/Byzantine —
>   acceptable because we own all validators; no stronger option on 26.6.1.
>
> **DoD MET (2026-07-05):** the prod deploy-test with `account_permissioning_mode="local"` + a
> seeded admin verified all three gates — non-allowlisted sender rejected, allowlisted sender
> mines, add/remove onboarding works end-to-end (`docs/prod-deploy-run-2026-07-05-c6c12.md`).
> The mode is set in the prod tfvars.

> **History:** C6 was FIRST built (2026-06-28, branch `c6-account-permissioning`) as **on-chain/contract**
> account permissioning and merged to master. The **2026-06-28 prod deploy-test #2 proved it
> cannot run (F17)** — every validator/bootnode crash-looped on `Unknown options:
> --permissions-accounts-contract-*`. **Besu REMOVED smart-contract permissioning in 25.6.0**
> (CHANGELOG 25.6.0, PR hyperledger/besu#8597; LF blog "Sunsetting Tessera and Simplifying Besu").
> Our pinned **26.6.1** supports ONLY file-based permissioning.

**Resolution applied (so the chain runs):** `account_permissioning_mode` now defaults to **`"off"`**
(validated set `off|local|onchain`; prod tfvars set to `off`). The contract artifacts
(`permissioning/src/AccountAllowlist.sol`, `files/account-allowlist.runtime.hex`, the genesis
predeploy, the node flags, `add-account.sh`/`bootstrap-allowlist.sh`) are kept as a **disabled
tombstone**; `accountMode=onchain` is documented BROKEN in the chart + variable comments. Node
permissioning (`node_permissioning_mode="local"`, file-based) is unaffected and works.

**The redesign (IMPLEMENTED 2026-07-05, see the status banner above) — file-based account
permissioning.** Verified against the Besu 26.6.1 source (tag `26.6.1` = commit `983c53fb`).
NB: the "same file / model (A) or (B)" notes below are the original sketch; the built version uses a
**separate** ConfigMap file and **Model B (reload)** — see the banner for the as-built decisions:
- **Flags exist:** `--permissions-accounts-config-file-enabled` + `--permissions-accounts-config-file`
  (`app/.../cli/options/PermissionsOptions.java`). No `*-contract-*` flags remain.
- **Implementation:** in the besu-node init container, also write `accounts-allowlist=[<admin>,<initial>]`
  into the SAME `/data/permissions_config.toml` that already holds `nodes-allowlist` (one file, both
  keys). Switch the node flags from contract → config-file when `accountMode="local"`.
- **Runtime onboarding (no re-genesis) — pick ONE model per node (mutually exclusive):**
  - **(A) RPC mutators** `perm_addAccountsToAllowlist` / `perm_removeAccountsFromAllowlist` (enable
    `PERM` API). **Persists** to the file (survives restart — `AllowlistPersistor.updateConfig` →
    `Files.write`) and **verifies file==state** (file must be WRITABLE; no out-of-band edits, or it
    throws `ERROR_ALLOWLIST_FILE_SYNC`).
  - **(B) External file + `perm_reloadPermissionsFromFile`** (method confirmed:
    `RpcMethod.PERM_RELOAD_PERMISSIONS_FROM_FILE`). Fits ConfigMap/GitOps; incompatible with a
    read-only mount and with (A).
- **⚠️ Per-node, not chain state.** The allowlist is node-local — any add/remove must be applied on
  **every enforcing node** (all 4 validators + RPC pools that accept inbound txs). This per-node
  fan-out (vs the old contract's single consensus-shared tx) is the **key design decision to settle
  before coding** — e.g. a small script that loops the enforcing pods doing (A) or (B).
- **Also rewrite:** the Foundry tests (the Solidity contract is moot for file-based), `add-account.sh`
  (call the PERM RPC, not a contract), and reconcile doc 02 §2.5 wording.
- **Reserve naming:** keep `"onchain"` only as a tombstone; implement the redesign under `"local"`.

---

## C10 — Permanent F27 fix: startup DNS-readiness gate for node permissioning  ✅ DONE — ACCEPTANCE COMPLETE (2026-07-02, 3/3 fresh deploys clean; F27 RESOLVED)

**Source.** F27 (2026-07-01 mock: fresh chain halted at block 0, validators 0 peers) +
the 2026-07-02 comparison run (identical sequence came up LIVE first try) — together they
prove F27 is a **nondeterministic startup race**: Besu resolves the node-permissioning
allowlist enode DNS **once at startup**; on a fresh genesis all pods boot simultaneously,
so whether a validator sees its peers depends on whether the peer Services had DNS/
endpoints at that instant. Every fresh prod genesis rolls this dice.

**Task.** Make a fresh genesis deterministic. Preferred: an **init container** on every
Besu node (validators especially) that blocks until the enode hostnames in the node
allowlist resolve (e.g. loop `getent hosts <peer-svc>` for all peers, with a timeout),
so Besu only starts once DNS is ready. Alternative/complement: periodic allowlist
re-resolution (`perm_reloadPermissionsFromFile` on a timer sidecar) so a lost race
self-heals. Keep the documented staged-roll live fix in the runbook as recovery.

**Implementation (2026-07-02, branch `c10-dns-readiness-gate`).** New `wait-peer-dns` init
container in `helm/charts/besu-node` (runs before `build-config`, same `toolsImage`): polls
`getent hosts` for every peer hostname (the same Terraform-computed `peers.*` lists the
enode allowlist is built from) and only lets Besu start when ALL resolve. Deadlock-free —
the headless Service already sets `publishNotReadyAddresses: true`, so each pod's DNS
record exists while it waits in its own init phase. Values: `dnsReadiness.enabled=true`,
`timeoutSeconds=300`, `pollSeconds=5`, `onTimeout=fail|continue` (default `fail`: init
exits 1 → kubelet retries → pod shows `Init:Error`; Besu never starts with a partial peer
view). Rollback = `dnsReadiness.enabled=false` (exact pre-C10 behavior). No Terraform
change (chart defaults flow; releases use `wait=false` so applies don't block). Verified:
`helm template` + `helm lint` + local 3-path script test (resolve / timeout-fail /
timeout-continue). NOTE: does NOT cover the F19 day-2 case (adding a new pool later still
needs the existing nodes rolled — they resolved before the pool existed).

**Acceptance: COMPLETE (2026-07-02).** [x] **3 consecutive fresh deploys** (02b, 02c, 02d)
reached quorum + advancing blocks with NO manual roll. The gate observed the LIVE race in
ALL THREE runs — run #3 showed **all 4 validators** at 7/9 unresolved peers at t=0 — proving
F27 was near-inevitable ungated; gate waits were 5–15s in every case (logs:
`docs/prod-deploy-run-2026-07-02{b,c,d}-*.md`); [x] gate has a sane timeout + clear log
line (verified live); [x] guide §14 F27 note updated to reference the gate (runbook A.7 note =
prod-branch file, update on merge to prod); [x] rollback path documented (`dnsReadiness.enabled=false`).

## C11 — Deploy/teardown hygiene from the 2026-07-02 run (F28 + secrets/EBS traps)  ✅ DONE — live-verified 2026-07-02b/c (`docs/prod-deploy-run-2026-07-02b-c10-c11-c8.md`)

**Source.** `docs/prod-deploy-run-2026-07-02-claude.md` findings section.

**Task.**
1. **F28 (code):** runner bootstrap must **fail cloud-init loudly** when the repo clone
   fails (today it logs to `/var/log/besu-clone.err` and exits 0 → runner looks healthy
   with no repo). Also surface a boot-status marker file the runbook can check.
2. **F28 (runbook, done in PRODUCTION-DEPLOYMENT.md 2026-07-02):** PAT curl-check in A.1;
   A.5 note to `put-secret-value` the github-token secret if the PAT rotated after A.3.
3. **Secrets trap:** teardown step to force-delete the scheduled-deletion secrets after
   destroy (or `secret_recovery_window_days=0` in deploy-test tfvars; keep 30 in real prod).
4. **EBS sweep:** broaden the sweep (status=available + `tag:Name` starts_with `besu-aws`,
   not one cluster tag) in the runbook AND `scripts/maintenance/full-delete.sh`; add EBS
   count to the zero-check. Consider `reclaimPolicy: Delete` for deploy-test tfvars.

**Implementation (2026-07-02).**
1. `modules/runner` user-data: 3 clone attempts → on failure writes
   `/opt/besu-deploy/BOOTSTRAP_STATUS` (FAILED + reason) and **exits 1** (cloud-init
   reports error); on success writes OK + commit + deploy-config state. New
   `runner_bootstrap_check` output = one-liner SSM check.
2. **Root cause of the EBS leak fixed at the source:** `modules/storage-csi` now sets
   StorageClass `tagSpecification_N` params from `local.common_tags` — the EBS CSI driver
   stamps every dynamically provisioned volume with `DeletionGroup` etc. (CSI volumes are
   created by the driver, NOT Terraform, so provider default_tags never reached them).
3. `full-delete.sh`: secrets sweep now uses `list-secrets --include-planned-deletion`
   filtered by the DeletionGroup tag (the tagging API stops returning scheduled secrets);
   EBS DG-sweep logs; new **report-only leftover check** (available `besu-*` volumes +
   `besu*` secrets incl. scheduled) so cross-run leaks can't hide again.
4. `primary.tfvars.example`: documented the `secret_recovery_window_days` re-deploy
   collision trap (0 for deploy-tests / force-delete post-destroy; keep 30 for real prod).

**Acceptance (live-verified 2026-07-02b, `docs/prod-deploy-run-2026-07-02b-c10-c11-c8.md`).**
[x] bootstrap status marker verified live (OK path 07-02b); **[x] fail case LIVE-VERIFIED
07-02c**: deliberately poisoned token → `cloud-init: status: error` + marker
`FAILED: git clone … Authentication failed` (vs the silent 07-02a behavior), and the
documented F28 recovery (put-secret-value + `-replace`) restored an OK bootstrap verbatim;
[x] CSI tagSpecification: all 10 PVC volumes carried DeletionGroup; the DG-keyed sweep caught
all 10 orphans by tag alone + 0 untagged leftovers; [x] `secret_recovery_window_days=0` left
**zero** scheduled-deletion secrets after destroy (name-collision trap eliminated for tests).

## Suggested order
1. **C2a** (quick tfvars cleanup) — unblocks a sane prod admin/allowlist.
2. **C1** (runner own state) — de-risks every subsequent apply.
3. **C2** (identity model + script) and **C4** (re-genesis safety) — together enable a clean
   prod chain genesis with a managed admin.
4. **C3** (app/infra per-env) → **C5** (secure app deploy) — stand up + run the app.
5. **C6 (reopened, independent)** — file-based account permissioning, only if/when account
   enforcement is actually required. The chain runs fine with it **off**; not a blocker for C1–C5.

> Once C1–C5 land, doc 03 becomes executable on prod and the per-dApp onboarding is
> runtime-only (no re-genesis). Update findings F7–F11 to ✅ in the command log as each ships.
> C6 is decoupled — account permissioning is off and the system works without it.

---

## C7 — Certificate-expiry email notifier (30-day cadence)  📋 NEW (2026-06-29)

**Source.** Cert-maintenance review (`tech-team-qa-2026-06-29.md` §8/§8b): the **5 managed X.509
certs** expire and need renewal — the 3 leaf certs (SWIFT server/client + app-rpc server, ~825 d)
on a ~2-yr cycle and the root CA (~10 yr). There is currently **no automated expiry warning**.

**Problem.** A lapsed server cert silently breaks the SWIFT or app RPC plane; a lapsed SWIFT client
cert breaks SWIFT's access. Expiry must be surfaced *well before* it happens.

**Change.** A scheduled job that, **every 30 days**, checks every managed cert's `notAfter` and
**emails the ones approaching expiry** (and nothing/an all-clear when none are):
- **What to check:** the leaf certs inside the PKCS12 keystores in Secrets Manager
  (`besu-node-rpc-keystore` A2, `besu-node-apprpc-keystore` A5, the SWIFT client cert A3 if we hold a
  copy) + the CA cert (`besu-node-ca-cert` A1). Parse `notAfter` (e.g. `openssl pkcs12 -nokeys` →
  `openssl x509 -enddate`), compute days-remaining.
- **Threshold:** flag any cert within, say, **≤60 days** (configurable). The 30-day cadence guarantees
  at least one warning inside a 60-day window.
- **Delivery:** reuse the existing **observability SNS→email** topic (Alertmanager→SNS→email already
  exists) — publish a summary listing each flagged cert (name, `notAfter`, days-left). Avoid a new
  email channel.
- **Mechanism (pick one):** (a) an EventBridge **Scheduler** rule (rate(30 days)) → small **Lambda**
  (instance role reads Secrets Manager + publishes SNS); or (b) a Kubernetes **CronJob** in-cluster
  using the existing pod IRSA. Lambda is simpler/cheaper and runs even if the cluster is down.

**Acceptance.** On the 30-day tick, an email arrives **only when** ≥1 managed cert is within the
threshold, listing each with its expiry date + days remaining; healthy certs produce no noise (or a
single "all certs healthy, next expiry in N days" line — decide during build). Idempotent; no secrets
in logs. **Files:** new `terraform/modules/observability/` (or a small `cert-expiry/` module) +
the check script; wire the SNS topic ARN from observability.

**Decisions to confirm before build:** Lambda vs CronJob; threshold days; "all-clear" email or
silence-when-healthy; whether to also track the SWIFT client cert (A3, SWIFT-held — we may only know
its expiry if SWIFT shares it).

---

## C8 — Remove the on-chain permissioning tombstone (`AccountAllowlist.sol`)  ✅ DONE (2026-07-02, branch `c11-c8-hygiene-and-tombstone`)

**Source.** F17 / [[c6-onchain-permissioning-invalid]]: Besu **removed smart-contract permissioning
in 25.6.0** (PR hyperledger/besu#8597), so the on-chain `AccountAllowlist` contract + `--permissions-
accounts-contract-*` flags **can never run** on our pinned 26.6.1+. It is kept today as a disabled
tombstone; the C6 redesign is **file-based** and will **not** use the Solidity contract.

**Recommendation: SAFE TO REMOVE.** The contract path is permanently dead code; the historical
knowledge already lives in the docs (`02-blockchain-layer.md` §2.5, this backlog's C6, the run logs)
and stays there. Removing it shrinks the surface and ends the "is onchain an option?" confusion.

**Change (full removal of the `onchain` account-permissioning path):**
- Delete `permissioning/` (the Foundry project: `AccountAllowlist.sol`, `build.sh`, `out/`, `cache/`,
  `lib/`, `test/`, `foundry.toml`, `README.md`).
- Delete `helm/charts/besu-genesis/files/account-allowlist.runtime.hex` and the **onchain predeploy
  block** in `qbft-config-configmap.yaml` (the `{{- if $onchain }}` alloc/code/storage stanza).
- Remove the **`accountMode=onchain` branch** in `helm/charts/besu-node/templates/statefulset.yaml`
  (the `--permissions-accounts-contract-*` flags) + the related `values.yaml` keys.
- Remove `account_contract_address` (+ the `onchain` arm of the `account_permissioning_mode`
  validation) from `terraform/variables.tf` and `terraform/modules/besu/{variables,main}.tf` — leave
  the validation set as `{off, local}`.
- Delete `scripts/permissioning/{add-account.sh, bootstrap-allowlist.sh}` (they drive the contract).
- Keep all **F17 explanatory text** in the docs (it explains *why* it's gone).

**Acceptance (2026-07-02): MET.** `terraform validate` (chain + runner roots) + `helm lint` +
`helm template` (genesis alloc comma logic re-verified with 2 accounts) all pass;
`account_permissioning_mode` accepts only `off`/`local` (and `node_permissioning_mode` only
`local` — node-contract permissioning was removed by the same Besu 25.6.0 change);
`grep -rn AccountAllowlist` outside `docs/` matches only the live `initialAccountAllowlist`
value name + removal-history comments (no live contract references). Removed: `permissioning/`,
`scripts/permissioning/`, the genesis predeploy block + `account-allowlist.runtime.hex`, the
statefulset onchain flags branch, `account_contract_address` end-to-end. **Caveat:** independent
of the C6 *file-based* redesign — C8 removes the dead contract path; C6 adds the new one later.

---

## C9 — Audit master for test-only artifacts before the real prod go-live  📋 NEW (2026-06-30)

**Source.** User request (2026-06-30): before the actual af-south-1 deployment, make sure nothing that
exists **only to facilitate deployment testing** leaks into real prod.

**Task.** Scan the **master** branch for anything created/relaxed for the deploy-tests/rehearsal that
should NOT be present (or must change) in actual prod, and produce an inventory + per-item
recommendation (remove / gate behind a flag / set to the real value / move out of the prod path).
Candidate categories to check (not exhaustive — the scan defines the final list):
- **Relaxed-for-test infrastructure:** the SWIFT NLB static "In-VPC clients" ingress on the RPC port
  (`rpc-access/main.tf` — added for the runner's mTLS smoke test; confirm it's acceptable in prod or
  gate it); `RPC_TLS_INSECURE` escape hatch; any `0.0.0.0/0` egress that could tighten.
- **Throwaway app layer:** the entire `app/` tree (the test dApp + Storage contract + prebuilt
  `app/web/contract/Storage.json`) and the in-cluster **app-rpc edge** — the real prod consumer is
  SWIFT, not the dApp. Decide: keep as reference, gate with `enable_app_rpc=false`, or exclude.
- **Test config / placeholders in COMMITTED files** (the real `*.tfvars` are gitignored, so focus on
  what's tracked): `*.tfvars.example` test values (chain_id 90210, `grafana_admin_password` literal,
  TEST-OVERRIDE comments, placeholder SWIFT CIDR/hostname), any hardcoded test deletion_group/region.
- **Keys / certs / secrets in the repo:** confirm NO private keys, PATs, PEMs, PKCS12, or signer/
  validator keys are committed (they should all be gitignored or in Secrets Manager) —
  `git grep -nE 'BEGIN (RSA|EC|PRIVATE)|github_pat_|private_key|0x[0-9a-f]{64}'` across tracked files.
- **Tombstones / dead code:** the C6 on-chain permissioning artifacts (covered by C8).

**Deliverable.** A findings table (path · what · why test-only · prod action). Then, if the user wants,
**create a `prod` branch kept in sync with master but with the test-only data removed/parameterised** —
i.e. master stays the working/dev line; `prod` is the deployable-to-real-prod line.

**Acceptance.** [ ] inventory produced; [ ] each item has a prod decision; [ ] (optional) `prod` branch
exists, builds (`terraform validate` + `helm lint`), and carries no testing data.

---

## C12 — FIPS 140-2 Level 3 key management for validator/consensus keys  ✅ Option 1 (path B) PROD-VERIFIED (2026-07-05)
> **STATUS 2026-07-05 (verified in the combined C6+C12 deploy-test,
> `docs/prod-deploy-run-2026-07-05-c6c12.md`, branch `feature/c6-c12-combined`):** the human chose
> **path B (at-rest custody)** → **Option 1 (KMS + Secrets Manager)** built. This is also the §10.2
> "adopt regardless" baseline, so implementing it does not pre-empt the compliance A/B ruling; a
> strict-(A) ruling would still require Option 2 (CloudHSM) on top.
>
> **What was built** (gated by `enable_node_key_cmk`, default OFF; ON in the prod tfvars example):
> - **Customer-managed CMK** (`terraform/kms.tf`) with annual rotation + a key policy that grants
>   `kms:Decrypt` to ONLY the Besu pod IRSA role and `kms:Decrypt`+`GenerateDataKey` to the genesis
>   role (explicit, least-privilege; account-root admin to prevent lockout). Acyclic key→IAM→key-policy
>   ordering (verified via `terraform graph`).
> - **Node-key + CA-private-key secrets** encrypted with the CMK (`modules/secrets` `kms_key_id`).
> - **Scoped IRSA grants** added to the pod (Decrypt) + genesis (Decrypt+GenerateDataKey) policies
>   (`modules/iam`), so the CSI driver / genesis Job transparently use the CMK.
> - **CloudTrail per-decrypt audit** — KMS Decrypt/GenerateDataKey on the CMK are CloudTrail
>   **management** events, captured by the base trail (`enable_cloudtrail`). (F31, 2026-07-05: the
>   original `advanced_event_selector`/`enable_kms_data_events` data-event approach was invalid —
>   `AWS::KMS::Key` is not a data-event resource type — and was removed; the audit still holds.)
> - **Memory-only delivery** already satisfied (Secrets Store CSI → tmpfs). **CA-key remediation:** the
>   SM copy is now CMK-encrypted; for "no long-lived key in tfstate" the guide recommends `ca_mode="aws"`
>   (ACM PCA keeps the CA key in its HSM). `terraform validate`/`fmt`/`graph` all clean.
>
> **DoD MET (2026-07-05):** the prod deploy-test with `enable_node_key_cmk=true` verified pods
> decrypt via the CMK (chain up), the genesis Job wrote CMK-encrypted keys, CloudTrail recorded
> 18 Decrypt **management** events, and teardown scheduled the CMK deletion
> (`docs/prod-deploy-run-2026-07-05-c6c12.md`). Still outstanding: record the compliance A/B
> ruling (§9 of the FIPS analysis doc).

**Source.** Human requirement (2026-07-03): validator private keys must be **managed in hardware
validated to FIPS 140-2 Level 3 (or higher)**. Scope is the **validator / bootnode / node-identity**
keys ONLY (secp256k1 node keys) — application/transaction-signing keys are explicitly out of scope.
Full options analysis (auditor-facing) in **`docs/fips-140-l3-validator-key-management-analysis.md`**
(a shareable Word/PDF copy can be regenerated from it on request). Respect [[no-hardcoding-rule]].

**Current state (baseline).** Node keys live in **Secrets Manager** (AWS-managed `aws/secretsmanager`
KMS key, i.e. FIPS-L3 *at rest* but uncontrolled), delivered via the **Secrets Store CSI driver** into
an **in-memory (tmpfs)** mount, read by Besu as `--node-private-key-file`. So the key is already
FIPS-L3-encrypted at rest but exists in **plaintext in pod memory at signing time**. The `ca_mode="aws"`
(ACM Private CA) hook exists but is off; the self-managed CA key currently sits in **tfstate** (a
separate gap to remediate).

**Key technical constraint (do not re-litigate).** Besu has **no remote-signer hook for the node key**
and AWS **KMS cannot host it** (KMS is not PKCS#11; and the node key also does secp256k1 **ECDH** for
devp2p, which KMS doesn't offer). So "sign inside certified hardware" is achievable **only via AWS
CloudHSM** + the Besu `--security-module` PKCS#11 plugin — never via KMS. KMS can only ever give
*encryption at rest* for these keys.

**The decision that gates everything (BLOCKER — get in writing from compliance/audit):**
does "FIPS 140-2 L3" mean **(A)** key generated-in / never-leaves the HSM with signing performed
*inside* it; or **(B)** key *encrypted at rest* under FIPS-L3 hardware + strong runtime controls?

**Two implementation paths (pick per the ruling):**
- **Option 1 — KMS + Secrets Manager (envelope encryption).** Satisfies reading **(B)** only.
  Customer-managed **CMK** (cert #4884, FIPS 140-3 L3), decrypt-to-memory only, IRSA + KMS key-policy
  scoped to the validator pods' role, CloudTrail alarm per `Decrypt`, key-rotation procedure, and fix
  the CA-key-in-tfstate gap. **~$1/key/mo**, no consensus-path change, low risk. Touch points:
  `terraform/modules/secrets` (add CMK + `kms_key_id`), IRSA policy (`kms:Decrypt`), the key-delivery
  init path, and `ca_mode="aws"` for the CA.
- **Option 2 — CloudHSM + `besu-hsm-plugin`.** Satisfies reading **(A)**. `hsm2m.medium` (cert #4703,
  FIPS 140-3 L3, single-tenant, secp256k1). **~$2,300–3,500/mo** (≥2 HSMs across AZs — roughly 2–3×
  the whole bill), puts an HSM call on the **consensus hot path** (load-test vs the 5 s block period),
  and adds a CloudHSM cluster to operate. Verify the plugin against Besu 26.6.1 and that `hsm2m.medium`
  is orderable in `af-south-1` before committing. (`hsm1.medium` is EOL — auto-migrates 2026-01-20.)

**Recommendation.** Adjudicate (A) vs (B) first. Adopt the Option-1 controls as a baseline hardening
regardless (they strictly improve the current posture and are prerequisites under either reading);
reserve CloudHSM for a written strict-(A) mandate with explicit budget sign-off.

**Acceptance.** [ ] compliance ruling (A/B) recorded; [ ] chosen option implemented + `terraform
validate`/`helm lint` pass; [ ] key delivered only into memory (no on-disk plaintext); [ ] access
scoped + audited; [ ] CA key no longer in tfstate; [ ] (Option 2 only) consensus-path latency
load-tested and HSM-outage behaviour documented in the maintenance runbook.

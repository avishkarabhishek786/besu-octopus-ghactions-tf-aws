# Hardening validation — mock deploy + pentest plan (H1–H27)

> **Purpose.** End-to-end confirmation, on a real (throwaway) prod deploy, of the 27
> production-hardening fixes (P0 `H1–H4`, P1 `H5–H12`, P2 `H13–H27`) implemented on branch
> **`feature/production-hardening`**. Static validation (`terraform validate`, `helm template`,
> `bash -n`, `node --check`) is already green; this plan is how the controls get *confirmed
> under a live chain* and *attacked* to prove they hold.
>
> **This is a plan you (the human) execute.** Per [[deployment-advise-only-mode]] I do not run
> applies/destroys — every command here is for you to run, review the output, and tick the
> checkbox. Standing rules apply: [[prod-testing-practice]] (**prod env, us-east-1, USD 15/run,
> MANDATORY same-day teardown**), and confirm each `apply`/`destroy` before running it.
>
> **Branch under test:** `feature/production-hardening` (superset of `feature/c6-c12-combined`;
> carries the C10 DNS startup gate — expect a brief `Init` phase per pod, no F27 halt).
>
> **Automated harness.** `scripts/validation/hardening-validation.sh` runs this whole matrix
> against an **already-running** deployment (it does NOT deploy or tear down). It is
> **read-only / prod-safe by default** — describe/simulate/`plan -lock=false` only, no secret
> values read; the disruptive tests (H3 revoke, H16 roll, H6 rogue-pod) are gated behind
> `--allow-mutations` with read-only substitutes. Gates every check off your tfvars; prints a
> PASS/FAIL/SKIP matrix. First live run = 2026-07-11 (`docs/prod-deploy-run-2026-07-11-hardening.md`).
> Run `--dry-run` to see what applies to your config. The step-by-step below remains the
> source of truth the script mirrors.

---

## 0. Scope, cost, and what this run does / does not cover

**Confirms (23 of 27 live-testable):** H1, H2, H3, H4, H5, H6, H7, H8, H10, H12, H13 (by
`terraform plan` inspection only — deletion protection is never enabled, per the operator
directive; see §3.8), H14, H15,
H16, H19, H20, H21, H22, H23, H24, H25, H26, plus H9 (JWT claims; pinning only if you opt in).

> **NEW AND UNPROVEN THIS RUN (2026-08-10) — treat as the run's primary objective.** The H5
> residual closure landed after the 2026-07-11 mock: an IAM **permissions boundary** on every
> stack-created role (`enable_iam_permissions_boundary`, default **true**) plus a rewritten,
> resource-scoped runner deploy policy that denies role creation without that boundary. Phase A
> now creates `<name_prefix>-role-boundary` and Phase C runs under the tightened policy — so a
> missing permission surfaces as an `AccessDenied` mid-apply. Budget for one retry, keep
> `deploy_extra_actions` (runner tfvars) to hand as the fix, and see §3.6b for the attacks.

**Static-only this run (cannot be observed live, already code-reviewed):**
- **H11** — `--Xbft-legacy-protocol-encoding` only matters on a 25↔26 rolling upgrade; a fresh
  26.6.1 deploy never crosses the boundary. Validate by rendering (`helm template … --set
  bft.legacyProtocolEncoding=true | grep Xbft`) and a `rolling-besu-rollback.sh --dry-run`.
- **H17** — argv-leak fix is observable only by inspecting `/proc/<pid>/cmdline` at the exact
  moment `sm_put` runs; treat as code-reviewed. (Only the `sm_put` PAT path was fixed;
  `cast`/`openssl`/`keytool` argv items remain — out of scope.)
- **H18** — validated by *deliberately* breaking the runner clone (optional §3.7).

**Explicitly OUT of scope:** H27 (DEFERRED — secret-name namespacing), all of P3 (H28–H39),
and the `cast/openssl/keytool` remainder of H17.

**Cost/time budget.** One chain lifecycle (~2–4 h wall clock) at us-east-1 prod size fits the
**USD 15** cap **only with disciplined same-day teardown**. The app layer (Phase G, for
H4/H8/H22/H24/H25) adds an app VPC + EC2 + 2 internal LBs — budget it as a *second* short
window or run it back-to-back before teardown. **Do not leave anything up overnight.**

**OPERATOR DIRECTIVE (2026-07-06) — nothing that blocks immediate deletion.** For this and any
deploy-test run, **do NOT enable any property that prevents immediate teardown**: no
`enable_deletion_protection=true` (H13), no `prevent_destroy`, no S3 Object Lock / deny-delete on
the CloudTrail bucket (H19). Consequences for this plan:
- **H13** is validated by **code + `terraform plan` inspection only** (the `enable_deletion_protection`
  var threads to both NLBs) — it is left at its default `false`, never enabled. The "delete is
  blocked" and "§5 unwind" steps are removed.
- **H19** — keep `cloudtrail_force_destroy=true` for the mock (prod flips it `false` only at a
  real, long-lived go-live). Versioning + SSE are still validated; **Object-Lock tamper-proofing
  is out of scope here by directive** (it would block teardown).

---

## 1. Pre-flight — make the opt-in controls actually active

**Problem:** none of the P2 opt-in toggles are set in `terraform/environments/prod/primary.tfvars`,
so a plain deploy exercises *default-off* code paths for H5(default-on scoped policy is fine),
H6, H7, H13, H19, H20. Layer a second var-file **after** `primary.tfvars` so the base file stays
untouched.

**Create `terraform/environments/prod/hardening-validation.tfvars`** (git-ignore it or delete
after — it may carry a CMK ARN):

```hcl
# ── Layered AFTER primary.tfvars to turn the P2 opt-in controls ON for validation ──
# apply with: -var-file=environments/prod/primary.tfvars -var-file=environments/prod/hardening-validation.tfvars

# H6 — NetworkPolicy over privileged RPC listeners (needs the VPC CNI NetworkPolicy agent)
enable_network_policy = true                 # flips vpc-cni configuration_values enableNetworkPolicy=true
network_policy = {
  enabled          = true
  # scope each listener's ingress to its real client; use the app/explorer/runner pod labels
  # or namespace selectors your cluster uses. Leaving a client unset = that rule denies all.
}

# H13 — NLB deletion protection: DO NOT ENABLE (operator directive: nothing blocks immediate
#       deletion). Left at default false; validated by code + `terraform plan` inspection only.
# enable_deletion_protection = false   # (default; keep it)

# H19 — CloudTrail bucket hardening. Keep force_destroy=true for the MOCK so teardown works;
#       prod value is false. Versioning + SSE are validated regardless.
cloudtrail_force_destroy = true
# cloudtrail_kms_key_arn = "arn:aws:kms:us-east-1:<acct>:key/<id>"   # optional: SSE-KMS on the trail

# H7 / H20 — customer CMK for EKS Secrets envelope + chain-data/node-EBS at rest.
# enable_secrets_encryption defaults true (H7). Supply a CMK whose key policy already allows the
# EBS, EKS, and (if used) CloudTrail service principals — THIS run is what proves that policy.
# If you don't have one ready, leave data_cmk_arn empty: H20 then validates as "AWS-managed"
# and the customer-CMK path is deferred to real go-live.
# data_cmk_arn = "arn:aws:kms:us-east-1:<acct>:key/<id>"

# H5 — runner scoped deploy policy is the DEFAULT (use_admin_deploy_policy=false). Leave it.
#      Break-glass test in §3.6 flips it true only to compare.
```

> **CMK note (H7/H20/H19-KMS).** These are the items most likely to need a second iteration —
> a wrong CMK key policy fails the apply with a `KMS … AccessDenied` on volume/secret creation.
> If you have a properly-scoped multi-service CMK, set `data_cmk_arn` (and optionally
> `cloudtrail_kms_key_arn`) and this run *proves* the policy. If not, leave them empty and mark
> H7 "validated (AWS-managed EKS layer)" / H20 "deferred" — do not burn the $15 window iterating
> on a key policy.

**App-layer identity (for Phase G / H4, H8, H22):** generate it *before* the chain apply so the
signer is funded **and** allowlisted, and the app API token exists:

```bash
./app/scripts/gen-app-identity.sh --env prod
# writes terraform/environments/prod/app-identity.tfvars (app_signer_account → allowlist+funded, H8;
# APP_API_TOKEN, APP_ENV=prod into the app .env template, H4/H22)
```

**H12 costs nothing and needs no deploy — do it first (§2.0).**

---

## 2. Deploy with inline validation checkpoints

Runbook source of truth: `docs/manual-deployment-guide.md` §6. Phases A–F below mirror it; the
`▶ CHECK` lines are the hardening assertions to run *at that point*.

### 2.0 — H12 input-validation (plan-only, before anything bills)

Deliberately feed bad values and confirm `terraform plan` **fails** with a clear message. Run
each from `terraform/`, throwaway overrides (never apply):

```bash
terraform plan -var-file=environments/prod/primary.tfvars -var 'validator_count=3'        # ▶ CHECK H12: fails "3F+1 ≥ 4"
terraform plan -var-file=environments/prod/primary.tfvars -var 'chain_id=1'               # ▶ CHECK H12: fails "public chain id"
terraform plan -var-file=environments/prod/primary.tfvars -var 'swift_sipn_allowed_cidrs=["0.0.0.0/0"]'  # ▶ CHECK H12: fails "reject 0.0.0.0/0"
terraform plan -var-file=environments/prod/primary.tfvars -var 'permissioning_admin_account=0xnothex'    # ▶ CHECK H12: fails address regex
```
`[ ] H12` — each invalid value is rejected at plan time; the valid `primary.tfvars` still plans clean.

### Phase A — Foundation + AWS layer (laptop, chain root, `deploy_in_cluster_resources=false`)

```bash
cd terraform
terraform init -backend-config="bucket=<state-bucket>" -backend-config="key=besu/prod/main.tfstate" \
  -backend-config="region=<state-region>" -backend-config="use_lockfile=true"   # S3-native lock; NO DynamoDB table.
#   Use key=besu/prod/main.tfstate — the runner root's chain_state_key defaults to it (runner reads chain outputs).
terraform plan  -var-file=environments/prod/primary.tfvars -var-file=environments/prod/hardening-validation.tfvars
terraform apply -var-file=environments/prod/primary.tfvars -var-file=environments/prod/hardening-validation.tfvars
```
Surface the plan's resource counts + expensive items (EKS, NAT, NLBs, worker ASG) before approving.

- `▶ CHECK H7` — envelope encryption on the cluster:
  `aws eks describe-cluster --name <cluster> --query cluster.encryptionConfig` → shows `resources:["secrets"]` + your CMK (or the dedicated H7 CMK). `[ ] H7`
- `▶ CHECK H10` — addons pinned + PRESERVE:
  `aws eks describe-addon --cluster-name <c> --addon-name vpc-cni --query addon.addonVersion` (repeat coredns/kube-proxy/aws-ebs-csi-driver); each is a concrete pinned version, and the plan showed `resolve_conflicts_on_update = "PRESERVE"`. `[ ] H10`
- `▶ CHECK H20` — data-at-rest CMK (only if `data_cmk_arn` set): after nodes exist,
  `aws ec2 describe-volumes --filters Name=tag:DeletionGroup,Values=<dg> --query 'Volumes[].{id:VolumeId,kms:KmsKeyId}'` → node root + chain-data volumes carry your CMK ARN. `[ ] H20`
- `▶ CHECK H21` — IMDS hop limit on worker LT:
  `aws ec2 describe-launch-template-versions --launch-template-id <node-lt> --query 'LaunchTemplateVersions[0].LaunchTemplateData.MetadataOptions.HttpPutResponseHopLimit'` → `1`. (Live pentest in §3.3.) `[ ] H21`
- `▶ CHECK H13` — NLB deletion protection **(code/plan only — do NOT enable it)**: confirm in the
  `terraform plan` that `enable_deletion_protection` threads to both `aws_lb.rpc` and `aws_lb.app_rpc`
  and that its effective value is **`false`** (attribute `deletion_protection.enabled=false` on the
  live NLBs). Per the operator directive nothing that blocks teardown is turned on. `[ ] H13`
- `▶ CHECK H19` — CloudTrail audit bucket:
  `aws s3api get-bucket-versioning --bucket <trail-bucket>` → `Enabled`; `aws s3api get-bucket-encryption --bucket <trail-bucket>` → `aws:kms` (if `cloudtrail_kms_key_arn` set) else `AES256`; `aws cloudtrail describe-trails --query 'trailList[].KmsKeyId'`. `[ ] H19`

### Phase B — Runner provision (laptop, runner's own root/state)

```bash
scripts/runner/push-deploy-config.sh
cd terraform/runner
terraform init -backend-config="key=besu/prod/runner.tfstate" <other backend-config>
terraform apply          # use_admin_deploy_policy defaults false → runner gets the SCOPED policy
```
- `▶ CHECK H5` — the apply itself is the test: the runner's instance profile is the **scoped**
  policy, and Phase C below **completes the whole in-cluster apply with it**. If Phase C fails on
  an `AccessDenied`, capture the action, add it to `terraform/runner/deploy-policy.tf`, re-apply.
  A clean Phase C = the scoped policy is sufficient. `[ ] H5` (final tick after Phase C succeeds)
- `aws ssm start-session --target <runner-id>` (from the `runner_ssm_command` output).

### Phase C — In-cluster apply (from the runner, `deploy_in_cluster_resources=true`)

```bash
# inside SSM session, at /opt/besu-deploy/besu-aws/terraform
terraform apply -var-file=environments/prod/primary.tfvars \
  -var-file=environments/prod/hardening-validation.tfvars -var deploy_in_cluster_resources=true
```
Genesis Job runs, then per-node Besu releases (validators via `helm_release.validator`), then
in-cluster observability.

- `▶ CHECK H14` — containers run hardened (**the key risk: does Besu tolerate non-root + drop-ALL?**):
  `kubectl -n besu get pod besu-validator-1-0 -o jsonpath='{.spec.containers[?(@.name=="besu")].securityContext}'`
  → `runAsNonRoot:true, runAsUser:1000, allowPrivilegeEscalation:false, capabilities.drop:["ALL"], seccompProfile.type:RuntimeDefault`; and the pod reaches **Running/Ready** (i.e. Besu didn't crash under the constraints). `[ ] H14`
- `▶ CHECK H7 (etcd)` — no node key mirrored to etcd:
  `kubectl -n besu get secrets | grep -i node` → only the CSI-mounted references, **no** synced
  secp256k1 key Secret. `[ ] H7-etcd`
- `▶ CHECK H1` — validators immune to bulk mutation. From the runner, note validator pod
  `AGE`, then trigger a shared-value change and re-apply:
  ```bash
  kubectl -n besu get pods -l besu.role=validator            # record AGE + RESTARTS
  terraform apply -var-file=… -var-file=… -var deploy_in_cluster_resources=true -var 'explorer_rpc_count=1'
  kubectl -n besu get pods -l besu.role=validator            # ▶ AGE unchanged, 0 new restarts
  ```
  `[ ] H1` — scaling a non-validator pool (rewrites `local.peers`) does **not** restart validators.
- `▶ CHECK H2` — genesis guard. Re-apply with no genesis change:
  `kubectl -n besu get job besu-genesis -o jsonpath='{.status.completionTime}'` unchanged across a
  re-apply; the `besu-genesis` ConfigMap `resourceVersion` unchanged. Then confirm the guard
  refuses a re-run without the flag (the Job's publish step exits early when the ConfigMap exists
  and `allowRegenesis != true`). `[ ] H2`
- `▶ CHECK H16` — rolling gate poll + resume. Do a no-op image roll and read the gate:
  ```bash
  scripts/maintenance/rolling-besu-apply.sh --image <same-current-besu-image>
  ```
  Expect: per validator → helm-upgrade → delete pod → wait Ready → **bounded catch-up poll**
  (`CATCHUP_TIMEOUT`, not a single-shot read) → next. Kill it mid-roll and re-run: it **skips**
  validators already on the target image (idempotent resume). `[ ] H16`

### Phase D — Cert / JWT / SWIFT edge (from the runner, order-sensitive)

```bash
RPC_HOSTNAME=<host> scripts/pki/issue-server-cert.sh    # BEFORE the RPC pods settle
scripts/access/sign-client-csr.sh
scripts/access/make-join-pack.sh
```
- `▶ CHECK H9 (JWT claims)` — decode the JWT in the join pack: header/payload has `aud`, `jti`,
  `iat`, `nbf`, and `exp − iat ≈ 90d` (not 1 yr). `[ ] H9-jwt`
- `▶ CHECK H9 (pinning, opt-in)` — only if you enabled `mtls.knownClientsSecret` +
  `caClientsEnabled`: an mTLS client cert signed by the infra CA but **not** in the known-clients
  file is rejected (see pentest §3.5). Else mark "deferred". `[ ] H9-pin`

### Phase E — Chain-health verification (from the runner)

```bash
kubectl -n besu get pods                                   # validators+bootnodes+RPC Running/Ready
kubectl -n besu logs job/besu-genesis | tail              # preflight OK
# exec a validator:
#   eth_blockNumber advancing; qbft_getValidatorsByBlockNumber → the 4 validators
```
- `▶ CHECK H15` — RPC-role readiness: an app-rpc/explorer/swift-rpc pod is **not Ready until its
  RPC port answers** (not just P2P). Confirm readiness probe is `tcpSocket: rpc-http` for those
  roles: `kubectl -n besu get pod <rpc-pod> -o jsonpath='{.spec.containers[0].readinessProbe}'`.
  `[ ] H15`
- `▶ CHECK H3` — allowlist **revocation** is enforced on all 4 validators (the security-critical
  P0). With `account_permissioning_mode=local`:
  ```bash
  PROPAGATE=hot scripts/permissioning/add-account.sh    <test-addr>
  scripts/permissioning/list-accounts.sh  --live       # ▶ test-addr enforced on every validator
  # (optional, needs Foundry/cast) fund + send a tx from test-addr → MINES
  PROPAGATE=hot scripts/permissioning/remove-account.sh <test-addr>
  scripts/permissioning/list-accounts.sh  --live       # ▶ test-addr GONE on every validator
  # send another tx from test-addr → REJECTED on all 4 validators
  ```
  `[ ] H3` — the revoked account's tx is rejected chain-wide (proves `hot` reconcile is real,
  not the old silent no-op).

### Phase G — App layer (for H4, H8, H22, H24, H25) — optional second window

Follow guide §12.6/§12.7 (app-identity already generated in §1):
```bash
cd terraform && terraform apply -var-file=environments/prod/primary.tfvars \
  -var-file=environments/prod/app-identity.tfvars -var-file=environments/prod/hardening-validation.tfvars
AWS_REGION=us-east-1 ./app/scripts/gen-app-identity.sh --push-secrets
AWS_REGION=<r> scripts/pki/issue-app-rpc-cert.sh
aws ec2 accept-vpc-endpoint-connections --service-id <svc> --vpc-endpoint-ids <ep>
cd app/infra && terraform init && terraform apply
# EC2 self-bootstraps (push-app-env.sh + app-ec2-bootstrap.sh)
```
- `▶ CHECK H8` — fresh deploy, `local` mode: the app signer's contract-deploy + `set()` **mine**
  (signer is both funded and allowlisted). `[ ] H8`
- `▶ CHECK H22` — SSM into the app EC2, set `RPC_TLS_INSECURE=true` in `.env` with `APP_ENV=prod`,
  `systemctl restart besu-app` → the process **hard-fails at startup** (does not run with TLS
  verification globally disabled). Revert. `[ ] H22`
- `▶ CHECK H24` — nonce serialization: fire N concurrent authenticated `set()`s and confirm **all
  N mine** (no lost write from a shared nonce):
  ```bash
  for i in $(seq 1 5); do curl -s -XPOST http://127.0.0.1:3000/api/value \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $APP_API_TOKEN" \
    -d "{\"value\":$i}" & done; wait
  ```
  → 5 distinct successful txs, sequential nonces, none dropped; and a stalled RPC returns a bounded
  5xx (timeout), not a hang. `[ ] H24`
- `▶ CHECK H25` — durable contract address: confirm the app-env **secret** now holds the real
  `CONTRACT_ADDRESS` (not `0x000…`): `aws secretsmanager get-secret-value --secret-id <app-env> --query SecretString --output text | grep CONTRACT_ADDRESS`. A replacement would read this, not redeploy empty. `[ ] H25`

---

## 3. Pentest — actively attack each control

Vantage points: **(a) a rogue in-cluster pod**, **(b) the in-VPC runner / app host**, **(c) an
off-VPC laptop** (baseline "nothing public"). Each test names the control and the expected
*denied* result. Run the "without the control" comparison only where noted.

Spin up a rogue pod:
```bash
kubectl -n besu run rogue --image=nicolaka/netshoot --restart=Never -it -- bash
```

### 3.1 — H6: rogue pod cannot reach the privileged ops/explorer listeners
From `rogue` (NetworkPolicy `enabled=true`):
```bash
curl -s http://besu-validator-1-ops:8545 -d '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}'   # ▶ times out / connection refused
curl -s http://<explorer-rpc-svc>:8545 -d '{"jsonrpc":"2.0","method":"debug_traceBlockByNumber","params":["latest",{}],"id":1}'          # ▶ blocked
```
`[ ] H6` — both denied by NetworkPolicy. (Optional proof-it-matters: set `network_policy.enabled=false`,
re-apply, confirm the same calls **succeed** — a rogue pod could vote validators / trace. Re-enable after.)

### 3.2 — H6/ops-JWT: ops listener without a JWT fails render-time
Confirm you *cannot* even deploy an ops listener without a JWT secret (the render-time precondition):
`helm template … --set opsRpc.enabled=true --set opsRpc.jwtPubkeySecret=""` → **fails** with the
precondition message (unless `opsRpc.allowNoJwt=true`). `[ ] H6-jwt`

### 3.3 — H21: pod cannot steal the node IAM role via IMDS
From `rogue`:
```bash
curl -s -m3 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60"   # ▶ empty / timeout (hop limit 1)
curl -s -m3 http://169.254.169.254/latest/meta-data/iam/security-credentials/                                 # ▶ no node role creds
```
`[ ] H21` — the pod cannot obtain IMDSv2 credentials (hop limit 1 stops the extra pod→node hop).

### 3.4 — H4: app tx-API rejects unauthenticated + CSRF submits
From the in-VPC runner/app host (not the operator port-forward):
```bash
curl -s -o /dev/null -w '%{http_code}\n' -XPOST http://<app-ip>:3000/api/value -H 'Content-Type: application/json' -d '{"value":1}'   # ▶ 401 (or 503 if token unset)
curl -s -o /dev/null -w '%{http_code}\n' -XPOST http://<app-ip>:3000/api/value -H 'Content-Type: text/plain' --data '{"value":1}'      # ▶ rejected (kills the simple-request CSRF)
curl -s -o /dev/null -w '%{http_code}\n' -XPOST http://<app-ip>:3000/api/value -H 'Content-Type: application/json' -H "Authorization: Bearer $APP_API_TOKEN" -d '{"value":1}'  # ▶ 200
```
`[ ] H4` — only the same-origin, `application/json`, correct-bearer request submits a tx.

### 3.5 — H9: infra-CA cert not pinned is rejected (opt-in pinning only)
If `mtls.knownClientsSecret` is set: present an mTLS client cert signed by the infra CA but absent
from the known-clients file to the SWIFT edge → **TLS handshake rejected**. Without pinning,
Besu accepts any infra-CA-signed clientAuth cert (the H9 gap) — mark "deferred" if you didn't
opt in. `[ ] H9-pin`

### 3.6 — H5: runner scoped policy denies out-of-scope actions
From the runner SSM session (scoped policy active):
```bash
aws iam create-user --user-name pentest-should-fail        # ▶ AccessDenied (no iam:CreateUser in scope)
aws organizations list-accounts                            # ▶ AccessDenied
```
`[ ] H5-deny` — IAM-user / org / account actions are denied while the stack's own
role/policy/PassRole actions succeed (proven by Phase C completing).

### 3.6b — H5 residual: the permissions boundary actually holds (NEW 2026-08-10)
The 2026-07-06 pentest escalated *through* the old scoped policy. These five checks attack the
paths the boundary + resource-scoping close. Run them from the runner; **all five must fail**.
```bash
ACC=$(aws sts get-caller-identity --query Account --output text); P=<name_prefix>
# 1. mint a role outside the stack's name prefix                → AccessDenied (resource scope)
aws iam create-role --role-name pentest-evil \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
# 2. mint an in-prefix role WITHOUT a boundary                  → explicit deny (RequirePermissionsBoundaryOnRoleCreate)
aws iam create-role --role-name ${P}-evil \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
# 3. lift the boundary off a real stack role                    → explicit deny (DenyRemovingPermissionsBoundary)
aws iam delete-role-permissions-boundary --role-name ${P}-eks-node-role
# 4. grant the runner itself more power                         → explicit deny (DenyRunnerSelfMutation)
aws iam put-role-policy --role-name ${P}-runner-role --policy-name esc \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}]}'
# 5. read a secret outside the chain's namespace                → AccessDenied (store scope)
aws secretsmanager get-secret-value --secret-id some-other-workload
```
Then confirm the positive half — every stack role is actually capped:
```bash
for r in $(aws iam list-roles --query "Roles[?starts_with(RoleName,'${P}-')].RoleName" --output text); do
  printf '%-42s %s\n' "$r" "$(aws iam get-role --role-name "$r" \
    --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text)"
done   # ▶ every row shows .../${P}-role-boundary EXCEPT ${P}-runner-role (uncapped by design)
```
`[ ] H5-boundary` (all roles but the runner carry the boundary) · `[ ] H5-escalate` (all 5 denied).
Both are automated in `scripts/validation/hardening-validation.sh` as read-only
`simulate-principal-policy` what-ifs — prefer the harness on prod; the raw commands above are the
manual equivalent for a throwaway mock.

> **If Phase C is denied a legitimate action:** re-apply the runner root with the action appended —
> `cd terraform/runner && terraform apply -var 'deploy_extra_actions=["<service>:<Action>"]'`
> (the runner root takes no tfvars file). Do **not** flip `use_admin_deploy_policy` unless you are
> unblocking a run in progress, and fold the action into `deploy_service_actions` afterwards.
> Capture every such action in the run log: the tightened policy has not been apply-validated
> before, so this run *is* its acceptance test.

### 3.7 — H18 (optional): PAT never lands in runner logs
Deliberately give the runner a bad PAT (or revoke it), re-provision, then:
`aws ec2 get-console-output --instance-id <runner>` and read the `BOOTSTRAP_STATUS` marker →
the clone URL credentials appear as `://***@`, **never** the raw token. `[ ] H18`

### 3.8 — H13: deletion protection (code/plan only — NOT exercised live)
Per operator directive, deletion protection is **never enabled** in a deploy-test, so the
"delete is blocked" behaviour is **not** exercised. Validate the wiring statically instead:
`grep -n enable_deletion_protection terraform/modules/rpc-access/main.tf` → present on both NLBs.
`[ ] H13` (wiring confirmed; control stays OFF so teardown is always immediate).

### 3.9 — H26: full-delete refuses the wrong account/region (dry-run, safe)
```bash
EXPECT_ACCOUNT_ID=000000000000 EXPECT_REGION=eu-west-1 scripts/maintenance/full-delete.sh --dry-run   # ▶ REFUSES: account/region mismatch
DELETION_GROUP='bad;rm -rf' scripts/maintenance/full-delete.sh --dry-run                               # ▶ REFUSES: DeletionGroup regex
```
`[ ] H26` — the teardown backstop denies a mismatched target and a malformed DeletionGroup **before**
touching anything. **Do not** run it without `--dry-run` here.

### 3.10 — H23 / baseline: CORS scoped + nothing public
- Cross-origin browser `set()` against the app pool is blocked by the scoped CORS (only the known
  app origin is allowed); server-to-server pools return no permissive CORS header. `[ ] H23`
- From the **off-VPC laptop**: every endpoint (RPC NLB DNS, app ALB, ops/explorer) is
  unreachable — confirms the standing "nothing public" guardrail still holds. `[ ] baseline`

---

## 4. Results matrix (fill in during the run)

| Item | Control | How validated | Result |
|------|---------|---------------|--------|
| H1 | Validators immune to bulk apply | §2 Phase C — scale non-val pool, AGE unchanged | ☐ |
| H2 | Genesis re-run guard | §2 Phase C — re-apply no-op; guard blocks overwrite | ☐ |
| H3 | Hot allowlist revoke enforced ×4 | §2 Phase E — revoked tx rejected chain-wide | ☐ |
| H4 | App API authn + anti-CSRF | §3.4 pentest | ☐ |
| H5 | Runner least-privilege | §2 Phase C completes on scoped policy + §3.6 deny | ☐ |
| H5-boundary | Every stack role permissions-boundary-capped | §3.6b role sweep | ☐ |
| H5-escalate | 5 escalation paths denied (boundary + scoping) | §3.6b | ☐ |
| H6 | NetworkPolicy on RPC listeners | §3.1 / §3.2 pentest | ☐ |
| H7 | EKS Secrets envelope CMK + no etcd sync | §2 Phase A + Phase C etcd check | ☐ |
| H8 | Signer funded **and** allowlisted | §2 Phase G — set() mines | ☐ |
| H9 | JWT claims (+ optional pinning) | §2 Phase D / §3.5 | ☐ |
| H10 | Addons pinned + PRESERVE | §2 Phase A describe-addon | ☐ |
| H11 | Legacy-encoding + rollback (static) | render + rollback --dry-run | ☐ |
| H12 | Input validation | §2.0 plan-fails | ☐ |
| H13 | NLB deletion protection | §2 Phase A attr + §3.8 delete blocked | ☐ |
| H14 | Container securityContext (Besu runs) | §2 Phase C jsonpath + Ready | ☐ |
| H15 | RPC-port readiness | §2 Phase E probe check | ☐ |
| H16 | Rolling gate poll + resume | §2 Phase C no-op roll | ☐ |
| H17 | sm_put off-argv (static) | code-reviewed | n/a |
| H18 | PAT scrub | §3.7 optional | ☐ |
| H19 | CloudTrail versioning + SSE | §2 Phase A bucket checks | ☐ |
| H20 | Data-at-rest CMK (if supplied) | §2 Phase A describe-volumes | ☐ |
| H21 | IMDS hop=1 | §2 Phase A attr + §3.3 pentest | ☐ |
| H22 | RPC_TLS_INSECURE prod hard-fail | §2 Phase G | ☐ |
| H23 | CORS scoped | §3.10 | ☐ |
| H24 | Nonce serialization + timeouts | §2 Phase G concurrent set() | ☐ |
| H25 | Durable contract address | §2 Phase G secret check | ☐ |
| H26 | full-delete account/region guard | §3.9 dry-run | ☐ |

---

## 5. Teardown + zero-check (MANDATORY, same day)

**No unwind needed** — per the operator directive nothing that blocks deletion was ever enabled
(H13 stayed `false`, `cloudtrail_force_destroy` stayed `true`, no Object Lock). Teardown is
immediate. Proceed straight to destroy in order (guide §6 Phase F):
```bash
# 1) app layer first (if Phase G ran)
cd app/infra && terraform destroy
# 2) in-cluster resources — state-rm from the laptop (can't reach private EKS to helm-destroy),
#    OR terraform destroy from the runner while it's still up. Then:
# 3) runner root
cd terraform/runner && terraform destroy
# 4) chain AWS layer
cd terraform && terraform destroy -var-file=environments/prod/primary.tfvars \
  -var-file=environments/prod/app-identity.tfvars      # include app-identity only if Phase G ran
# 5) EBS sweep by DeletionGroup tag, then zero-check
```
**Zero-check** (must return empty): EKS clusters, EC2 instances (runner + app), NLBs, NAT GWs,
EIPs, PVC-backed EBS volumes by `DeletionGroup` tag, the app VPC. Backstop if state is lost:
`scripts/maintenance/full-delete.sh` — but **only** with the correct `EXPECT_ACCOUNT_ID`/
`EXPECT_REGION` and an explicit typed confirmation.

**Delete the overlay file** `terraform/environments/prod/hardening-validation.tfvars` (and
`app-identity.tfvars`) if it carried a CMK ARN; append the run to `docs/test-run-log.md`
(start/stop, resources up, est. spend vs the $15 cap).

---

## 6. After the run

- Update each item's note in `docs/production-hardening-backlog.md` from "statically validated"
  to "**live-confirmed** (mock 2026-07-…)", and record any control that needed a fix (e.g. a
  denied IAM action added to the runner policy for H5, or a CMK key-policy edit for H7/H20).
- If H7/H20 ran AWS-managed (no CMK supplied), leave them flagged for the real go-live and note
  that the customer-CMK key policy is still un-apply-tested.
- Anything that failed → new backlog item; anything that passed → close it.
```

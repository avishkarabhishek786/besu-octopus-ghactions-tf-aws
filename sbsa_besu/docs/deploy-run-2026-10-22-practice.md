# Practice run — 2026-10-22 — reset to zero, then the whole stack

Following [`PRACTICE_DEPLOYMENT.md`](PRACTICE_DEPLOYMENT.md) (Part A, Part B, T1–T8). Today adds
a **Part R** first: delete everything the CI/CD side persists — Octopus, GitHub, the ECR mirror
and the AWS trust behind them — so Part A is a **genuine** first-time setup, not a row of
"already done". Times UTC.

**Order of the day:** R (reset) → A0–A9 (rebuild the one-time setup) → B0–B10 (the run) → T1–T8.

---

## Part R — reset the CI/CD side to zero (operator)

**What exists before the reset** (Claude, read-only, 12:55):

| Where | What | Made by |
|---|---|---|
| Octopus space `Default` | 3 projects, 1 project group, environment SIT, lifecycle, worker pool `besu-runner-sit`, AWS OIDC account, Docker feed, library variable set `Besu platform` + 12 variables, processes/steps — **36 objects** (25 resource blocks) | `octopus/terraform` (A6), state `besu/octopus/space.tfstate` |
| Octopus | `besu-ci` service account + OIDC identity, team, 2 user roles, 2 scoped roles — **8 objects** | `octopus/ci-trust` (A7), state `besu/octopus/ci-trust.tfstate` |
| Octopus | worker `Workers-1` (`ip-10-60-0-250`, Unavailable) | `install-tentacle.sh` (B7) — **not Terraform** |
| Octopus | service accounts behind the two API keys (Space-manager key, Tentacle register key), their teams; package `sbsa-besu-platform` in the built-in feed | by hand (A5, A8) / the release workflow — **not Terraform** |
| AWS us-east-1/global | Octopus OIDC provider, deploy role + policy + attachment, secret `sbsa-besu-sit-octopus-deploy-config` — **5** | `octopus/aws-trust` (A4), state `besu/octopus/aws-trust.tfstate` |
| AWS | ECR push role + policy for GitHub — **2** | `mimic_registry` (A2), state `besu/sit/registry.tfstate` |
| AWS af-south-1 | ECR mirror, **29 repositories** under `mirror/` | `supply-chain.yml` (A3) — not Terraform |
| AWS af-south-1 | secrets `sbsa-besu-octopus-terraform-key`, `sbsa-besu-primary-octopus-register-key`, `sbsa-besu-primary-tentacle-cert` | by hand (A5, A8) |
| GitHub repo | 2 secrets, 7 variables, workflow run history | by hand (A2, A7) / runs |

**Kept, on purpose:** the two state buckets (A1 re-confirms them), the **GitHub OIDC provider** in
IAM (`token.actions.githubusercontent.com` — `mimic_registry` only *reads* it, as a `data` source;
no step in this repo creates it, so deleting it would break A2), the workflow **files** (they're
code), your local tfvars (A9's `cp -n` keeps them), and the Octopus **instance and space** (the
code manages what's inside the space, not the space).

**Order, and why:** Octopus first, while the keys that delete it still exist (R2 needs the
Space-manager key, R3 an admin key) — and **R3 before R2** (learned 13:22): `ci-trust` scopes the
`Besu CI` team's roles to the three projects, and Octopus refuses to delete a project a team is
scoped to; `ci-trust` also looks the projects up by name, so its plan fails once they're gone; then the keys and accounts themselves; then the AWS trust
Octopus used; then the mirror and the role GitHub used; GitHub's settings last.

### R0 — Terminal

```bash
export REPO=~/Documents/Blockchain/Besu/besu-octopus-ghactions-tf-aws
export D=2026-10-22 SP=~/besu-run-2026-10-22 ACCT=867728055761; mkdir -p $SP
```

### R1 — Octopus UI: the pieces Terraform doesn't own, which would block R2

1. **Infrastructure → Workers → `ip-10-60-0-250` → ⋮ → Delete.** A worker pool that still holds a
   worker can't be deleted, so R2 would stop half-way.
2. **Deploy → Manage → Packages** → `sbsa-besu-platform` → delete **all versions**. It is the **one**
   package every project deploys (`PACKAGE_ID` in `release.yml` — the whole `sbsa_besu` tree as a
   zip, version `YYYY.M.D.<run>`); the release workflow pushed it and it outlives the projects.

### R2 — Delete the Octopus space contents ⚠️ run **after R3**: `octopus/terraform` (expect **36** to destroy)

```bash
cd $REPO/sbsa_besu/octopus/terraform
export OCTOPUS_APIKEY="$(aws secretsmanager get-secret-value --region af-south-1 \
  --secret-id sbsa-besu-octopus-terraform-key --query SecretString --output text)"
terraform plan -destroy -var-file=environments/sit/space.tfvars -out=$SP/space-d.plan
terraform show -no-color $SP/space-d.plan | grep '^Plan:'     # 0 to add, 0 to change, 36 to destroy
terraform apply $SP/space-d.plan
unset OCTOPUS_APIKEY
```

Projects, their releases and deployment history go with it.

### R3 — Delete GitHub → Octopus trust ⚠️ run **before R2**: `octopus/ci-trust` (expect **8**, Octopus **admin** key)

```bash
cd $REPO/sbsa_besu/octopus/ci-trust
read -rs OCTOPUS_APIKEY && export OCTOPUS_APIKEY            # the ADMIN key, typed, never stored
terraform plan -destroy -var-file=environments/sit/ci-trust.tfvars -out=$SP/ci-trust-d.plan
terraform show -no-color $SP/ci-trust-d.plan | grep '^Plan:'  # 8 to destroy
terraform apply $SP/ci-trust-d.plan
unset OCTOPUS_APIKEY
```

### R4 — Octopus UI: the hand-made accounts (after R2 — R2 needed the first one's key)

**Configuration → Users** (service accounts) and **Configuration → Teams**:
- the **Space-manager** service account (`besu-terraform`, A5) — delete it (its API keys go with
  it) and its team;
- the service account behind the **Tentacle register key** (A8) — delete it and its team.

After R3 + R4, **Users** should list only you (and any admin), **Teams** only the built-in ones.

### R5 — Delete Octopus → AWS trust: `octopus/aws-trust` (expect **5**)

```bash
cd $REPO/sbsa_besu/octopus/aws-trust
terraform plan -destroy -var-file=environments/sit/aws-trust.tfvars -out=$SP/aws-trust-d.plan
terraform show -no-color $SP/aws-trust-d.plan | grep '^Plan:'   # 5 to destroy
terraform apply $SP/aws-trust-d.plan
```

The deploy-config secret has `recovery_window_in_days = 0`, so A4 can recreate the name at once.

### R6 — Delete the three hand-made secrets (no recovery window, or A5/A8 can't reuse the names for 30 days)

```bash
for s in sbsa-besu-octopus-terraform-key sbsa-besu-primary-octopus-register-key sbsa-besu-primary-tentacle-cert; do
  aws secretsmanager delete-secret --region af-south-1 --secret-id $s --force-delete-without-recovery \
    --query Name --output text; done
aws secretsmanager list-secrets --region af-south-1 --include-planned-deletion \
  --query 'SecretList[].Name' --output text                      # → empty
```

Deleting the tentacle cert means B7 registers a **new** worker identity today — what a first time looks like.

### R7 — Empty the ECR mirror (29 repositories)

A3 refills it (`create_repos` ON — `allow_create_repositories = true` in `registry.tfvars`, so CI may).

```bash
R=$(aws ecr describe-repositories --region af-south-1 \
      --query "repositories[?starts_with(repositoryName,'mirror/')].repositoryName" --output text)
echo "$R" | tr '\t' '\n' | wc -l                                 # → 29 — STOP if anything else is listed
for r in $R; do aws ecr delete-repository --region af-south-1 --repository-name $r --force \
  --query repository.repositoryName --output text; done
aws ecr describe-repositories --region af-south-1 --query 'length(repositories)' --output text   # → 0
```

### R8 — Delete the ECR push role: `mimic_registry` (expect **2**)

```bash
cd $REPO/mimic_registry/terraform
terraform plan -destroy -var-file=environments/sit/registry.tfvars -out=$SP/registry-d.plan
terraform show -no-color $SP/registry-d.plan | grep '^Plan:'   # 2 to destroy
terraform apply $SP/registry-d.plan
```

### R9 — GitHub UI: settings and history

Repo → **Settings → Secrets and variables → Actions**:
- **Secrets** tab: delete `AWS_ECR_PUSH_ROLE_ARN`, `ECR_REGISTRY`, and `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` if present.
- **Variables** tab: delete `ECR_PREFIX`, `AWS_REGION`, `CI_RUNNER_LABELS`, `RELEASE_RUNNER_LABELS` (optional — may not exist),
  `OCTOPUS_URL`, `OCTOPUS_SPACE`, `OCTOPUS_SERVICE_ACCOUNT_ID`.
- Also check **Settings → Environments**: if any environment holds secrets/variables, delete those too.

Optional: **Actions** → each workflow → each run → **⋯ → Delete workflow run** (history only; nothing
depends on it).

### R10 — Zero-check of the reset (Claude, read-only)

Claude checks: the four states hold 0 resources; no `mirror/` repositories; no secrets (incl.
planned deletion); no Octopus OIDC provider or deploy/push roles in IAM.
You check: Octopus → Projects, Infrastructure (environments, worker pools, workers, accounts),
Deploy → Manage (feeds, variable sets, packages) empty **except the 2026-09-06 demo objects, which are not ours and stay**: project `Terraform AWS Demo`, variable set `AWS variableset`, account `AWS Dev` (`Accounts-1`); GitHub → no Actions secrets/variables.

---

## Log (Claude writes from what you report · times UTC)

| Time | Step | Who | Result |
|---|---|---|---|
| 12:52 | A0 — tools | Claude | ✅ Terraform 1.16.1 (= manifest pin), aws-cli 2.34.53, jq 1.7, session-manager-plugin 1.2.835.0, OpenSSL 3.0.13, cast 1.4.0. `gh` **not installed**, so GitHub runs (A3, A7 test, B4, B8) are UI clicks |
| 12:53 | B0 (early) — empty account | Claude | ✅ account `867728055761`; af-south-1: no non-default VPCs, no EKS clusters |
| 12:53 | A0 — `verify-region.sh af-south-1 m6i.xlarge 1.35` | Claude | ✅ **7 passed, 0 failed** |
| 12:54 | A9 (early look) — sender key | Claude | ⚠️ **no Foundry keystore on the laptop** (`~/.foundry/keystores` absent). `genesis_funded_accounts` still `0x9f7e…b248` from 10-11, the key nobody had on 10-17. A9 today must **create** `besu-sit-sender` and put its address into `chain.tfvars` **before B3** |
| 12:55 | decision — reset first | operator | Delete everything GitHub/Octopus persist, then do Part A as a real first time. Claude inventoried it (table above) and wrote Part R |
| ~13:00 | gap found — GitHub OIDC provider | Claude | `token.actions.githubusercontent.com` provider (created 2026-09-06, outside this repo, aud `sts.amazonaws.com`) is **kept** by Part R. `mimic_registry` only reads it, and no step created it, so A2 would fail in a truly empty account. **`PRACTICE_DEPLOYMENT.md` A2 now checks for it and creates it only if missing**, says never to delete it, and its 🏦 note says it is the cloud team's in the bank, and absent altogether if their runners use IRSA or an instance profile (R-7, CD-49) |
| ~13:07 | branch `testing` | operator / Claude | ✅ `git switch -c testing` from `shared-eks-namespace` (`1a395dd`). Committed the docs as `19a7bef`. Stashed `stash@{0}`: the two tracked `.plan` files (old binary run artefacts) and `Discussion with Cloud team on resources.md` (bank Confluence content, never committed). **Consequence for Part A:** CI trust is exact on the branch ref, so `refs/heads/testing` must be added to `allowed_refs` in `registry.tfvars` (A2) and `ci-trust.tfvars` (A7), and A3/B4/B8 run from `testing` |
| 13:10 | R0 — terminal (`REPO`, `D`, `SP`, `ACCT`) | operator | ✅ done |
| 13:16 | R1 — packages | operator | Only `sbsa-besu-platform` in **Deploy → Manage → Packages** — correct: it is the single package all three projects deploy. **Claude's R1 was wrong** (named `besu-infra`/`besu-workloads` packages, said "Library"); fixed in place above |
| 13:17 | R1 — worker + package deleted | operator | ✅ worker `ip-10-60-0-250` (`Workers-1`) deleted; `sbsa-besu-platform` all versions deleted |
| 13:21 | R2 — `octopus/terraform` plan -destroy | operator | ✅ **36 to destroy**, not the 25 Claude predicted. **Claude's count was wrong:** it counted resource blocks, not instances — `octopusdeploy_variable.lvs` is 10 instances (the `Besu platform` variables), `process_step.infra_root` 3 (shared/chain/runner). State holds exactly 36. Same error in R3: ci-trust is **8** (= RUNBOOK). Both fixed above. Cleared to apply |
| 13:22 | R2 — apply | operator | ⚠️ **partial: 28 of 36 destroyed**, apply ended (lock released 13:22:13). Gone: 12 variables, 8 process steps, 3 processes, 3 step orders, Docker feed, worker pool `besu-runner-sit`. **Left (8):** projects ×3, project group, lifecycle, environment SIT, AWS OIDC account, library variable set. Waiting on the error text |
| 13:24 | R2 — the error | operator / Claude | 3 × `This project cannot be deleted because it restricts permissions for the following teams: Besu CI`; 1 × `This account cannot be deleted as it is currently referenced by a variable`. **Cause: Claude's Part R order.** `ci-trust`'s scoped roles point at the projects, so **R3 must precede R2**; the account reference goes with the projects. Order fixed above. Next: R3, then re-plan R2 (expect **8**) |
| 13:36 | R3 — plan (1st) | operator | ❌ `Required plugins are not installed` — `octopusdeploy 1.20.0` not in `ci-trust/.terraform/providers` (local cache gone; backend config intact). Fix: plain `terraform init` |
| 13:37 | R3 — `terraform init` | operator / Claude | ❌ then ✅. `cannot install package … because it is a symlink`: `ci-trust/.terraform/providers/…/1.20.0/linux_amd64` was a **dangling link into a 10-10 Claude session scratchpad** (a plugin cache from Claude's check that day, since wiped). **Cause: Claude, 10-10.** Claude removed the link (cache only; state + lock untouched) and re-ran `init` → initialised, provider now a real directory. Searched all roots: no other links into `/tmp/claude-*` |
| 13:38 | R3 — `ci-trust` plan -destroy | operator | ✅ **8 to destroy** = prediction (corrected). Cleared to apply |
| 13:39 | R3 — apply (1st) | operator | ⚠️ **partial: 4 of 8.** Gone: scoped role + role `deploy`, GitHub OIDC identity (+1). Failed: `octopusdeploy_scoped_user_role.publish` — `An exception has been raised that is likely due to a transient failure. Please try again.` Left: scoped role + role `publish`, team `Besu CI`, user `besu-ci`. Lock released. Retry: re-plan (expect 4) |
| 13:41 | R3 — plan (retry) | operator | ✅ **4 to destroy**, as expected |
| 13:41 | R3 — apply (retry) | operator | ✅ **4 destroyed** → `ci-trust` total **8/8**; Claude: state now **0** managed. Team `Besu CI` gone, so the projects are released for R2 |
| 13:43 | R2 — plan (after R3) | operator | ✅ **8 to destroy**, as expected |
| 13:44 | R2 — apply (2nd) | operator / Claude | ⚠️ 6 of 8: projects ×3, group, lifecycle, variable set gone. Account `Accounts-21` again `referenced by a variable` — a **race**: deleted in parallel with the projects whose variables referenced it. Claude (read-only API, Space-manager key): usages of `Accounts-21` now **empty**. Left: account + environment SIT. Also in the space, **not ours** (2026-09-06 demo, left alone): `Terraform AWS Demo`, `AWS variableset`, `AWS Dev` — R10 updated. Retry: expect **2** |
| 13:45 | R2 — apply (3rd) | operator | ❌ `Saved plan is stale` — an older plan file applied after the state moved on; Terraform refused, **nothing changed** (Claude: state serial 9, same 2 left, no lock). Re-plan, then apply |
| 13:47 | R2 — apply (4th, fresh plan) | operator | ✅ **2 destroyed** (account `Accounts-21`, environment SIT). R2 total **36/36** over three applies; Claude: `space` state **0** managed |
| 13:58 | R4 — Octopus users/teams | operator | Users: **`besu-terraform`** (A5) and **`besu-register`** (A8) deleted (their API keys with them — Claude's API call with the stored terraform key now 401); **`octaadmin`** kept (the administrator). Teams: `besu-terraform` listed; `besu-register`'s team is **`BesuTestTeam`** (named 2026-09-17, Environment manager on the space) — both to delete. For A8: name the new team after the account |
| 13:59 | R4 — teams | operator | ✅ teams `besu-terraform` and `BesuTestTeam` deleted |
| 14:01 | R5 — `aws-trust` plan -destroy | operator | ✅ **5 to destroy**, as expected |
| 14:03 | R5 — `aws-trust` apply | operator | ✅ 5 destroyed. Claude: state **0**; IAM OIDC providers = only `token.actions.githubusercontent.com` (kept); no `*octopus*` roles |
| 14:03 | R6 — 3 hand-made secrets, `--force-delete-without-recovery` | operator | ✅ Claude: af-south-1 and us-east-1 hold **no secrets**, incl. planned deletion (the list lagged a few seconds behind the delete — one name showed while `describe` already said not found) |
| 14:07 | R7 — ECR mirror emptied | operator | ✅ 29 `mirror/` = 29 total before; deleted with `--force`. Claude: af-south-1 **0** repositories (us-east-1 also 0) |
| 14:08 | R8 — `mimic_registry` plan -destroy | operator | ✅ **2 to destroy**, as expected |
| 14:17 | R9 — GitHub (in progress) | operator / Claude | `RELEASE_RUNNER_LABELS` **not present** — optional, `release.yml` falls back to `CI_RUNNER_LABELS` (never set). **`DOCKERHUB_USERNAME` found in Secrets**, not on Claude's list: optional Docker Hub login for `mirror.sh`, needs `DOCKERHUB_TOKEN` too, so alone it was ignored (anonymous pulls). Delete. `PRACTICE_DEPLOYMENT.md` A2 table: `RELEASE_RUNNER_LABELS` marked optional, Docker Hub pair added as optional; R9 list updated |
| 14:22 | R8 — `mimic_registry` apply | operator | ✅ 2 destroyed (Claude: state 0) |
| 14:22 | R9 — GitHub | operator | ✅ secrets `AWS_ECR_PUSH_ROLE_ARN`, `ECR_REGISTRY`, `DOCKERHUB_USERNAME` and the repo variables deleted |
| 14:22 | **R10 — zero-check of the reset** | Claude | ✅ **CLEAN.** States `space`, `ci-trust`, `aws-trust`, `registry`: **0** each; no `.tflock`. ECR af-south-1: **0** repos. Secrets af-south-1 + us-east-1: **none** (incl. planned deletion). IAM OIDC providers: only GitHub's (kept). No `*octopus*`/`*ecr*` roles. One unrelated role found and **left alone**: `besu-nonprod-aws-load-balancer-controller` (created 2026-05-28, owner tag `aroko`, trusts a long-gone us-east-1 EKS OIDC provider, not referenced by this repo) |
| 06:06 (10-23) | R10 follow-up — old IAM role | operator → Claude | ✅ operator approved deleting `besu-nonprod-aws-load-balancer-controller` (2026-05-28, unrelated). No managed/inline policies or instance profiles attached; `delete-role` → `NoSuchEntity` on re-read. Also found, **not deleted**: customer-managed policy `AWSLoadBalancerControllerIAMPolicy` (created 2026-08-08, **0 attachments**), not referenced by this repo. Awaiting a decision |

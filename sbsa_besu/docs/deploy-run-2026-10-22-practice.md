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
| Octopus space `Default` | 3 projects, 1 project group, environment SIT, lifecycle, worker pool `besu-runner-sit`, AWS OIDC account, Docker feed, library variable set `Besu platform` + 3 variables, processes/steps — **25 objects** | `octopus/terraform` (A6), state `besu/octopus/space.tfstate` |
| Octopus | `besu-ci` service account + OIDC identity, team, 2 user roles, 2 scoped roles — **7 objects** | `octopus/ci-trust` (A7), state `besu/octopus/ci-trust.tfstate` |
| Octopus | worker `Workers-1` (`ip-10-60-0-250`, Unavailable) | `install-tentacle.sh` (B7) — **not Terraform** |
| Octopus | service accounts behind the two API keys (Space-manager key, Tentacle register key), their teams; packages in the built-in feed | by hand (A5, A8) / the release workflow — **not Terraform** |
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
Space-manager key, R3 an admin key); then the keys and accounts themselves; then the AWS trust
Octopus used; then the mirror and the role GitHub used; GitHub's settings last.

### R0 — Terminal

```bash
export REPO=~/Documents/Blockchain/Besu/besu-octopus-ghactions-tf-aws
export D=2026-10-22 SP=~/besu-run-2026-10-22 ACCT=867728055761; mkdir -p $SP
```

### R1 — Octopus UI: the pieces Terraform doesn't own, which would block R2

1. **Infrastructure → Workers → `ip-10-60-0-250` → ⋮ → Delete.** A worker pool that still holds a
   worker can't be deleted, so R2 would stop half-way.
2. **Library → Packages** → delete `besu-infra` and `besu-workloads` (all versions). The release
   workflow pushed them; they outlive the projects.

### R2 — Delete the Octopus space contents: `octopus/terraform` (expect **25** to destroy)

```bash
cd $REPO/sbsa_besu/octopus/terraform
export OCTOPUS_APIKEY="$(aws secretsmanager get-secret-value --region af-south-1 \
  --secret-id sbsa-besu-octopus-terraform-key --query SecretString --output text)"
terraform plan -destroy -var-file=environments/sit/space.tfvars -out=$SP/space-d.plan
terraform show -no-color $SP/space-d.plan | grep '^Plan:'     # 0 to add, 0 to change, 25 to destroy
terraform apply $SP/space-d.plan
unset OCTOPUS_APIKEY
```

Projects, their releases and deployment history go with it.

### R3 — Delete GitHub → Octopus trust: `octopus/ci-trust` (expect **7**, Octopus **admin** key)

```bash
cd $REPO/sbsa_besu/octopus/ci-trust
read -rs OCTOPUS_APIKEY && export OCTOPUS_APIKEY            # the ADMIN key, typed, never stored
terraform plan -destroy -var-file=environments/sit/ci-trust.tfvars -out=$SP/ci-trust-d.plan
terraform show -no-color $SP/ci-trust-d.plan | grep '^Plan:'  # 7 to destroy
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
- **Secrets** tab: delete `AWS_ECR_PUSH_ROLE_ARN`, `ECR_REGISTRY`.
- **Variables** tab: delete `ECR_PREFIX`, `AWS_REGION`, `CI_RUNNER_LABELS`, `RELEASE_RUNNER_LABELS`,
  `OCTOPUS_URL`, `OCTOPUS_SPACE`, `OCTOPUS_SERVICE_ACCOUNT_ID`.
- Also check **Settings → Environments**: if any environment holds secrets/variables, delete those too.

Optional: **Actions** → each workflow → each run → **⋯ → Delete workflow run** (history only; nothing
depends on it).

### R10 — Zero-check of the reset (Claude, read-only)

Claude checks: the four states hold 0 resources; no `mirror/` repositories; no secrets (incl.
planned deletion); no Octopus OIDC provider or deploy/push roles in IAM.
You check: Octopus → Projects, Infrastructure (environments, worker pools, workers, accounts),
Library (feeds, variable sets, packages) all empty; GitHub → no Actions secrets/variables.

---

## Log (Claude writes from what you report · times UTC)

| Time | Step | Who | Result |
|---|---|---|---|
| 12:52 | A0 — tools | Claude | ✅ Terraform 1.16.1 (= manifest pin), aws-cli 2.34.53, jq 1.7, session-manager-plugin 1.2.835.0, OpenSSL 3.0.13, cast 1.4.0. `gh` **not installed**, so GitHub runs (A3, A7 test, B4, B8) are UI clicks |
| 12:53 | B0 (early) — empty account | Claude | ✅ account `867728055761`; af-south-1: no non-default VPCs, no EKS clusters |
| 12:53 | A0 — `verify-region.sh af-south-1 m6i.xlarge 1.35` | Claude | ✅ **7 passed, 0 failed** |
| 12:54 | A9 (early look) — sender key | Claude | ⚠️ **no Foundry keystore on the laptop** (`~/.foundry/keystores` absent). `genesis_funded_accounts` still `0x9f7e…b248` from 10-11, the key nobody had on 10-17. A9 today must **create** `besu-sit-sender` and put its address into `chain.tfvars` **before B3** |
| 12:55 | decision — reset first | operator | Delete everything GitHub/Octopus persist, then do Part A as a real first time. Claude inventoried it (table above) and wrote Part R |
| ~13:10 | gap found — GitHub OIDC provider | Claude | `token.actions.githubusercontent.com` provider (created 2026-09-06, outside this repo, aud `sts.amazonaws.com`) is **kept** by Part R. `mimic_registry` only reads it, and no step created it, so A2 would fail in a truly empty account. **`PRACTICE_DEPLOYMENT.md` A2 now checks for it and creates it only if missing**, says never to delete it, and its 🏦 note says it is the cloud team's in the bank, and absent altogether if their runners use IRSA or an instance profile (R-7, CD-49) |

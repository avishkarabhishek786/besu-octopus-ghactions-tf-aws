# Deploy run — 2026-10-10 (Octopus) — CD-67 Phases 1–2: AWS trust and the Octopus space, as code

> **Live log.** Every command executed, in order, with what came back. Times UTC.
> Reconstructed from the session transcript on the same day. **Who ran what is marked on
> each step:** *Claude* ran it from the laptop shell; *operator* ran it because the
> permission layer refused it to Claude (IAM grants, `terraform apply`) or it happens in
> the Octopus UI. **The Octopus API key is never printed:** every command reads it from
> Secrets Manager into a variable and unsets it.

**Source under test:** `shared-eks-namespace` @ `717275d` (the `sbsa_besu/octopus/` tree),
then `3b408bc` (the `sort_order` fix).

**What it must show:**
1. **AWS trusts Octopus, and only for the one subject that should deploy:** an IAM OIDC
   provider for the instance, and a SIT deploy role whose trust is exactly
   `space:default:project:besu-infra:environment:sit`.
2. **The Octopus space is reproducible from Terraform:** environment, lifecycle, worker
   pool, OIDC account, variable set and the three projects with their steps. Verified
   through the API, with a no-change plan afterwards.

**Out of scope for this run (Phases 3–4):** `release.yml`, a release, any deployment.
Nothing in Octopus has executed yet.

**Instance:** `https://avishkarabhishek786.octopus.app`, the **Default** space (`Spaces-1`,
slug `default`), which is the only space. It already held non-Besu objects, which were left
untouched: environments Development/Staging/Production, account `AWS Dev`, pools Hosted
Ubuntu (`WorkerPools-3`), `sit-ledger-workers` (09-17) and Hosted Windows, projects
`Terraform AWS Demo` and `Hello world deployment`, and LVS `AWS`.

**Outcome:** ✅ `aws-trust` 5 resources; space 33 objects (4 + 29 over two applies); API
checks match; no-change plan. Two defects were found on the way, both fixed in code or
docs: a ReadOnly API key, and environment `sort_order`.

---

## 0. Reconnaissance (10:24 → 10:30, Claude, read-only)

```bash
find . -path ./.git -prune -o \( -iname "*octopus*" -o -name "*.ocl" -o -iname "*tentacle*" \) -print
grep -rl -i octopus --include=*.sh --include=*.yml --include=*.tf --include=*.json .
grep -n -E "^#+ " sbsa_besu/docs/CICD_DESIGN_NOTES.md
ls .github/workflows                      # → supply-chain.yml only; no release.yml
grep -n -E "^\| \*\*CD-(4|5|8|…|41|…)\*\*" sbsa_besu/docs/CICD_DESIGN_NOTES.md
grep -n -E 'variable "(deploy_in_cluster_resources|enable_blockscout…)' sbsa_besu/terraform/chain/variables.tf
grep -n -A3 "^### *4\." sbsa_besu/PORTING.md      # item 4: charts still from public URLs
grep -n -i -E "space|worker pool|octopus\.app|api key" sbsa_besu/docs/deploy-run-2026-09-17-r9-mock.md
curl -s https://registry.terraform.io/v1/providers/OctopusDeploy/octopusdeploy | jq -r '.version, .published_at'
```
→ The only Octopus code is `install-tentacle.sh`. There is no Octopus configuration. The
09-17 run registered a Tentacle into `sit-ledger-workers` in the Default space. The
provider's latest is **1.20.0** (published 2026-09-21); it is pinned.

Operator decisions (via question): **"Prove the machinery"** (workloads = smoke steps until
the CT-5 rewrite) and **"Terraform provider"** for the space. Recorded as **CD-67**;
committed **`fa2779a`**.

## 1. Provider schema and docs (10:46 → 10:48, Claude)

```bash
D=$SP/octo-schema; mkdir -p $D && cd $D
printf 'terraform { required_providers { octopusdeploy = { source = "OctopusDeploy/octopusdeploy", version = "1.20.0" } } }\n' > main.tf
terraform init && terraform providers schema -json > schema.json
jq -r '.provider_schemas[].resource_schemas|keys[]' schema.json | grep -E "environment|lifecycle|worker_pool|aws|project|process|variable|feed"
# per-resource attribute dumps for: process, process_step, process_steps_order, aws_openid_connect_account,
#   lifecycle, project, static_worker_pool, variable, environment; data sources worker_pools, feeds, space, environments
curl -s https://raw.githubusercontent.com/OctopusDeploy/terraform-provider-octopusdeploy/v1.20.0/docs/resources/process_step.md
curl -s https://raw.githubusercontent.com/OctopusDeploy/terraform-provider-octopusdeploy/v1.20.0/docs/resources/aws_openid_connect_account.md
curl -s …/v1.20.0/docs/guides/how-to-find-step-properties.md
```
→ `octopusdeploy_process_step` takes `type` plus untyped `execution_properties`. Step
property names are **not validated by the provider**, so they must be checked against the
instance. The OIDC account takes `role_arn`, `execution_subject_keys` (space, environment,
project, …) and `environments`. The provider reads the key from `OCTOPUS_APIKEY`.

```bash
aws iam list-attached-user-policies --user-name tfuser     # → AllAccess (the laptop's reach)
sed -n 1,120p sbsa_besu/scripts/runner/push-deploy-config.sh; cat sbsa_besu/scripts/runner/fetch-deploy-config.sh
grep -n "sm_put()" -A12 sbsa_besu/scripts/lib/common.sh; grep terraform sbsa_besu/scripts/runner/runner-tools.manifest
sed -n 1,60p sbsa_besu/scripts/maintenance/rolling-besu-apply.sh
grep -n -E "WORKER_POOL|--workerpool" sbsa_besu/scripts/runner/install-tentacle.sh     # pool chosen by NAME
```

## 2. `sbsa_besu/octopus/` written (10:49 → 10:55, Claude)

```bash
mkdir -p sbsa_besu/octopus/{aws-trust/environments/sit,terraform/environments/sit,steps}
# aws-trust/: versions, backend (s3, key besu/octopus/aws-trust.tfstate), variables, main, outputs, tfvars(.example)
terraform -chdir=sbsa_besu/octopus/aws-trust validate                    # → valid
chmod +x sbsa_besu/octopus/steps/*.sh && for f in sbsa_besu/octopus/steps/*.sh; do bash -n $f; done   # → 3 × syntax-ok
# terraform/: versions (provider 1.20.0), backend (key besu/octopus/space.tfstate), variables, space.tf, projects.tf, outputs
terraform -chdir=sbsa_besu/octopus/terraform fmt && terraform -chdir=sbsa_besu/octopus/terraform validate   # → valid
```
Two edits were made after the first validate. Both appear in the code comments:
- **Every variable a script reads gets an unscoped default.** Octopus passes an undefined
  variable through as the literal text `#{Name}`.
- **Approval steps get `count = 0` when there are no approval environments.** A step with
  an empty environment set runs in all environments. Step order uses `concat(...[*].id, [...])`.

The first scripted edit failed an assertion (`AssertionError … 0`, the text didn't match).
A regex version was applied instead, then validated.

The real `space.tfvars` and `aws-trust.tfvars` are gitignored (checked). The README and
`.example` files are committed. Committed **`717275d`** *feat: Octopus as code — aws-trust,
the space, three projects (CD-67)*.

## 3. Operator: push, apply `aws-trust` (≈ 10:55 → 11:33)

```bash
git push origin shared-eks-namespace                                                     # operator
cd sbsa_besu/octopus/aws-trust                                                           # operator
terraform init -backend-config="bucket=besu-tfstate-867728055761" -backend-config="key=besu/octopus/aws-trust.tfstate" \
  -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
terraform plan -var-file=environments/sit/aws-trust.tfvars -out=aws-trust.plan
terraform apply aws-trust.plan
```
→ **5 added** (Claude had predicted 6, wrongly counting a data source). Created **11:32:54**.
Outputs: `deploy_role_arns`, `deploy_config_secrets`, `trusted_subjects`.

Verified by Claude (11:33):
```bash
terraform -chdir=sbsa_besu/octopus/aws-trust state list
aws iam get-role --role-name sbsa-besu-sit-octopus-deploy --query 'Role.AssumeRolePolicyDocument'
aws iam list-open-id-connect-providers
```
→ State: `aws_iam_openid_connect_provider.octopus`, `aws_iam_role.deploy["sit"]`,
`aws_iam_role_policy.read_config["sit"]`,
`aws_iam_role_policy_attachment.deploy["sit|…AdministratorAccess"]`,
`aws_secretsmanager_secret.deploy_config["sit"]`. Trust: `StringEquals`
`avishkarabhishek786.octopus.app:aud = avishkarabhishek786.octopus.app` and
`…:sub = space:default:project:besu-infra:environment:sit`. The OIDC provider now sits
next to GitHub's.

```bash
aws secretsmanager describe-secret --region af-south-1 --secret-id sbsa-besu-octopus-terraform-key   # → not found (yet)
git check-ignore -v sbsa_besu/octopus/aws-trust/aws-trust.plan || echo "plan NOT ignored"        # → NOT ignored (root ignores only *.tfplan)
unzip -p sbsa_besu/octopus/aws-trust/aws-trust.plan | tr -d '\0' | grep -c 'PRIVATE KEY'          # → 0
git add …lock.hcl … aws-trust.plan && git commit …        # REFUSED by the permission layer (Credential Leakage)
git add mimic_registry/terraform/.terraform.lock.hcl sbsa_besu/octopus/aws-trust/.terraform.lock.hcl \
        sbsa_besu/octopus/terraform/.terraform.lock.hcl && git commit …                          # → cc027cc
```
The plan file was left untracked for the operator to delete or commit.

## 4. Operator: the Octopus service account and its key (11:38 → 11:51, Octopus UI)

1. **Configuration → Users → Add user**: service account **`besu-terraform`** (`Users-61`).
2. **Configuration → Teams → Add team**: `Besu Terraform`, scoped to the Default space,
   member `besu-terraform`, user role **Space manager**, no environment or project scoping.
3. **Users → besu-terraform → API keys → New API key** (expiry 2027-04-08; key type
   "a person"). Stored without passing through chat:
   ```bash
   read -rs K && aws secretsmanager create-secret --region af-south-1 \
     --name sbsa-besu-octopus-terraform-key --secret-string "$K" && unset K        # created 11:50:37
   ```

## 5. Key and step-property checks against the instance (11:51, Claude, read-only)

```bash
K="$(aws secretsmanager get-secret-value --region af-south-1 --secret-id sbsa-besu-octopus-terraform-key --query SecretString --output text)"
U=https://avishkarabhishek786.octopus.app
curl -fsS -H "X-Octopus-ApiKey: $K" "$U/api/users/me"               # → besu-terraform, IsService True
curl -fsS -H "X-Octopus-ApiKey: $K" "$U/api/users/me/permissions"   # → HTTP 500 (this endpoint fails on Cloud)
curl -fsS -H "X-Octopus-ApiKey: $K" "$U/api/spaces/all"             # → Spaces-1 Default default
curl -fsS -H "X-Octopus-ApiKey: $K" "$U/api/users/Users-61/permissions"   # need-list: EnvironmentCreate, LifecycleCreate,
                                                                          # WorkerEdit, AccountCreate, ProjectCreate, …
unset K
```
→ **missing: none**; `ProjectCreate` scoped to `Spaces-1`. *This check reads the
**account's** permissions, not the **key's** access level. See §7.*

```bash
curl … "$U/api/Spaces-1/projects/all"; for t in environments workerpools accounts lifecycles projectgroups libraryvariablesets; do curl … "$U/api/Spaces-1/$t/all"; done
curl … "$U/api/Spaces-1/projects/Projects-1/deploymentprocesses"     # TerraformApply step in the demo project
curl … "$U/api/Spaces-1/projects/Projects-22/deploymentprocesses"    # Script steps in Hello world
```
→ The existing objects are as listed in the header. The properties Octopus itself saved on
the AWS and Script steps match every key `projects.tf` uses:
- `Octopus.Action.Aws.AssumeRole`, `Aws.Region`, `AwsAccount.UseInstanceRole`
- `AwsAccount.Variable`, set to a **bare variable name** (`AWSAccount` there,
  `Besu.AwsAccount` here)
- `RunOnServer`, `Script.ScriptSource`, `Script.ScriptBody`, `Script.Syntax`
- package `FeedId = feeds-builtin`, `Extract = True`

## 6. Plan the space (11:52, Claude)

```bash
cd sbsa_besu/octopus/terraform
terraform init -input=false -reconfigure -backend-config="bucket=besu-tfstate-867728055761" \
  -backend-config="key=besu/octopus/space.tfstate" -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
OCTOPUS_APIKEY="$(aws secretsmanager get-secret-value --region af-south-1 --secret-id sbsa-besu-octopus-terraform-key --query SecretString --output text)" \
  terraform plan -input=false -var-file=environments/sit/space.tfvars -out=$SP/space.plan > $SP/space.plan.txt 2>&1
grep -nE '^\s+\+ (slug|name|role_arn|region|execution_subject_keys|session_duration) ' $SP/space.plan.txt
```
→ **Plan: 33 to add, 0 to change, 0 to destroy.** The plan creates:
- **Space objects:** environment SIT (slug `sit`), lifecycle `Besu SIT → UAT → PROD`,
  project group `Besu`, pool `besu-runner-sit`, LVS `Besu platform`.
- **The AWS account:** `besu-aws-sit`, with role
  `arn:aws:iam::867728055761:role/sbsa-besu-sit-octopus-deploy`, region `af-south-1`,
  session 3600 s, subject keys space/project/environment.
- **Projects** `besu-infra`, `besu-workloads` and `besu-validators`, and their processes,
  steps and step orders.
- **Variables** including `Besu.Cluster`, `Besu.DeployConfigSecret`, `Besu.RunnerPool` and
  `Besu.AwsAccount`.

No approval steps are created (SIT has none, by design).

Gap noticed: `Besu.Cluster` and `Besu.DeployConfigSecret` have **only** SIT-scoped values,
with no unscoped default. That is harmless with one environment; it needs a fail-loud
default before UAT/PROD.

## 7. Apply attempt 1: ReadOnly key (12:00, Claude, with operator's "apply")

```bash
OCTOPUS_APIKEY="$(aws secretsmanager get-secret-value …)" terraform apply -input=false $SP/space.plan
```
→ Every create was refused, for example:
```
Octopus API error: … Missing permission: LibraryVariableSetCreate []
… Missing permission: ProjectGroupCreate []
… Missing permission: EnvironmentCreate []
… Missing permission: WorkerEdit []
```
Diagnosis:
```bash
terraform state list | grep -v '^data\.'                                   # → empty: nothing created
curl -fsS -H "X-Octopus-ApiKey: $K" "$U/api/users/Users-61/apikeys"        # → Hint API-WBG7, AccessLevel: ReadOnly
curl -fsS -H "X-Octopus-ApiKey: $K" "$U/api/users/Users-61/teams"          # → Besu Terraform, Everyone
```
**Cause: the key was created with `AccessLevel: ReadOnly`.** The account has Space manager;
the key restricts it. It plans cleanly because planning only reads.

Operator fix (Octopus UI + shell):
```bash
# New API key, access level read-write ("FullAccess"), purpose "… (read-write)", same expiry
read -rs K && aws secretsmanager put-secret-value --region af-south-1 \
  --secret-id sbsa-besu-octopus-terraform-key --secret-string "$K" && unset K     # changed 12:05:41
# Revoked the old key API-WBG7
```
Claude checked it (12:06):
```bash
curl -fsS -H "X-Octopus-ApiKey: $K" "$U/api/users/Users-61/apikeys"   # → API-PRE8 FullAccess 2027-04-08 (the only key)
```

README step 3 now says the key must be read-write and how to check it. Committed
**`c3458b5`**.

## 8. Apply attempt 2: refused to Claude, run by the operator (12:06 → 12:09)

```bash
OCTOPUS_APIKEY=… terraform plan -out=$SP/space.plan && terraform apply $SP/space.plan   # Claude: REFUSED (Blind Apply)
OCTOPUS_APIKEY=… terraform plan -input=false -var-file=environments/sit/space.tfvars -out=$SP/space.plan   # Claude → 33 to add
OCTOPUS_APIKEY=… terraform apply -input=false $SP/space.plan                                               # Claude: REFUSED (Blind Apply)
```
The operator ran it:
```bash
cd sbsa_besu/octopus/terraform
OCTOPUS_APIKEY="$(aws secretsmanager get-secret-value --region af-south-1 --secret-id sbsa-besu-octopus-terraform-key --query SecretString --output text)" \
  terraform apply $SP/space.plan
```
→ Created `ProjectGroups-3`, `WorkerPools-43` and `LibraryVariableSets-22`. Then:
```
Error: Provider produced inconsistent result after apply
When applying changes to octopusdeploy_environment.this["SIT"], … .sort_order: was cty.NumberIntVal(0), but now cty.NumberIntVal(3).
```

## 9. Diagnose and fix `sort_order` (12:09 → 12:10, Claude)

```bash
terraform state list | grep -v '^data\.'
curl -fsS -H "X-Octopus-ApiKey: $K" "$U/api/Spaces-1/environments/all"     # Id Name Slug SortOrder
terraform show -json | python3 -c '…print address, tainted…'
OCTOPUS_APIKEY=… terraform plan -out=$SP/space.plan
```
→ State: 4 objects. The environments list was `Development 0`, `Staging 1`, `Production 2`,
**`SIT (Environments-22) sit 3`**. **Octopus appends a new environment after the existing
ones and ignores the requested position.** SIT itself is correct, but it was tainted, so
the plan said "30 to add, **1 to destroy**", which would have replaced it.

Fix: removed `sort_order` from `octopusdeploy_environment.this`, with a comment explaining
why. Promotion order comes from the lifecycle. SIT was kept rather than replaced, because
its slug is what the AWS trust names:
```bash
terraform untaint 'octopusdeploy_environment.this["SIT"]'
OCTOPUS_APIKEY=… terraform plan -input=false -var-file=environments/sit/space.tfvars -out=$SP/space.plan
```
→ **Plan: 29 to add, 0 to change, 0 to destroy** (33 − the 4 already created).
`terraform fmt -check` passed. Committed **`3b408bc`**.

## 10. Operator: apply the remaining 29 (≈ 12:11)

```bash
cd sbsa_besu/octopus/terraform
OCTOPUS_APIKEY="$(aws secretsmanager get-secret-value --region af-south-1 --secret-id sbsa-besu-octopus-terraform-key --query SecretString --output text)" \
  terraform apply $SP/space.plan
```
→ **Apply complete! Resources: 29 added, 0 changed, 0 destroyed.**
```
aws_accounts        = { SIT = "Accounts-21" }
projects            = { infra = "Projects-41", validators = "Projects-42", workloads = "Projects-43" }
runner_worker_pools = { SIT = "besu-runner-sit" }
```
The operator pushed everything up to `3b408bc`.

## 11. Verification (12:12, Claude, read-only)

```bash
for p in Projects-41 Projects-43 Projects-42; do
  curl -fsS -H "X-Octopus-ApiKey: $K" "$U/api/Spaces-1/projects/$p"                       # slug, lifecycle, LVS
  curl -fsS -H "X-Octopus-ApiKey: $K" "$U/api/Spaces-1/projects/$p/deploymentprocesses"   # steps, types, pools, packages, keys
done
curl -fsS -H "X-Octopus-ApiKey: $K" "$U/api/Spaces-1/accounts/Accounts-21"
OCTOPUS_APIKEY=… terraform plan -input=false -detailed-exitcode -var-file=environments/sit/space.tfvars
```
| Project | Slug | Steps (type · pool · package) |
|---|---|---|
| Projects-41 | `besu-infra` | `terraform: shared`, `chain`, `runner`: `Octopus.AwsRunScript` · `WorkerPools-3` (Hosted Ubuntu) · `platform` = `sbsa-besu-platform` @ `feeds-builtin`, Extract True |
| Projects-43 | `besu-workloads` | smoke: `Octopus.Script` · pool variable `Besu.RunnerPool` · `platform` |
| Projects-42 | `besu-validators` | `Approve validator roll …`: `Octopus.Manual`; then `rolling-besu-apply.sh`: `Octopus.Script` · `Besu.RunnerPool` · `platform` |

All three projects use lifecycle `Lifecycles-2` and LVS `LibraryVariableSets-22`. Every step
has environments `[]`, meaning all environments; with SIT the only one, that is correct.
- **Step keys:** the AWS steps carry `Aws.AssumeRole`, `Aws.Region`,
  `AwsAccount.UseInstanceRole`, `AwsAccount.Variable`, `RunOnServer` and `Script.*`. These
  are the keys Octopus saves.
- **Account:** `besu-aws-sit`, `AmazonWebServicesOidcAccount`, role
  `…:role/sbsa-besu-sit-octopus-deploy`, environments `['Environments-22']`, subject keys
  `['space','project','environment']`.
- **Drift:** `plan exit=0`, meaning no changes.

CD-67 ("Applied 2026-10-10 (Phases 1–2)" plus the two lessons) and `test-run-log.md` were
updated. Committed **`edc5094`**.

---

## Left standing (by design)

| Where | What | Cost |
|---|---|---|
| AWS (`besu/octopus/aws-trust.tfstate`) | OIDC provider `avishkarabhishek786.octopus.app`; role `sbsa-besu-sit-octopus-deploy` (**AdministratorAccess**, to be narrowed); secret `sbsa-besu-sit-octopus-deploy-config` (empty until `push-deploy-config.sh`) | ≈ $0.40/month |
| AWS | secret `sbsa-besu-octopus-terraform-key` (key `API-PRE8`, FullAccess, expires 2027-04-08) | ≈ $0.40/month |
| Octopus (`besu/octopus/space.tfstate`) | the 33 objects above | free |
| Laptop | `sbsa_besu/octopus/aws-trust/aws-trust.plan`, untracked; delete it, since it is already applied | — |

## Open after this run

- **Nothing has executed in Octopus.** OIDC on Octopus Cloud's dynamic workers is unproven
  until the first `besu-infra` deployment.
- `Besu.Cluster` and `Besu.DeployConfigSecret` need an unscoped, fail-loud default before
  UAT/PROD.
- Delete pool `sit-ledger-workers` after Phase 4 registers the new runner into
  `besu-runner-sit`.
- Phase 3: `release.yml` (package `sbsa-besu-platform`, push to the built-in feed, create the
  release; CD-8 versioning). Phase 4: the run.

## Lessons

1. **An Octopus API key has its own access level.** A ReadOnly key on a Space-manager
   account plans cleanly, then fails every create with `Missing permission: X []`. Check
   `GET /api/users/<id>/apikeys` → `AccessLevel`; `/api/users/me/permissions` returns 500
   on Cloud, so use `/api/users/<id>/permissions`.
2. **Octopus appends new environments** and ignores `sort_order` on create, and provider
   1.20.0 reports that as an inconsistent result and taints the resource. Don't set
   `sort_order`; if it happens, `untaint` the resource rather than replacing it.
3. **Step properties are untyped.** Check them against steps the instance saved itself
   before trusting them.

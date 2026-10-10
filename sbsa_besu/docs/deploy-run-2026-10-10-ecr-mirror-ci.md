# Deploy run — 2026-10-10 (CI) — the first ECR mirror through GitHub Actions

> **Live log.** Every command executed, in order, with what came back. Times UTC.
> Reconstructed from the session transcript on the same day. **Who ran what is marked on
> each step:** *Claude* ran it from the laptop shell; *operator* ran it, because the
> permission layer refused it to Claude (IAM grants) or it happens in the GitHub UI.

**Source under test:** `shared-eks-namespace` @ `27db178` → `42cfa71` → `9fab5c2` (fixes
landed between runs, below), then `974f9a7` (digest pinning).

**What it must show:** that `.github/workflows/supply-chain.yml`, a **bank deliverable**
(CD-66), mirrors every third-party artefact in `scripts/supply-chain/mirror.manifest` into a
private ECR, from a GitHub-hosted runner, with **no stored AWS keys** (GitHub OIDC → IAM
role, CD-9).

**Shape:** `mimic_registry` (new: the cloud team's CI push grant, mimicked; long-lived) +
four `workflow_dispatch` runs. No VPC, no cluster.

**Outcome:** ✅ run 4 (`38040455269`, 9m28s) created 28 IMMUTABLE, scan-on-push
repositories under `mirror/` and copied 23 images + 5 charts. Digests pinned. Two defects
found and fixed on the way (subject format; `--dry-run` died on missing repositories).

---

## 0. Reconnaissance (08:17 → 08:20, Claude, read-only)

```bash
cat .github/workflows/supply-chain.yml; git remote -v
grep -rn -l "AWS_ECR_PUSH_ROLE_ARN\|ecr-push\|ecr_push" --include=*.tf --include=*.md --include=*.sh --include=*.yml .
grep -n -i -E "sub.claim|AWS_ECR_PUSH_ROLE_ARN|push role|CD-9 |ECR_PREFIX|CD-17|CD-19|CD-26|CD-27|CD-28" sbsa_besu/docs/CICD_DESIGN_NOTES.md
```
→ The workflow expects secrets `AWS_ECR_PUSH_ROLE_ARN`, `ECR_REGISTRY` and variable
`ECR_PREFIX`. Nothing in the repo creates the role.

```bash
P=arn:aws:iam::867728055761:oidc-provider/token.actions.githubusercontent.com
aws iam get-open-id-connect-provider --open-id-connect-provider-arn $P --query '[ClientIDList,CreateDate,Tags]'
for r in $(aws iam list-roles --query 'Roles[].RoleName' --output text); do
  aws iam get-role --role-name $r --query 'Role.AssumeRolePolicyDocument' --output json | grep -q token.actions.githubusercontent.com \
    && { echo "== $r"; aws iam get-role --role-name $r --query 'Role.AssumeRolePolicyDocument.Statement[].Condition'; \
         aws iam list-attached-role-policies --role-name $r --query 'AttachedPolicies[].PolicyName' --output text; }
done
aws ecr describe-repositories --region af-south-1 --query 'length(repositories)'
```
→ GitHub OIDC provider exists (2026-09-06, audience `sts.amazonaws.com`). One role trusts
it: `github-actions-terraform`, for **another** repository, `sub` wildcard
`repo:avishkarabhishek786*/terraform-octopus-demo*:*`. ECR repositories in af-south-1: **0**.
Decision: **reference** the provider, never create or modify it.

```bash
git fetch -q origin; git branch -r; git log --oneline -1 origin/main -- .github/workflows/supply-chain.yml
git diff --stat origin/main HEAD -- .github/workflows/supply-chain.yml sbsa_besu/scripts/supply-chain/ sbsa_besu/scripts/lib/common.sh
sed -n 130,215p sbsa_besu/scripts/supply-chain/mirror.sh                    # repo naming + --create-repos
grep -n -B2 -A12 'variable "container_images"' sbsa_besu/terraform/chain/variables.tf
grep -rn "image_ref *=" -A14 sbsa_besu/terraform/chain/*.tf                 # registry_host + registry_repo_prefixes
command -v gh                                                               # → not installed
curl -s https://api.github.com/repos/avishkarabhishek786/besu-octopus-ghactions-tf-aws \
  | jq -r '.created_at, .default_branch, .id, .owner.id'
```
→ Repositories are `<ECR_PREFIX>/<upstream path>`, created `IMMUTABLE` + `scanOnPush`.
Repository created **2026-09-18** (after GitHub's 2026-07-15 `sub` format change), repo id
`1375347034`, owner id `27818433`.

## 1. `mimic_registry` written (08:21 → 08:30, Claude)

New sibling project `mimic_registry/terraform/` (main, variables, outputs, versions, backend,
`environments/sit/registry.tfvars.example`; real `registry.tfvars` gitignored —
`.gitignore:48 **/environments/*/*.tfvars`). The first write attempt was refused by the
permission layer as a *Permission Grant*; re-issued after the operator's approval (08:26).

```bash
cd mimic_registry/terraform
terraform fmt -recursive
terraform init -input=false -backend-config="bucket=besu-tfstate-867728055761" \
  -backend-config="key=besu/sit/registry.tfstate" -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
terraform validate
terraform plan -input=false -var-file=environments/sit/registry.tfvars -out=$SP/registry.plan
terraform show -json $SP/registry.plan | jq '…assume_role_policy…' ; jq '…policy Statement…'
```
→ **Plan: 2 to add** — `aws_iam_role.ecr_push`, `aws_iam_role_policy.push`. Trust:
`StringEquals` on `aud = sts.amazonaws.com` and `sub ∈ {repo:<owner>/<repo>:ref:refs/heads/main,
…:refs/heads/shared-eks-namespace}`. Permissions: `EcrLogin` (`GetAuthorizationToken` on
`*`), `ListRepositories`, `PushUnderPrefix` and `CreateUnderPrefix` on
`arn:aws:ecr:af-south-1:867728055761:repository/mirror/*` only. No delete, no lifecycle,
no mutability change.

```bash
terraform apply $SP/registry.plan            # Claude: REFUSED by the permission layer (Permission Grant)
```

Workflow change (deliverable): new step **"Show the OIDC subject"** prints the `sub` claim
of the run's token (token masked, never printed; `continue-on-error`). Checked locally:

```bash
python3 -c 'import yaml; d=yaml.safe_load(open(".github/workflows/supply-chain.yml")); print([s.get("name") for s in d["jobs"]["mirror"]["steps"]])'
# decoder against a synthetic token → repo:o/r:ref:refs/heads/main
cd sbsa_besu && ./scripts/supply-chain/mirror.sh --check-drift      # → 8/8 OK, rc=0
```

Recorded **CD-66**; committed **`27db178`** *feat: mimic_registry push grant + OIDC subject
step for supply-chain.yml*.

## 2. Operator: apply the push role, push, configure GitHub (08:30 → 08:51)

```bash
cd mimic_registry/terraform && terraform apply $SP/registry.plan && terraform output     # operator
git push origin shared-eks-namespace                                                     # operator
```
Verified by Claude (08:34):
```bash
aws iam get-role --role-name sbsa-besu-sit-ecr-push --query 'Role.[Arn,CreateDate]' --output text
aws iam list-role-policies --role-name sbsa-besu-sit-ecr-push --query PolicyNames --output text
```
→ `arn:aws:iam::867728055761:role/sbsa-besu-sit-ecr-push`, created **08:33:23**; policy
`ecr-push-under-prefix`.

GitHub → Settings → Secrets and variables → Actions — **Repository** level (operator).
Not Environment level: a job bound to an environment gets `sub = …:environment:<name>`,
which the trust above does not list.

| Kind | Name | Value |
|---|---|---|
| secret | `AWS_ECR_PUSH_ROLE_ARN` | `arn:aws:iam::867728055761:role/sbsa-besu-sit-ecr-push` |
| secret | `ECR_REGISTRY` | `867728055761.dkr.ecr.af-south-1.amazonaws.com` |
| variable | `ECR_PREFIX` | `mirror` |
| variable | `AWS_REGION` | `af-south-1` |
| variable | `CI_RUNNER_LABELS` | `["ubuntu-latest"]` |

## 3. Run 1 — dry run, assume refused (08:51, operator dispatch; Claude read the result)

Actions → supply-chain → Run workflow: branch `shared-eks-namespace`, `dry_run` ✔, scope `all`.

```bash
R=https://api.github.com/repos/avishkarabhishek786/besu-octopus-ghactions-tf-aws
curl -s $R/actions/runs/38039325083 | jq -r '…status, conclusion…'
curl -s $R/actions/runs/38039325083/jobs | jq -r '.jobs[].steps[] | "\(.number). \(.name): \(.conclusion)"'
curl -s <check_run_url>/annotations | jq -r '.[] | "[\(.annotation_level)] \(.message)"'
```
→ **failure**, 08:51:17 → 08:52:36. Steps 1–5 success (drift check, crane+helm, subject
step); **6. Assume the ECR push role: failure** — `Could not assume role with OIDC: Not
authorized to perform sts:AssumeRoleWithWebIdentity`; 7–8 skipped.

```bash
for R in af-south-1 us-east-1; do aws cloudtrail lookup-events --region $R \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --start-time 2026-10-10T08:45:00Z …; done                       # → nothing yet (CloudTrail lag)
# then polled every 30 s in the background — superseded by the operator reading the subject step
```

The operator read step 5's output (08:57):
`repo:avishkarabhishek786@27818433/besu-octopus-ghactions-tf-aws@1375347034:ref:refs/heads/shared-eks-namespace`
— the **ID-suffixed** form, not the plain `repo:<owner>/<repo>:ref:<ref>` the trust listed.

## 4. Fix the trust to the observed subject (08:58, Claude; apply by operator)

`mimic_registry`: new variable `github_ids = { owner, repository }`; for every allowed ref
the trust now lists both the plain and the exact ID-suffixed subject. No wildcard.
`registry.tfvars`: `github_ids = { owner = "27818433", repository = "1375347034" }`.

```bash
terraform fmt && terraform validate
terraform plan -var-file=environments/sit/registry.tfvars -out=$SP/registry2.plan
```
→ **Plan: 0 to add, 1 to change** (`aws_iam_role.ecr_push`, trust only). Subjects:
```
repo:avishkarabhishek786/besu-octopus-ghactions-tf-aws:ref:refs/heads/main
repo:avishkarabhishek786/besu-octopus-ghactions-tf-aws:ref:refs/heads/shared-eks-namespace
repo:avishkarabhishek786@27818433/besu-octopus-ghactions-tf-aws@1375347034:ref:refs/heads/main
repo:avishkarabhishek786@27818433/besu-octopus-ghactions-tf-aws@1375347034:ref:refs/heads/shared-eks-namespace
```
The workflow's trust-policy comment (deliverable) now documents the observed format and
recommends exact matching instead of the `owner*/repo*` wildcard it used to suggest. README
and CD-66 updated. Committed **`42cfa71`** *fix: trust the ID-suffixed OIDC subject GitHub
actually sends*.

```bash
cd mimic_registry/terraform && terraform apply $SP/registry2.plan      # operator
git push origin shared-eks-namespace                                   # operator
```

## 5. Run 2 — assume works, dry run dies on missing repositories (09:02)

Run `38039952570` @ `42cfa71`, same inputs.
```bash
# same run/jobs/annotations queries as §3, plus:
aws iam get-role --role-name sbsa-besu-sit-ecr-push \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals."token.actions.githubusercontent.com:sub"' \
  --output text | tr '\t' '\n' | grep -c @                              # → 2 (ID-suffixed subjects live)
```
→ **failure**, 09:02:01 → 09:02:19. **6. Assume: success (1 s).** 7. Check ECR
repositories exist: success (continue-on-error; reported none exist). **8. Mirror:
failure in 1 s.**

Cause (`sed -n 215,340p scripts/supply-chain/mirror.sh`): the missing-repository check
called `die` even under `--dry-run`, so a dry run never resolved a single upstream. Fix:
under `--dry-run` it warns with the list and continues; a real run without `--create-repos`
still stops. Exercised locally with stub tools:

```bash
bash -n scripts/supply-chain/mirror.sh
mkdir -p $SPB/bin; printf '#!/bin/sh\nexit 1\n' > $SPB/bin/crane; printf '#!/bin/sh\nexit 0\n' > $SPB/bin/helm; chmod +x $SPB/bin/*
PATH=$SPB/bin:$PATH ECR_REGISTRY=867728055761.dkr.ecr.af-south-1.amazonaws.com ECR_PREFIX=mirror AWS_REGION=af-south-1 \
  ./scripts/supply-chain/mirror.sh --dry-run
```
→ `WARN 28 ECR repositories do not exist — a real run needs --create-repos …`, then
proceeds to resolve upstreams (the stub crane fails each — expected locally). Committed
**`9fab5c2`** *fix: mirror.sh --dry-run reports missing repositories instead of dying*;
operator pushed.

## 6. Run 3 — dry run green (09:05)

Run `38040147028` @ `9fab5c2`, `dry_run` ✔, `create_repos` ✘.
→ **success**, 09:05:18 → 09:06:14; Mirror step 40 s. All 28 upstream artefacts resolved.
(The one `failure` annotation is step 7's tolerated "repositories missing" exit.)

## 7. Run 4 — the real mirror (09:10 → 09:20)

Run `38040455269` @ `9fab5c2`, `dry_run` ✘, **`create_repos` ✔**.
```bash
# run/jobs/annotations as before, then:
aws ecr describe-repositories --region af-south-1 \
  --query 'repositories[].[repositoryName,imageTagMutability,imageScanningConfiguration.scanOnPush]' --output text | sort
aws ecr describe-repositories --region af-south-1 --query 'length(repositories)'
```
→ **success**, 09:10:32 → 09:20:13 (**9m28s**; Mirror step 09:10:42 → 09:20:10). Step 7
skipped (`create_repos`). **28 repositories**, every one `IMMUTABLE` / scan-on-push `True`.

Every manifest row checked present at its version:
```bash
M=scripts/supply-chain/mirror.manifest
awk -F'\t' '/^[^#]/ && NF>=5 {print $1"\t"$2"\t"$4"\t"$5}' $M | while IFS=$'\t' read -r kind name path ver; do
  repo="mirror/$path"; [ "$kind" = chart ] && repo="mirror/charts/$path"
  aws ecr describe-images --region af-south-1 --repository-name "$repo" --image-ids imageTag="$ver" \
    --query 'imageDetails[0].[imageDigest,imageSizeInBytes,artifactMediaType || imageManifestMediaType]' --output text
done
```
→ **23 images + 5 charts, all OK.** Multi-arch images kept their index/manifest-list media
type (crane copies by digest, D-18) — e.g. `besu 26.6.1 sha256:ac85d23b4250… 314MB
manifest.list.v2`, `tools 1.30.13 sha256:3ac15bcb3e6f… 311MB`, charts as
`helm.config.v1`.

## 8. Pin the digests; make the drift check compare them (09:21 → 09:23, Claude)

```bash
awk -F'\t' '/^[^#]/ && $1=="image" {print $2"\t"$4"\t"$5}' $M | while IFS=$'\t' read -r name path ver; do
  echo -e "$name\t$(aws ecr describe-images --region af-south-1 --repository-name "mirror/$path" \
    --image-ids imageTag="$ver" --query 'imageDetails[0].imageDigest' --output text)"
done > $SP/digests.tsv                                   # 23 rows, 0 malformed
awk -F'\t' -v OFS='\t' 'NR==FNR {d[$1]=$2; next} $1=="image" && ($2 in d) {$6=d[$2]} {print}' $SP/digests.tsv $M > $M.tmp && mv $M.tmp $M
```
→ manifest digest column filled for all 23 images. A Python edit added `digest = "…"` to the
8 platform images in `terraform/chain/variables.tf` (asserted exactly 8 substitutions).
`mirror.sh --check-drift` now compares the digest as well as host/repo/tag.

```bash
bash -n scripts/supply-chain/mirror.sh && ./scripts/supply-chain/mirror.sh --check-drift      # → all OK
cp terraform/chain/variables.tf $SP/variables.tf.bak
sed -i '0,/digest = "sha256:ac85/s//digest = "sha256:bc85/' terraform/chain/variables.tf
./scripts/supply-chain/mirror.sh --check-drift                                              # → DRIFT: besu …, exit 1
cp $SP/variables.tf.bak terraform/chain/variables.tf && ./scripts/supply-chain/mirror.sh --check-drift   # → exit 0
terraform -chdir=terraform/chain validate                                                  # → valid
```

CD-46 and `test-run-log.md` updated; committed **`974f9a7`** *feat: first CI mirror — pin all
image digests; drift check compares them*; operator pushed.

---

## Left standing (by design)

- IAM role `sbsa-besu-sit-ecr-push` (state `besu/sit/registry.tfstate`) — the long-lived
  push grant. The registry has no expiry (CLAUDE.md §5.2).
- 28 ECR repositories under `mirror/` — ≈ $1/month storage.

## Lessons

1. **Repositories created after 2026-07-15 send an ID-suffixed `sub`**
   (`repo:<owner>@<owner-id>/<repo>@<repo-id>:ref:<ref>`). Match it exactly; read it from
   the run rather than guessing a wildcard.
2. **A dry run must not die on what a real run would create.** It hid every upstream check.
3. **Tag agreement is not enough** between the manifest and Terraform; the digest is what
   gets deployed (H38).

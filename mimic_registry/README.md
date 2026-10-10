# mimic_registry — the cloud team's CI push grant, mimicked

**Not a bank deliverable.** In production the registry is a central shared-services account
and this grant is the cloud team's (CICD notes CD-27, R-5b). This project stands it up in
the personal environment so `.github/workflows/supply-chain.yml` — which *is* a deliverable
— can run unchanged. Decision record: **CD-66**.

## What it creates

One IAM role, assumable only through GitHub OIDC, only by `github_repository` on
`allowed_refs` (exact `sub` match, no wildcards), allowed to log in to ECR, list
repositories, and push and create repositories **only under `<ecr_prefix>/*`**. No delete,
no lifecycle policy, no tag-mutability change — the registry has no expiry (CLAUDE.md §5.2).

It **references** the account's GitHub OIDC provider and does not create it: there is one
per account per URL, and this account's already serves another repository's role.

Long-lived: unlike the deploy-test roots it is not torn down daily, because the images it
lets CI push must outlive every run. ECR storage for the manifest is ~ $1/month.

## Run

```bash
cd mimic_registry/terraform
cp environments/sit/registry.tfvars.example environments/sit/registry.tfvars   # fill in
terraform init -backend-config="bucket=<state-bucket>" -backend-config="key=besu/sit/registry.tfstate" \
  -backend-config="region=<state-region>" -backend-config="use_lockfile=true"
terraform plan  -var-file=environments/sit/registry.tfvars -out=registry.plan
terraform apply registry.plan
terraform output
```

Then, in the GitHub repository (Settings → Secrets and variables → Actions):

| Kind | Name | Value |
|---|---|---|
| secret | `AWS_ECR_PUSH_ROLE_ARN` | `terraform output -raw ecr_push_role_arn` |
| secret | `ECR_REGISTRY` | `terraform output -raw ecr_registry` |
| variable | `ECR_PREFIX` | `terraform output -raw ecr_prefix` |
| variable | `AWS_REGION` | the registry region (af-south-1) |
| variable | `CI_RUNNER_LABELS` | `["ubuntu-latest"]` here; the bank's self-hosted labels there (CD-26) |
| secret (optional) | `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` | avoids Docker Hub's anonymous rate limit |

## If the role is refused

`Not authorized to perform sts:AssumeRoleWithWebIdentity` means the token's `sub` is not
in `terraform output trusted_subjects`. **Seen on the first dry run (2026-10-10):** this
repository postdates GitHub's 2026-07-15 change, and its `sub` is
`repo:<owner>@<owner-id>/<repo>@<repo-id>:ref:<ref>`. Setting `github_ids` generates that
form exactly for every allowed ref. The workflow's **Show the OIDC subject** step
printed the real one (also in the run summary). Add that exact string to
`extra_subjects`, plan, apply, re-run. Never replace it with a wildcard.

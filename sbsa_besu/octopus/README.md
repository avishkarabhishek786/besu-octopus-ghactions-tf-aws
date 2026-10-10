# octopus/ — the Octopus side of the platform, as code

**A bank deliverable.** Everything here is reviewable and parameterised; nothing names a
person, an instance or an account (CD-10). Design record: `docs/CICD_DESIGN_NOTES.md`
§5–§8 and **CD-67**.

| Path | What | Applied by |
|---|---|---|
| `aws-trust/` | The IAM OIDC provider for the Octopus instance; one deploy role per environment, trusted **only** for `space:<s>:project:<p>:environment:<e>`; one empty deploy-config secret per environment | **A human, once per account — never Octopus.** A deploy tool must not be able to edit its own trust |
| `terraform/` | The Octopus space's objects: environments, the CD-41 lifecycle, a worker pool per environment for the In-VPC EC2 Runner, an AWS OIDC account per environment, the `Besu platform` variable set, and the three projects with their processes | A human with a Space-manager service-account key (`OCTOPUS_APIKEY`) |
| `steps/` | The scripts the project steps run, **from the release package** — so step logic is versioned with what it deploys | Octopus |

## The three projects (CD-4, CD-5)

| Project | Runs on | Does |
|---|---|---|
| `besu-infra` | Octopus hosted worker + OIDC account | Terraform `shared` → `chain` (AWS layer) → `runner`; each plan attached as an artefact, the attached plan applied. Approval step in the approval environments |
| `besu-workloads` | The runner's polling Tentacle (`besu-runner-<env>` pool) | Until the CT-5 rewrite: cluster smoke — nodes, a quota'd namespace, the #38 pull canary, C-2 DNS (CD-67). Never the validator release |
| `besu-validators` | The runner's Tentacle | **Manual intervention in every environment**, then `rolling-besu-apply.sh` — one validator at a time (H1) |

## Order of operations

```bash
# 1. AWS trust (human, once): role ARNs + secret names out
cd octopus/aws-trust && terraform init -backend-config=… key=besu/octopus/aws-trust.tfstate … && terraform apply -var-file=environments/sit/aws-trust.tfvars
# 2. Environment config into the env's secret (laptop, after mimic/hand-over files exist)
ENV=sit AWS_REGION=af-south-1 scripts/runner/push-deploy-config.sh <prefix>-sit-octopus-deploy-config
# 3. The space (human, Space-manager key in OCTOPUS_APIKEY). The KEY's access level must be
#    read-write ("FullAccess"): a ReadOnly key on a Space-manager account plans cleanly, then
#    every create fails "Missing permission: EnvironmentCreate []" (seen 2026-10-10).
#    Check: GET /api/users/<id>/apikeys → AccessLevel.
cd octopus/terraform && terraform init -backend-config=… key=besu/octopus/space.tfstate … && terraform apply -var-file=environments/sit/space.tfvars
# 4. Releases come from release.yml; deployments from Octopus
```

## Known limits, said plainly

- **Step property names are not typed by the provider** (1.20.0). They are verified against the
  instance's own step templates before the first deployment; a wrong key is ignored, not
  rejected.
- **The deploy role is broad** (`AdministratorAccess`) — the reach the operator's laptop has
  today. Narrowing it is follow-up work, in `aws-trust`'s `deploy_policy_arns`.
- **`besu-workloads` does not deploy workloads yet** — it proves the path (CD-67).

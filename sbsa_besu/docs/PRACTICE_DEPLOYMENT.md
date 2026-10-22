# Practice deployment — the whole stack, from an empty account, one step at a time

**What this is:** the reusable operator walkthrough for a SIT practice deployment in our own AWS
account: mimic network + proxy → Octopus builds the AWS layer → the runner joins Octopus →
Octopus installs the chain → you send a transaction → everything is deleted. A simple version
of RUNBOOK E.3 + E.4, written as if **nothing exists yet**. First proven end to end (minus the
transaction) on 2026-10-17: `deploy-run-2026-10-17-practice.md`.

**Rule:** treat every practice as a **first-time deployment**. No step is skipped because it was
done last time. Steps that persist between runs (Part A) say what "already done" looks like —
run them anyway and confirm that answer.

**Each step has:** **Why** · the commands · **Should see** · **🔁 Already done looks like**
(Part A) · **🏦 In the bank** where it differs.

**Cost:** Part A is free or cents. Part B bills **≈ $2/hour** from B5 until T5 finishes; a clean
run is ≈ 2 hours ≈ **$4**. Same-day teardown is mandatory.

**Rules for the day**
- One step at a time. Check **Should see** before the next one. If it doesn't match, **stop** and
  paste the output — don't improvise a fix.
- Never paste a secret (private key, API key) into chat or onto a command line. `read -rs`, or a
  keystore.
- Write the log as you go (B0) — a row per step, failures included.

```
PART A — one-time setup (persists)                     PART B — the run (billable, torn down)
A0 tools + terminal                                    B0 log + empty-account check + tags
A1 state buckets + backends                            B1 mimic_vpc        (network)
A2 ECR push grant (mimic_registry) ─► A3 mirror        B2 mimic_egress     (proxy)
A4 Octopus→AWS trust ─┐                                B3 push-deploy-config
A5 Space-manager key ─┴► A6 Octopus space ─► A7 CI     B4 release besu-infra (shared → chain → runner)
A8 Tentacle secrets                                    B5 runner check → B6 fingerprint → B7 Tentacle
A9 tfvars + the test sender key                        B8 release besu-workloads → B9 tunnel → B10 tx
                                                       T1–T8 teardown + zero-check
```

---

# Part A — one-time setup

In a brand-new account, every step creates something. On a later practice, every step should
come back **"already done"** — that confirmation is the point of running it.

## A0 — Tools and terminal (laptop · free)

**Why:** every later step uses these tools and variables; a wrong Terraform version cannot even
`init` our backends (`use_lockfile` needs ≥ 1.10).

```bash
terraform version          # 1.16.1 — the pin in sbsa_besu/scripts/runner/runner-tools.manifest
aws --version; jq --version; session-manager-plugin --version; openssl version
cast --version             # Foundry, for B10
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

export REPO=~/Documents/Blockchain/Besu/besu-octopus-ghactions-tf-aws
export D=$(date -u +%F)                  # today, e.g. 2026-10-24 — used for tags and the log
export SP=~/besu-run-$D; mkdir -p $SP    # plan files
export ACCT=$(aws sts get-caller-identity --query Account --output text); echo $ACCT
cd $REPO && sbsa_besu/scripts/preflight/verify-region.sh af-south-1 m6i.xlarge 1.35
```

**Should see:** the versions; your account ID; `verify-region.sh` → **7 passed / 0 failed**
(af-south-1 is opt-in — it must be enabled; m6i.xlarge in all 3 AZs; all endpoint services).

> **New terminal later?** Re-run the `export` lines. Variables live only in the terminal that
> set them — on 10-17 an empty `$RUNNER` sent a command to no machine, silently.

## A1 — Terraform state buckets and backends (laptop · cents/month)

**Why:** state is how Terraform knows what it built. Two buckets: **af-south-1** for the
platform roots, because the runner is air-gapped in af-south-1 and can only reach same-region
S3 (B49); **us-east-1** for the mimics and Octopus roots, which only ever run from the laptop.

```bash
for b in "besu-tfstate-$ACCT:us-east-1" "besu-tfstate-$ACCT-afs1:af-south-1"; do
  n=${b%%:*}; r=${b##*:}
  if [ "$r" = us-east-1 ]; then aws s3api create-bucket --bucket $n --region $r
  else aws s3api create-bucket --bucket $n --region $r --create-bucket-configuration LocationConstraint=$r; fi
  aws s3api put-bucket-versioning --bucket $n --versioning-configuration Status=Enabled
  aws s3api put-public-access-block --bucket $n --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket $n --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
done
```

Then initialise the five roots you'll plan/destroy from the laptop:

```bash
ini() { terraform -chdir=$1 init -reconfigure -backend-config="bucket=$2" -backend-config="key=$3" \
          -backend-config="region=$4" -backend-config="use_lockfile=true"; }
ini $REPO/mimic_vpc/terraform           besu-tfstate-$ACCT      besu/sit/network.tfstate us-east-1
ini $REPO/mimic_egress/terraform        besu-tfstate-$ACCT      besu/sit/egress.tfstate  us-east-1
for r in shared chain runner; do
  ini $REPO/sbsa_besu/terraform/$r      besu-tfstate-$ACCT-afs1 besu/sit/$r.tfstate      af-south-1
done
```

**Should see:** `Terraform has been successfully initialized!` ×5.
**🔁 Already done looks like:** `create-bucket` → `BucketAlreadyOwnedByYou` (fine — the three
`put-…` calls just re-apply the same settings); `init` succeeds.
**Why `-reconfigure`:** a folder initialised on an older bucket keeps pointing at it; B49 moved
platform state, and an old init silently reads empty state from the wrong place.

## A2 — Let CI push to ECR: `mimic_registry` (laptop · free)

**Why:** GitHub Actions (internet, no AWS keys) fills our private registry. This creates one IAM
role it can assume through **GitHub OIDC** — a short-lived token, nothing stored — allowed only
to push under `mirror/*`: never delete, never change expiry.

**First, the account's GitHub OIDC provider** — what makes AWS accept GitHub's tokens at all.
There is **one per account** for `token.actions.githubusercontent.com`, shared by every role that
trusts GitHub, so `mimic_registry` only **reads** it (a `data` source) and never creates or
destroys it. In an account that has none, the plan below fails on that lookup. Check, and create
it only if missing:

```bash
aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?ends_with(Arn,'/token.actions.githubusercontent.com')].Arn" \
  --output text | grep . || \
  aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com
#   no --thumbprint-list: IAM fetches it, and for GitHub it validates against its own trusted CAs
```

**Never delete it in a teardown or reset** — other repositories' roles may trust it (ours does since
2026-09-06), and nothing in this repo would put it back.

```bash
cd $REPO/mimic_registry/terraform
cp -n environments/sit/registry.tfvars.example environments/sit/registry.tfvars   # -n: never overwrite yours
#   edit registry.tfvars (github repository, allowed refs incl. refs/heads/shared-eks-namespace)
terraform init -reconfigure -backend-config="bucket=besu-tfstate-$ACCT" -backend-config="key=besu/sit/registry.tfstate" \
  -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
terraform plan -var-file=environments/sit/registry.tfvars -out=$SP/registry.plan
terraform show -no-color $SP/registry.plan | grep -E '^Plan:|No changes'
terraform apply $SP/registry.plan          # skip if "No changes"
terraform output
```

GitHub → repo **Settings → Secrets and variables → Actions**:

| Kind | Name | Value |
|---|---|---|
| secret | `AWS_ECR_PUSH_ROLE_ARN` | `terraform output -raw ecr_push_role_arn` |
| secret | `ECR_REGISTRY` | `terraform output -raw ecr_registry` |
| variable | `ECR_PREFIX` | `terraform output -raw ecr_prefix` |
| variable | `AWS_REGION` | `af-south-1` |
| variable | `CI_RUNNER_LABELS` | `["ubuntu-latest"]` (JSON) |
| variable | `RELEASE_RUNNER_LABELS` | `["ubuntu-latest"]` (JSON) |

**🔁 Already done looks like:** the provider check prints its ARN (nothing created);
`No changes. Your infrastructure matches the configuration.`; and the six entries already listed in GitHub.
**🏦 In the bank:** the registry is the cloud team's shared-services ECR (CD-27); the push role is
theirs to grant (R-7). **The GitHub OIDC provider is theirs too, and may not exist at all.** It
lives in the account holding the push role (theirs), and is needed only if their runners use GitHub
OIDC. If the runners are pods (IRSA, CD-49) or VMs (instance profile), there is no provider and the
workflow's `configure-aws-credentials` step is **removed**, not reconfigured. What we hand over
either way: the exact `sub` value(s) and the push permissions under our prefix — both generated by
`mimic_registry`.

> **Reading a saved plan:** `.plan` files are binary. `terraform show $SP/x.plan` for the list;
> `terraform show -no-color … | grep '^Plan:'` for the count — without `-no-color`, colour codes
> in front of `Plan:` stop `grep` matching and you get nothing.

## A3 — Fill the mirror: `supply-chain.yml` (GitHub · cents)

**Why:** the VPC has no internet, so every image and Helm chart must already be in our ECR. A
missing one doesn't error — **the pull hangs**. The list, pinned by digest, is
`sbsa_besu/scripts/supply-chain/mirror.manifest`; `crane` copies keep digests identical (D-18).

1. GitHub → **Actions → supply-chain → Run workflow**, branch `shared-eks-namespace`,
   **`dry_run` ON**, scope `all`. Read the report: what would be copied.
2. Again with **`dry_run` OFF**, scope `all`, **`create_repos` ON**.

```bash
aws ecr describe-repositories --region af-south-1 --query 'length(repositories)' --output text   # → 29 (as of 2026-10)
```

**🔁 Already done looks like:** every image and chart reports **"already present"** (tags are
immutable, so a re-run cannot overwrite anything) and the count doesn't change. Anything *not*
already present means the manifest moved on since the last run — exactly why this is never skipped.
**🏦 In the bank:** who runs the mirror pipeline is open (Q-4d); repositories need a prefix and a
create path from the cloud team (point 19 / R-5b).

## A4 — Octopus → AWS trust: `octopus/aws-trust` (laptop, AWS admin · ~$0.40/month)

**Why:** Octopus must create AWS resources with no AWS keys stored in it. This creates an OIDC
provider for your Octopus instance, a deploy role per environment that **only**
`space:<s>:project:besu-infra:environment:<e>` can assume, and the empty
`sbsa-besu-<env>-octopus-deploy-config` secret that B3 fills. **A human applies this, never
Octopus** — a deploy tool must not edit its own trust.

**Prerequisite:** an Octopus Cloud instance exists and you know its name (`<instance>` in
`https://<instance>.octopus.app`). 🏦 In the bank that name also goes into the R-10 egress ticket.

```bash
cd $REPO/sbsa_besu/octopus/aws-trust
cp -n environments/sit/aws-trust.tfvars.example environments/sit/aws-trust.tfvars   # set octopus_server_url, owner, cost_center
terraform init -reconfigure -backend-config="bucket=besu-tfstate-$ACCT" -backend-config="key=besu/octopus/aws-trust.tfstate" \
  -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
terraform plan -var-file=environments/sit/aws-trust.tfvars -out=$SP/aws-trust.plan
terraform show -no-color $SP/aws-trust.plan | grep -E '^Plan:|No changes'
terraform apply $SP/aws-trust.plan        # skip if "No changes"
terraform output                          # deploy_role_arns → A6
```

**🔁 Already done looks like:** `No changes`.

## A5 — Octopus Space-manager API key (Octopus UI → Secrets Manager)

**Why:** A6 manages Octopus through its API. In Octopus: a **service account** `besu-terraform`,
in a **team** with **Space manager** on the space (team **saved**); an **API key** for it with
access level **read-write** — a ReadOnly key plans cleanly, then every create fails (10-10).
Store it so it never touches a command line or your shell history:

```bash
aws secretsmanager describe-secret --region af-south-1 --secret-id sbsa-besu-octopus-terraform-key \
  --query Name --output text 2>/dev/null || {
  read -rs K && aws secretsmanager create-secret --region af-south-1 \
    --name sbsa-besu-octopus-terraform-key --secret-string "$K"; unset K; }
```

**🔁 Already done looks like:** `describe-secret` prints the name, so nothing is created. To
rotate instead: `read -rs K && aws secretsmanager put-secret-value … --secret-string "$K"; unset K`.

## A6 — The Octopus space as code: `octopus/terraform` (laptop · free)

**Why:** environments, lifecycle, the runner's worker pool (`besu-runner-sit`), the AWS OIDC
account, the `Besu platform` variables and the three projects with their steps — in code, so the
bank gets the Octopus we tested. **Must be re-applied after any commit touching
`sbsa_besu/octopus/terraform/`**, or Octopus runs the old steps.

```bash
cd $REPO/sbsa_besu/octopus/terraform
cp -n environments/sit/space.tfvars.example environments/sit/space.tfvars
#   aws_role_arns ← A4's output; state_bucket = besu-tfstate-$ACCT-afs1 and state_region = af-south-1
#   (B49 — must equal aws_region); tools_image = the alpine/k8s digest from mirror.manifest
terraform init -reconfigure -backend-config="bucket=besu-tfstate-$ACCT" -backend-config="key=besu/octopus/space.tfstate" \
  -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
export OCTOPUS_APIKEY="$(aws secretsmanager get-secret-value --region af-south-1 \
  --secret-id sbsa-besu-octopus-terraform-key --query SecretString --output text)"
terraform plan -var-file=environments/sit/space.tfvars -out=$SP/space.plan
terraform show -no-color $SP/space.plan | grep -E '^Plan:|No changes'
terraform apply $SP/space.plan            # skip if "No changes"
unset OCTOPUS_APIKEY
```

**🔁 Already done looks like:** `No changes`. Don't set an environment `sort_order`: provider
1.20.0 taints it; if that happens, `terraform untaint`, never replace.
**🏦 In the bank:** the bank's Octopus admin applies the same code (R-8: own space or shared?).

## A7 — GitHub → Octopus trust: `octopus/ci-trust` + GitHub variables (Octopus **administrator**)

**Why:** lets GitHub Actions create releases in Octopus via OIDC — **no Octopus key in GitHub**.
Creates the `besu-ci` service account, its GitHub identities (exact branch refs) and two narrow
roles (publish; deploy to **SIT only**). Needs an **administrator's** key, not A5's: a pipeline
must not be able to edit its own permissions.

```bash
cd $REPO/sbsa_besu/octopus/ci-trust
cp -n environments/sit/ci-trust.tfvars.example environments/sit/ci-trust.tfvars
#   allowed_refs must include the branch you release from: refs/heads/shared-eks-namespace
terraform init -reconfigure -backend-config="bucket=besu-tfstate-$ACCT" -backend-config="key=besu/octopus/ci-trust.tfstate" \
  -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
read -rs OCTOPUS_APIKEY && export OCTOPUS_APIKEY      # the ADMIN key, typed, never stored
terraform plan -var-file=environments/sit/ci-trust.tfvars -out=$SP/ci-trust.plan
terraform show -no-color $SP/ci-trust.plan | grep -E '^Plan:|No changes'
terraform apply $SP/ci-trust.plan         # skip if "No changes"
terraform output service_account
unset OCTOPUS_APIKEY
```

GitHub → **Settings → Secrets and variables → Actions → Variables**: `OCTOPUS_URL`,
`OCTOPUS_SPACE`, `OCTOPUS_SERVICE_ACCOUNT_ID` (the GUID from the output).
**Test:** **Actions → release → Run workflow**, project **`none`** — packages, signs in to Octopus,
deploys nothing. Must be green.

**🔁 Already done looks like:** `No changes`, the three variables present, and the `none` release green.

## A8 — Tentacle registration secrets (laptop · free)

**Why:** B7 registers the runner as an Octopus worker. It reads the registration key from
Secrets Manager — never a file or command line — and stores the Tentacle's certificate so a
rebuilt runner comes back as the **same** worker (CD-61). The key belongs to a service account
in a team with a **Space-scoped role** (Environment manager is enough — CD-65), **team saved**.

```bash
# names stuck in a deletion window are invisible to plain list-secrets but block the name:
aws secretsmanager list-secrets --region af-south-1 --include-planned-deletion \
  --query 'SecretList[].[Name,DeletedDate]' --output text
aws secretsmanager describe-secret --region af-south-1 --secret-id sbsa-besu-primary-octopus-register-key \
  --query Name --output text 2>/dev/null || {
  read -rs K && aws secretsmanager create-secret --region af-south-1 \
    --name sbsa-besu-primary-octopus-register-key --secret-string "$K"; unset K; }
aws secretsmanager describe-secret --region af-south-1 --secret-id sbsa-besu-primary-tentacle-cert \
  --query Name --output text 2>/dev/null || \
  aws secretsmanager create-secret --region af-south-1 --name sbsa-besu-primary-tentacle-cert
#   ↑ NO --secret-string: EMPTY on purpose. install-tentacle.sh generates a certificate only when
#     the secret has no value; any placeholder (even '{}') is read as a certificate and fails.
```

**🔁 Already done looks like:** both names printed by `describe-secret`, nothing created. The
cert secret then already holds the certificate from an earlier run — keep it, that's CD-61.

## A9 — The environment's tfvars, and the test sender key (laptop · free)

**Why:** four gitignored files carry everything environment-specific. And the chain's **only**
source of funds is genesis (F20 — no faucet), so the account you'll send from in B10 must be
**in genesis before B3**. Only its **address** travels through the pipeline (tfvars → B3 → genesis
in B8); **the private key never does** — on 10-17 nobody had it at B10 and the transaction was lost.

**The sender key first** — kept in an encrypted Foundry keystore, so the raw key never sits in a
shell variable or your history:

```bash
cast wallet list | grep -q besu-sit-sender || {
  cast wallet new                                    # prints Address + Private key ONCE
  cast wallet import besu-sit-sender --interactive   # paste that key, choose a password
}
cast wallet address --account besu-sit-sender        # → the address for genesis_funded_accounts
```

**Then the tfvars** (`cp -n` never overwrites yours):

```bash
cd $REPO
cp -n mimic_vpc/terraform/environments/sit/primary.tfvars.example    mimic_vpc/terraform/environments/sit/primary.tfvars
cp -n mimic_egress/terraform/environments/sit/primary.tfvars.example mimic_egress/terraform/environments/sit/primary.tfvars
cp -n sbsa_besu/terraform/environments/sit/common.tfvars.example     sbsa_besu/terraform/environments/sit/common.tfvars
cp -n sbsa_besu/terraform/environments/sit/chain.tfvars.example      sbsa_besu/terraform/environments/sit/chain.tfvars
```

| File | Must contain |
|---|---|
| `mimic_vpc/…/primary.tfvars` | `az_ids` (yours: `aws ec2 describe-availability-zones --region af-south-1 --query 'AvailabilityZones[].ZoneId'`), `pinned_ip_reservations = { "afs1-az1" = "10.60.0.250" }` (B43) |
| `mimic_egress/…/primary.tfvars` | `octopus_instance` = your instance name; `runner_private_ip = "10.60.0.250"` |
| `sbsa_besu/…/common.tfvars` | project, environment `sit`, owner, cost_center, `primary_region = "af-south-1"` |
| `sbsa_besu/…/chain.tfvars` | `chain_id` (non-zero), `registry_host = "<ACCT>.dkr.ecr.af-south-1.amazonaws.com"`, `registry_repo_prefixes`, `registry_chart_path = "mirror/charts"`, `registry_cert_publicly_trusted = true`, **`genesis_funded_accounts = ["<the address above>"]`** |

```bash
grep -h '^genesis_funded_accounts' sbsa_besu/terraform/environments/sit/chain.tfvars
cast wallet address --account besu-sit-sender     # the two addresses must match
```

**🔁 Already done looks like:** the keystore exists, the files exist (`cp -n` leaves them alone),
and the two addresses match. **If they don't match, fix it now** — after B8 it means rebuilding
the chain.

---

# Part B — the run (billable from B4)

## B0 — Start the log, check the account is empty, tag today's resources (laptop · free)

**Why:** a log written live is the record (a row per step, failures included); an empty account
means anything found at the end was made today; a **new `deletion_group` per run** means teardown
and zero-check find exactly today's resources and nothing else.

```bash
cd $REPO
L=sbsa_besu/docs/deploy-run-$D-practice.md
[ -f $L ] || printf '# Practice run — %s\n\nFollowing `PRACTICE_DEPLOYMENT.md`. Times UTC.\n\n| Time | Step | Who | Result |\n|---|---|---|---|\n' "$D" > $L

aws ec2 describe-vpcs --region af-south-1 --filters Name=is-default,Values=false --query 'Vpcs[].VpcId' --output text   # → empty
aws eks list-clusters --region af-south-1 --query clusters --output text                                               # → empty

sed -i -E "/^deletion_group/s/[0-9]{4}-[0-9]{2}-[0-9]{2}/$D/" \
  mimic_vpc/terraform/environments/sit/primary.tfvars \
  mimic_egress/terraform/environments/sit/primary.tfvars \
  sbsa_besu/terraform/environments/sit/common.tfvars
grep -h '^deletion_group' mimic_vpc/terraform/environments/sit/primary.tfvars \
  mimic_egress/terraform/environments/sit/primary.tfvars sbsa_besu/terraform/environments/sit/common.tfvars
```

**Should see:** both lists empty; three `deletion_group` lines ending in **today's date**.

## B1 — The fake bank network: `mimic_vpc` (laptop · ~free · ~3 min)

**Why:** in the bank the cloud team hands us a VPC; here we impersonate it — **no internet**, on
purpose. The platform learns its IDs from a **hand-over file**, never from the mimic's state,
because the real cloud team will never share theirs.

```bash
cd $REPO/mimic_vpc/terraform
terraform plan -var-file=environments/sit/primary.tfvars -out=$SP/mvpc.plan
terraform show -no-color $SP/mvpc.plan | grep '^Plan:'     # ~347 to add, 0 to change, 0 to destroy — STOP and check
terraform apply $SP/mvpc.plan
cd .. && ./scripts/verify-contract.sh && ./scripts/emit-handover.sh
grep '^vpc_id' network-handover.auto.tfvars                # today's VPC — note it for B2
```

- **`verify-contract.sh`** (read-only) asks the **live AWS API** whether the VPC meets what the
  platform needs — default tenancy, DNS on, the LB subnet tag, 3 AZs, **no `0.0.0.0/0` route** —
  each check citing its requirement number. → **27 passed**.
- **`emit-handover.sh`** writes the IDs to `network-handover.auto.tfvars` and links it into the
  platform roots. It writes to a temp file first, so a half-read hand-over can't replace a good one (B19).

**🏦 In the bank:** no mimic — type the cloud team's IDs into the same hand-over file and run
`verify-contract.sh <vpc-id> af-south-1` against their VPC.

## B2 — The fake bank proxy: `mimic_egress` (laptop · ~$0.03/h · ~3 min)

**Why:** the runner reaches Octopus Cloud only through the bank's proxy, which allows exactly two
Octopus hostnames. This builds a copy. **The `cp` is not optional:** this root keeps its *own*
copy of the network hand-over; skip it and it peers with a deleted VPC (10-11).

```bash
cd $REPO/mimic_egress
cp ../mimic_vpc/network-handover.auto.tfvars terraform/
V=$(grep '^vpc_id' terraform/network-handover.auto.tfvars | cut -d'"' -f2); echo $V
cd terraform
terraform plan -var-file=environments/sit/primary.tfvars -out=$SP/egress.plan
terraform show -no-color $SP/egress.plan | grep -E "^Plan:|$V" | head -5
#   STOP: "29 to add, 0 to change, 0 to destroy" AND at least one line with today's $V
terraform apply $SP/egress.plan
cd .. && ./scripts/emit-handover.sh
terraform -chdir=terraform output     # peering_connection_id, proxy_instance_id → checks below
```

Check what AWS says now, not what the apply said:

```bash
aws ec2 describe-vpc-peering-connections --region af-south-1 --vpc-peering-connection-ids <pcx-…> \
  --query 'VpcPeeringConnections[0].Status.Code' --output text          # → active
aws ec2 describe-instances --region af-south-1 --instance-ids <i-…> \
  --query 'Reservations[0].Instances[0].State.Name' --output text        # → running
```

**🏦 In the bank:** no mimic — the **R-10** ticket (proxy `host:port`; source = the runner's /32;
the two Octopus hostnames, 443, CONNECT only; **no TLS decryption**; a route from the ledger
subnets; credentials y/n; the runner's IP **reserved**). The reply is typed into
`sbsa_besu/terraform/egress-handover.auto.tfvars`.

## B3 — Send the environment's config: `push-deploy-config.sh` (laptop · free)

**Why:** the four gitignored files (A9 + both hand-overs) reach Octopus and the runner in one
Secrets Manager secret. **Only now** — before B1/B2 it would ship a stale VPC (10-11).

```bash
cd $REPO/sbsa_besu
ENV=sit AWS_REGION=af-south-1 scripts/runner/push-deploy-config.sh sbsa-besu-sit-octopus-deploy-config
# check what's inside without printing secrets:
T=$(mktemp -d); aws secretsmanager get-secret-value --region af-south-1 --secret-id sbsa-besu-sit-octopus-deploy-config \
  --query SecretString --output text | base64 -d | tar xzf - -C $T
grep -rhE '^(vpc_id|deletion_group|egress_proxy_host|egress_allowed_source|genesis_funded_accounts) ' $T; rm -rf $T
```

**Should see:** **`4 file(s)`**; today's `vpc_id`, today's `deletion_group`, the proxy, `10.60.0.250/32`,
and the sender address from A9.

## B4 — The AWS layer from Octopus: release `besu-infra` (GitHub · 💰 billing starts · ~25 min)

**Why:** the real path — GitHub packages, Octopus deploys. Four steps on a hosted worker:
`shared` (15 VPC endpoints — how a private subnet reaches AWS) → `chain` (EKS + 4 nodes, KMS,
secrets, NLB, buckets) → runner bundle (toolchain + source + provider mirror to S3) → `runner`
(the EC2 box at `10.60.0.250`, the only machine that can reach the private cluster).

**GitHub → Actions → release → Run workflow** → `shared-eks-namespace`, project **`besu-infra`**.

Follow it from the terminal (the deployment URL ends in `Deployments-NN`):

```bash
K="$(aws secretsmanager get-secret-value --region af-south-1 --secret-id sbsa-besu-octopus-terraform-key --query SecretString --output text)"
U=https://<instance>.octopus.app/api/Spaces-1
T=$(curl -s -H "X-Octopus-ApiKey: $K" $U/deployments/Deployments-NN | jq -r .TaskId); echo $T
curl -s -H "X-Octopus-ApiKey: $K" "$U/tasks/$T/details?verbose=false" \
  | jq -r '.ActivityLogs[0].Children[] | "\(.Name)\t\(.Status)\t\(.Started)\t\(.Ended)"'
curl -s -H "X-Octopus-ApiKey: $K" $U/tasks/$T/raw | grep -E 'Plan: [0-9]|Apply complete'
unset K
```

**Should see:** all four steps green; `shared` **27**, `chain` **106**, `runner` **13** added.

**🏦 In the bank:** `shared` creates ~nothing (their endpoints, `central_interface_endpoints = true`);
`chain` creates only what's ours (KMS, secrets, IRSA roles, NLB…) once the root is split — see the
🏦 box under Step 5 of `deploy-run-2026-10-17-practice.md`, and points 4/5/6/22 of the cloud-team
discussion document.

## B5 — Did the runner boot correctly? (laptop · read-only)

**Why:** the runner has no internet; everything comes from S3 at boot. Check it once now rather
than debug it later.

```bash
export RUNNER=$(terraform -chdir=$REPO/sbsa_besu/terraform/runner output -raw runner_instance_id)
: "${RUNNER:?RUNNER is empty — check the runner root is initialised on the afs1 bucket (A1)}"
C=$(aws ssm send-command --region af-south-1 --instance-ids $RUNNER --document-name AWS-RunShellScript \
  --parameters 'commands=["cloud-init status; cat /opt/besu-deploy/BOOTSTRAP_STATUS"]' \
  --query Command.CommandId --output text)
sleep 5; aws ssm get-command-invocation --region af-south-1 --command-id $C --instance-id $RUNNER \
  --query StandardOutputContent --output text
```

**Should see:** `status: done` · `OK: tools=5 source=<sha>/<release> deploy-config: extracted`.
**The `${RUNNER:?}` guard** stops here if the variable is empty — AWS accepts a command with no
target as "Success" and runs it nowhere.

## B6 — Measure Octopus's certificate, and print the B7 command (laptop · free)

**Why:** B7 checks the proxy does **not** decrypt traffic by comparing the certificate seen
*through* the proxy with the one you see *directly*. The value must travel to the runner by
copy-paste — so this step **prints the finished B7 command** with it inside. (A placeholder to
fill in by hand was pasted unfilled twice; a value written into the docs goes stale on rotation.)

```bash
I=<instance>      # your Octopus instance name
H=polling.$I.octopus.app
FP=$(openssl s_client -connect $H:443 -servername $H </dev/null 2>/dev/null \
     | openssl x509 -fingerprint -sha256 -noout | cut -d= -f2); echo "FP=$FP"
[ -n "$FP" ] && cat <<EOF
sudo env OCTOPUS_INSTANCE=$I OCTOPUS_SPACE='Default' OCTOPUS_WORKER_POOL=besu-runner-sit \\
  OCTOPUS_API_KEY_SECRET=sbsa-besu-primary-octopus-register-key \\
  EXPECTED_POLLING_CERT_SHA256='$FP' \\
  TENTACLE_CERT_SECRET=sbsa-besu-primary-tentacle-cert \\
  bash /opt/besu-deploy/sbsa_besu/scripts/runner/install-tentacle.sh
EOF
```

**Should see:** `FP=` followed by 32 hex pairs, then the command. Nothing printed after `FP=` →
`openssl` failed; run it again.

## B7 — The runner becomes an Octopus worker: `install-tentacle.sh` (runner · free)

**Why:** `besu-workloads` runs *on the runner* — only it can reach the cluster. The Tentacle
**polls out** through the proxy; nothing connects in. The script runs 7 probes first (allowed ×2,
refused ×3, no-interception, …) and refuses to register on any failure.

```bash
aws ssm start-session --target $RUNNER --region af-south-1
```

In that session, paste **the command B6 printed**. Read the output, **then** type `exit` on its own.
In Octopus: **Infrastructure → Workers →** `ip-10-60-0-250` **→ Check health** → **Healthy**.

**Should see:** 7/7 PASS, `Machine registered successfully`, `OK tentacle.service running…`.
First time ever: a new worker. Every later run: the **same** worker updated in place (cert from A8).
**If probe 7 fails:** compare its two values. *Through the proxy* = what the runner sees;
*baseline* = what you passed. A placeholder or typo in the baseline is your input, not the
network — fix and re-run (idempotent). Only through-proxy ≠ your laptop's value means decryption.

## B8 — Install the chain: release `besu-workloads` (GitHub → runner · ~5 min)

**Why:** everything *inside* the cluster — CSI drivers, LB controller, monitoring, genesis (with
your A9 sender funded), 4 validators, bootnodes, RPC, Blockscout — all from the mirror.
Gates: **#38 canary** (the *cluster* can pull, not just us), **F19** (RPC certs before RPC pods),
**CD-53** (only in-cluster changes), **CD-5** (never touch a running validator).

**GitHub → Actions → release → Run workflow** → `shared-eks-namespace`, project **`besu-workloads`**.
Follow it with the B4 commands.

**Should see:** smoke PASS ×3 → `Plan: 19 to add` → CD-53 OK → CD-5 OK →
**`Apply complete! Resources: 19 added`** → `verify-deployed.sh`: **PASS 4/4 validators Ready,
PASS 4 distinct nodes**.
> ⚠️ **Expected red (until fixed):** `verify-deployed.sh` **#33 FAIL** (the mock cluster has no
> security groups for pods) makes the step **Failed although the install succeeded**. Check the
> `Apply complete` and the two PASS lines.

## B9 — Tunnel to the chain (laptop + runner · free)

**Why:** nothing in the cluster is public. Path: laptop → SSM → runner → `kubectl port-forward` →
service. The runner side runs as root via `send-command` in restart loops — hand-typed forwards
died twice on 10-11. Port **4000** is fixed: Blockscout's frontend calls `localhost:4000`.

```bash
: "${RUNNER:?RUNNER is empty — re-run the export in B5}"
aws ssm send-command --region af-south-1 --instance-ids $RUNNER --document-name AWS-RunShellScript \
  --query 'Command.[InstanceIds,Status]' --output text \
  --parameters 'commands=["export PATH=/usr/local/besu-tools/bin:$PATH KUBECONFIG=/root/kc-pf",
    "aws eks update-kubeconfig --name sbsa-besu-primary-eks --region af-south-1 --kubeconfig $KUBECONFIG",
    "setsid nohup bash -c \"while true; do kubectl -n besu port-forward svc/blockscout-proxy 4000:80; sleep 1; done\" >/tmp/pf-4000.log 2>&1 </dev/null &",
    "setsid nohup bash -c \"while true; do kubectl -n besu port-forward svc/besu-explorer-rpc-1-rpc 8545:8545; sleep 1; done\" >/tmp/pf-8545.log 2>&1 </dev/null &"]'
#   → must print the runner's instance ID. Empty = sent to nobody.
sleep 10
C=$(aws ssm send-command --region af-south-1 --instance-ids $RUNNER --document-name AWS-RunShellScript \
  --parameters 'commands=["ss -ltnp | grep -E \":(4000|8545) \" || echo NO_LISTENERS"]' --query Command.CommandId --output text)
sleep 5; aws ssm get-command-invocation --region af-south-1 --command-id $C --instance-id $RUNNER \
  --query StandardOutputContent --output text      # → kubectl on 127.0.0.1:4000 and :8545
```

Then **two new terminals**, left open (`RUNNER` re-exported in each):

```bash
aws ssm start-session --target $RUNNER --region af-south-1 --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["4000"],"localPortNumber":["4000"]}'
```
```bash
aws ssm start-session --target $RUNNER --region af-south-1 --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8545"],"localPortNumber":["8545"]}'
```

**Should see:** `Waiting for connections...` ×2; http://localhost:4000 shows Blockscout.

## B10 — Send a transaction, find it in Blockscout (laptop · free)

**Why:** the end-to-end proof — signed by your A9 key, accepted by an RPC node, agreed by the 4
validators, indexed by the explorer. It also proves blocks are **produced**, which
`verify-deployed.sh` doesn't check yet.

```bash
cast chain-id --rpc-url http://localhost:8545                                        # = chain_id
cast block-number --rpc-url http://localhost:8545; sleep 10; cast block-number --rpc-url http://localhost:8545   # +2
cast balance $(cast wallet address --account besu-sit-sender) --rpc-url http://localhost:8545   # genesis funds, non-zero
TO=$(cast wallet new | awk '/Address/{print $2}'); echo $TO                           # a throwaway recipient
cast send --account besu-sit-sender --rpc-url http://localhost:8545 \
  --gas-price 0 --priority-gas-price 0 $TO --value 1ether                             # asks the keystore password
cast balance $TO --rpc-url http://localhost:8545 --ether                              # → 1.000000000000000000
```

Search the `transactionHash` at http://localhost:4000 → **Success**, with its block.

**Why both gas flags:** `cast` sends EIP-1559; `--gas-price 0` alone sets only the max fee and the
node refuses the default priority fee above it. **Blockscout shows the sender at 0** until its
first transaction — it doesn't import genesis balances; `cast balance` is the truth.

---

# Teardown — same day, reverse order (laptop · ~40 min)

**Why reverse order:** each layer sits on the one before it. **Why `plan -destroy -out` then
`apply`:** you read what will be deleted before anything is.

First **Ctrl-C** both B9 tunnel terminals.

## T1 — Forget the in-cluster layer (don't destroy it)

**Why:** the laptop can't reach the private cluster, so destroying Helm/Kubernetes resources would
hang; they vanish with the cluster. `-d '\n'`: plain `xargs` strips the quotes in names like
`…["besu-validator-1"]` and silently skips them (F30).

```bash
cd $REPO/sbsa_besu/terraform/chain
terraform state list | grep -E '(^|\.)(helm_release|kubernetes_[a-z_]+)\.' | xargs -d '\n' -r -n1 terraform state rm
terraform state list | grep -cE '(^|\.)(helm_release|kubernetes_[a-z_]+)\.'     # → 0
```

## T2 — Runner (expect 13) — first, because it reads the chain's state and holds a cluster access entry

```bash
cd $REPO/sbsa_besu/terraform/runner
terraform plan -destroy -var region=af-south-1 -var chain_state_bucket=besu-tfstate-$ACCT-afs1 \
  -var chain_state_key=besu/sit/chain.tfstate -var chain_state_region=af-south-1 -out=$SP/runner-d.plan
terraform show -no-color $SP/runner-d.plan | grep '^Plan:'      # 13 to destroy
terraform apply $SP/runner-d.plan
```

## T3 — Chain AWS layer (expect 106 · ~15 min)

```bash
cd $REPO/sbsa_besu/terraform/chain
terraform plan -destroy -var-file=../environments/sit/common.tfvars -var-file=../environments/sit/chain.tfvars -out=$SP/chain-d.plan
terraform show -no-color $SP/chain-d.plan | grep '^Plan:'       # 106 to destroy — more means T1 missed something
terraform apply $SP/chain-d.plan
```

KMS keys go to a 7-day *pending deletion* (normal); secrets are deleted immediately (forced, so
names can be reused).

## T4 — What EKS and the storage driver left behind (look first, delete only what's listed)

**Why:** the cluster's ENIs/SG and the pods' **data volumes** (validators, bootnodes, RPC,
Blockscout DB — ~10, ≈ $10/month each) were never Terraform's. Filtering on **today's tag and
`available`** means nothing in use, and nothing from another run, can be touched.

```bash
C=sbsa-besu-primary-eks; DG=sbsa-sit-$D
aws ec2 describe-network-interfaces --region af-south-1 --filters Name=tag:cluster.k8s.amazonaws.com/name,Values=$C \
  Name=status,Values=available --query 'NetworkInterfaces[].[NetworkInterfaceId,Description]' --output text   # each → delete-network-interface
aws ec2 describe-security-groups --region af-south-1 --filters Name=tag:aws:eks:cluster-name,Values=$C \
  --query 'SecurityGroups[].[GroupId,GroupName]' --output text                                                # each → delete-security-group
aws ec2 describe-volumes --region af-south-1 --filters Name=tag:DeletionGroup,Values=$DG Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size]' --output text
for v in $(aws ec2 describe-volumes --region af-south-1 --filters Name=tag:DeletionGroup,Values=$DG Name=status,Values=available \
             --query 'Volumes[].VolumeId' --output text); do echo "deleting $v"; aws ec2 delete-volume --region af-south-1 --volume-id $v; done
aws ec2 describe-volumes --region af-south-1 --filters Name=tag:DeletionGroup,Values=$DG --query 'length(Volumes)' --output text   # → 0
```

## T5 — Shared endpoints (expect 27) — the last billable platform piece

```bash
cd $REPO/sbsa_besu/terraform/shared
terraform plan -destroy -var-file=../environments/sit/common.tfvars -out=$SP/shared-d.plan
terraform show -no-color $SP/shared-d.plan | grep '^Plan:'
terraform apply $SP/shared-d.plan
```

## T6 — Proxy (expect 29) · T7 — Network (expect ~347, = B1)

```bash
cd $REPO/mimic_egress/terraform
terraform plan -destroy -var-file=environments/sit/primary.tfvars -out=$SP/egress-d.plan
terraform show -no-color $SP/egress-d.plan | grep '^Plan:'; terraform apply $SP/egress-d.plan

cd $REPO/mimic_vpc/terraform
terraform plan -destroy -var-file=environments/sit/primary.tfvars -out=$SP/mvpc-d.plan
terraform show -no-color $SP/mvpc-d.plan | grep '^Plan:'; terraform apply $SP/mvpc-d.plan
```

`DependencyViolation` on T7 = something still inside the VPC: stop and find it, don't retry blindly.

## T8 — Zero-check (read-only, both regions)

**Why:** "destroy complete" covers only what Terraform knew about.

```bash
cd $REPO
for d in sbsa_besu/terraform/{shared,chain,runner} mimic_egress/terraform mimic_vpc/terraform; do
  printf "%-28s %s\n" $d "$(terraform -chdir=$d state list | grep -vE '^data\.|\.data\.' | grep -c .)"; done   # all 0
for r in af-south-1 us-east-1; do echo "== $r"
  aws ec2 describe-vpcs --region $r --filters Name=is-default,Values=false --query 'Vpcs[].VpcId' --output text
  aws ec2 describe-instances --region $r --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text
  aws eks list-clusters --region $r --query clusters --output text
  aws ec2 describe-network-interfaces --region $r --query 'length(NetworkInterfaces)' --output text
  aws ec2 describe-vpc-endpoints --region $r --query 'VpcEndpoints[].VpcEndpointId' --output text
  aws elbv2 describe-load-balancers --region $r --query 'LoadBalancers[].LoadBalancerName' --output text
  aws ec2 describe-volumes --region $r --query 'Volumes[].VolumeId' --output text
  aws logs describe-log-groups --region $r --query 'logGroups[].logGroupName' --output text
done                                                                                  # all empty / 0
aws s3 ls s3://besu-tfstate-$ACCT-afs1/besu/sit/ | grep tflock; aws s3 ls s3://besu-tfstate-$ACCT/besu/sit/ | grep tflock   # none
```

**Kept on purpose — not leftovers:** everything from Part A (state buckets, ECR mirror, the four
secrets, Octopus space and CI trust, the sender keystore), and KMS keys in `PendingDeletion`.
The worker shows **Unavailable** in Octopus until the next B7.

**Finish the log:** zero-check result, cost (billing ≈ B4 start → T5 end, ≈ $2/h), what went
wrong and why, what's still open — and a row in `test-run-log.md`.

# R-9 mock deploy — 2026-09-17 — the Octopus polling-Tentacle path (RUNBOOK E.1)

> **RESULT: E.1 steps 1–10 PASSED.** Octopus Cloud ran `kubectl get nodes` against the
> private EKS endpoint through a polling Tentacle worker on the in-VPC runner, whose only
> way out is a `CONNECT` proxy allowlisted to one source `/32` and two hostnames; the worker
> survived a stop/start with the same thumbprint and IP. CD-56..CD-61 are validated live.
> Four defects found and fixed on the way (**B21–B24**), one design answer for the bank
> (the least-privilege Octopus role for registration — see step 8). Teardown: §T.

> **Read this if re-running.** This record predates the 2026-09-18 merge of the three
> projects into one repository. Every `~/Documents/Blockchain/Besu/sbsa/<project>` below is now
> `~/Documents/Blockchain/Besu/besu-octopus-ghactions-tf-aws/<project>`; the commands are otherwise
> unchanged. The two mimic state keys in the table below (`besu/network/…`) are the ones used
> that day; the mimic docs and `backend.tf` now specify `besu/<env>/{network,egress}.tfstate`
> — pass the new key at the next `terraform init` (RUNBOOK §2).

**What this run proves.** The bank's cloud team gives us no egress internals (R-9 closed as
"option 1", 2026-09-14): a shared central egress behind a load balancer, reachable only from
a pinned source. Our in-VPC runner must register with Octopus Cloud as a **polling Tentacle
worker** through that proxy (CD-55..CD-64) so Octopus can deploy Terraform *and* Helm into a
cluster whose API endpoint is private. This mock builds the assumed egress shape ourselves
(`mimic_egress`), the network the cloud team will hand us (`mimic_vpc`), and then the real
platform roots on top — `shared` → `chain` → `runner` — exactly as production will be built.

**Ground rules that applied.** Advise-only (the operator runs every command); USD 15 cap;
same-day teardown; nothing hardcoded; no deletion-protection anywhere; verify versions from
source. Every command below was run from the laptop unless the step says otherwise.

**State layout used today**

| Root | Repo | Backend key (bucket `besu-tfstate-867728055761`, us-east-1) | Region of resources |
|---|---|---|---|
| mimic network | `mimic_vpc` | `besu/network/main.tfstate` | af-south-1 |
| mimic egress | `mimic_egress` | `besu/network/egress.tfstate` | af-south-1 |
| shared endpoints | `sbsa_besu/terraform/shared` | `besu/sit/shared.tfstate` | af-south-1 |
| chain (AWS layer) | `sbsa_besu/terraform/chain` | `besu/sit/chain.tfstate` | af-south-1 |
| runner | `sbsa_besu/terraform/runner` | `besu/sit/runner.tfstate` (not yet initialised) | af-south-1 |

The state bucket lives in us-east-1 while every resource lives in af-south-1. That is normal
— state is just an object in S3 — but it is why every `init` names the bucket's region
explicitly and every destroy names the *resource* region explicitly.

---

## 0. Pre-checks (free)

**What:** prove the account is empty and the two kept secrets still exist.
**Why:** a leaked resource from a previous run would be silently adopted or collide by name;
the two secrets were deliberately kept on 09-14 so the Octopus API key need not be re-issued.

```bash
aws sts get-caller-identity --query Account --output text            # 867728055761
aws ec2 describe-vpcs --region af-south-1 \
  --query 'Vpcs[?IsDefault==`false`].VpcId' --output text            # (empty)
aws secretsmanager list-secrets --region af-south-1 --include-planned-deletion \
  --query 'SecretList[].[Name,DeletedDate]' --output text
# sbsa-besu-primary-octopus-register-key  None
# sbsa-besu-primary-tentacle-cert         None
```

`--include-planned-deletion` matters: a secret in its 7–30-day recovery window is invisible
to a plain `list-secrets` but still blocks a new secret with the same name.

Also start the live command log (this file's companion) with the UTC start time.

---

## 1. `mimic_vpc` — the network the cloud team will hand us (~$0)

**What:** one VPC `10.60.0.0/20` (+ an unused `100.64.0.0/16` secondary), five subnet tiers ×
three AZs (ledger / app / lb / endpoint / data), one route table per subnet, NACLs, DHCP
options, the two gateway endpoints (S3, DynamoDB), flow logs. **No IGW, no NAT.**
**Why:** the platform never creates a VPC — it *consumes* one under a contract
(`modules/network-contract`, eight gates). The mimic is that contract made real so the
platform can be built and torn down without the cloud team.

### 1.1 Bump the DeletionGroup tag

```bash
sed -i 's/sbsa-net-sit-2026-09-09/sbsa-net-sit-2026-09-17/' \
  ~/Documents/Blockchain/Besu/sbsa/mimic_vpc/terraform/environments/sit/primary.tfvars
```

`DeletionGroup` is the tag `full-delete.sh` keys on when state is lost. A fresh value per run
means a backstop delete can never match a previous run's ghosts (the tag API keeps listing
deleted ARNs for minutes — B16).

### 1.2 Plan to a file, apply that file

```bash
cd ~/Documents/Blockchain/Besu/sbsa/mimic_vpc/terraform
terraform plan -var-file=environments/sit/primary.tfvars -out=mimic.plan
terraform apply mimic.plan
```

`-out` + `apply <file>` guarantees what was reviewed is what is applied; a bare `apply`
re-plans and could pick up a change made in between.

**Expected / got:** `Plan: 65 to add` → `Apply complete! Resources: 65 added`. VPC
`vpc-0aa3d48cec8421f9e`. Ledger subnets `subnet-0050925bec140b039` (az1),
`subnet-0d22185f099c35937` (az2), `subnet-0947ef5813732035f` (az3); ledger route tables
`rtb-0f0c4bf4c132fb154`, `rtb-05756938e010eb4ef`, `rtb-0dfb6c7fc06dd318a`. Only the flow-log
group bills (1-day retention).

### 1.3 Verify the contract against LIVE AWS, then emit the hand-over

```bash
cd .. && ./scripts/verify-contract.sh     # 27 passed, 0 failed
./scripts/emit-handover.sh
wc -c network-handover.auto.tfvars        # 3363 (a 0-byte file = B19 regression)
grep -E 'vpc_id|network_region' network-handover.auto.tfvars
grep vpc_id ../sbsa_besu/terraform/network-handover.auto.tfvars
```

`verify-contract.sh` reads the AWS API, not state, because the platform will meet reality.
`emit-handover.sh` renders the IDs the platform needs into
`sbsa_besu/terraform/network-handover.auto.tfvars` and symlinks it into `shared/` and
`chain/` (an `*.auto.tfvars` is loaded by Terraform without being named on the command
line). The render is atomic since B19 — a failed output read used to truncate the file and
leave a stale hand-over in place.

---

## 2. `mimic_egress` — the bank's assumed egress shape (≈ $0.6/day)

**What:** a second, tiny VPC `10.61.0.0/24` with the *only* IGW in the account, a Squid 6.13
proxy on a `t3.micro`, an **internal** NLB in front of it (the "VIP"), a private hosted zone
`egress.mimic.internal` with `proxy` → the NLB, associated to the ledger VPC, VPC peering to
the ledger VPC, and **exactly three routes** `10.61.0.0/24 → pcx` in the three **ledger**
route tables only.
**Why:** CD-63 — we model what the bank gives us (a hostname:port for a CONNECT proxy
reachable from a pinned source) so the runner's Tentacle path is tested against the same
shape. The routes go only into ledger tables because only the runner may reach egress; the
app/lb/endpoint/data tiers stay air-gapped (CD-60).

### 2.1 Feed it the network hand-over, bump the tag

```bash
cd ~/Documents/Blockchain/Besu/sbsa
cp mimic_vpc/network-handover.auto.tfvars mimic_egress/terraform/
grep -E 'vpc_id|network_region' mimic_egress/terraform/network-handover.auto.tfvars   # the NEW vpc
sed -i 's/sbsa-egress-sit-2026-09-14/sbsa-egress-sit-2026-09-17/' \
  mimic_egress/terraform/environments/sit/primary.tfvars
```

The egress mimic needs the ledger VPC ID and route-table IDs to peer and route. The local
copy still carried the **destroyed** 09-14 VPC — copying is the step that fixes that; without
it the peering would target a VPC that no longer exists.

### 2.2 Plan, review against the checklist, apply

```bash
cd mimic_egress/terraform
terraform plan -var-file=environments/sit/primary.tfvars -out=egress.plan
terraform apply egress.plan
```

Checklist (all satisfied today, `Plan: 29 to add`):
`aws_vpc_peering_connection` with `peer_vpc_id = vpc-0aa3d48cec8421f9e`; exactly **3**
`ledger_to_egress` routes into the three ledger tables; **one** `0.0.0.0/0`
(`default_to_igw`) and it is in the egress VPC's own table; `t3.micro`, IMDSv2 required,
encrypted gp3 root; proxy SG **443 out only**, 3128 in from `10.60.0.0/20` + `10.61.0.0/24`;
NLB `sbsa-besu-sit-egress-vip`, target group with `preserve_client_ip = true` (that is what
lets Squid see the runner's real `10.60.0.250` and enforce the source allowlist).

**Got:** peering `pcx-053085dc71c5f6bba`, proxy `i-0b95c6e5f185c0613`.

### 2.3 Confirm Squid is up behind the NLB, emit the egress hand-over

```bash
aws elbv2 describe-target-health --region af-south-1 \
  --target-group-arn "$(aws elbv2 describe-target-groups --region af-south-1 \
      --names sbsa-besu-sit-egress-proxy-tg --query 'TargetGroups[0].TargetGroupArn' --output text)" \
  --query 'TargetHealthDescriptions[].TargetHealth.State' --output text   # initial → healthy (~2 min)

cd .. && ./scripts/emit-handover.sh
grep -E 'egress_allowed_source|egress_proxy_host|egress_proxy_port|egress_vpc_cidr' egress-handover.auto.tfvars
ls -l ../sbsa_besu/terraform/egress-handover.auto.tfvars ../sbsa_besu/terraform/runner/egress-handover.auto.tfvars
```

Squid is installed by user-data, so the target is `initial` for a minute or two; `unhealthy`
after 5 min means the config failed to parse (`aws ssm start-session` onto the instance,
`journalctl -u squid`). The hand-over (`1440` bytes) carries
`egress_allowed_source = "10.60.0.250/32"`, `proxy.egress.mimic.internal:3128`, the CIDR and
the two `octopus.app` hostnames; it is placed in `sbsa_besu/terraform/` and symlinked into
`runner/`, where the runner root reads its **pinned** private IP from it (CD-60: the
allowlisted source is pinned, not observed).

---

## 3. Octopus Cloud side + the two secrets (nothing to create today)

In `avishkarabhishek786.octopus.app`: default Space, **Static** worker pool
`sit-ledger-workers` — showing "no workers" is correct until step 8 registers one. In Secrets
Manager (af-south-1), named with the chain's `name_prefix` (`sbsa-besu-primary`, *not*
`<project>-<env>`): `…-octopus-register-key` (the API key, written via `file://` so it never
appears on a command line) and `…-tentacle-cert` (created **empty**; `install-tentacle.sh`
fills it so a stop/start keeps the same Tentacle identity, CD-61). The runner's deploy policy
already scopes `<name_prefix>-*` secrets, so no IAM change is needed for them.

---

## 4a. `shared` — the 15 interface endpoints (≈ $0.45/h — the clock starts here)

**What:** 15 Interface VPC endpoints (ssm, ssmmessages, ec2messages, ec2, eks, sts, kms,
logs, monitoring, secretsmanager, ecr.api, ecr.dkr, elasticloadbalancing, sns, sqs) in the
three **endpoint** subnets, one endpoint security group (443 from the VPC), one private hosted
zone `chain.internal`. **No gateway endpoints** — the hand-over says the network already has
them (`gateway_endpoints_created_here = true`).
**Why:** the VPC has no internet path at all, so every AWS API the nodes, addons and runner
call must be reachable through an endpoint. They are the largest fixed cost in the
air-gapped design (45 ENIs ≈ $11/day), which is why they are their own root: they outlive a
chain rebuild and are destroyed last.

### Two fixes found before the first plan

**(a) `environments/sit/common.tfvars` said `environment = "dev"`.** Both `shared` and
`chain` validate `contains(["prod","uat","sit"], var.environment)`, so the plan would
hard-fail. The file is gitignored (it carries the owner's e-mail), so git could not show the
drift from the tracked `.example` (which says `sit`). Fixed, and the tag bumped:

```bash
cd ~/Documents/Blockchain/Besu/sbsa/sbsa_besu/terraform
sed -i 's/^environment = "dev"/environment    = "sit"/; s/sbsa-sit-2026-09-09/sbsa-sit-2026-09-17/' \
  environments/sit/common.tfvars
```

**(b) State keys had no `<env>` segment.** The roots were last initialised (08-30) on
`besu/platform/{shared,chain}.tfstate`; the runbook (09-09) makes `besu/<env>/…`
load-bearing — without it the three environments would share state and the second apply
would reconcile one environment against another's resources. Neither `platform` key existed
as an S3 object, so re-pointing was free. `-reconfigure` is safe *only* because there was no
state to migrate — with live state you would use `-migrate-state` instead:

```bash
cd shared
terraform init -reconfigure \
  -backend-config="bucket=besu-tfstate-867728055761" \
  -backend-config="key=besu/sit/shared.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="use_lockfile=true"
```

`use_lockfile=true` is S3-native locking (Terraform ≥ 1.10; DynamoDB locking is deprecated).

### The plan failed — B21, fixed in code the same hour

```
Error: Call to function "coalesce" failed: no non-null, non-empty-string arguments.
  on ../modules/network-contract/main.tf line 195, in resource "terraform_data" "no_egress"
```

The "no NAT" gate was written as `coalesce(r.nat_gateway_id, "") != ""`. Terraform's
`coalesce` treats `""` as *absent* and errors when nothing non-empty remains, and the
`aws_route_table` data source reports `nat_gateway_id = ""` for every non-NAT route. The
gate had only ever been evaluated against an **empty** route list (the data source omits the
`local` route, and until today the ledger tables had nothing else) — the three peering routes
added in step 2 were the first real routes it saw, hence three identical errors. Fix: the
non-empty sentinel idiom the neighbouring IGW check already used,
`coalesce(r.nat_gateway_id, "-") != "-"`. Commit `3537577`; `docs/build-findings.md` B21.
Lesson (same shape as B19/B20): a check that passes on the input it was written against is
not evidence it works on the input it will meet.

### Plan, apply

```bash
terraform plan -var-file=../environments/sit/common.tfvars -out=shared.plan
terraform apply shared.plan
terraform output billable_endpoint_eni_count      # 45
```

**Got (15:09 UTC):** `27 added` — 15 endpoints + SG/rules + zone + the `terraform_data`
gates; `gateway_endpoint_ids` empty as required; SG `sg-060b5cf41b439f33f`; zone
`Z06505853RFD93X4CB1A5`; `billable_endpoint_eni_count = 45`.

---

## 4b. `chain` — the AWS layer only (≈ $1.1–1.4/h)

**What:** the private EKS cluster (1.35) and its 4-node `m6i.xlarge` group in the ledger
subnets, IRSA/OIDC, EBS CSI addon + the three core addons, the node-key CMK and a second CMK,
the CA (self-managed, `tls_*`) and 23 Secrets Manager secrets (validator/bootnode/rpc node
identities, keystores, JWTs), the SWIFT RPC NLB shell, CloudTrail + its bucket, the
runner-artifacts bucket, SNS alerting, log groups, the Resource Group, and the eight
contract gates + hardening guards as `terraform_data`.
**Why the AWS layer only:** the cluster's API endpoint is private. Anything applied through
the `kubernetes`/`helm` providers must run from inside the VPC — that is the runner's job.
`deploy_in_cluster_resources = false` in `chain.tfvars` makes this laptop apply skip every
`helm_release` / `kubernetes_*`.
**Why the runner needs this first:** the runner root reads the chain's state (VPC, ledger
subnets, cluster for its access entry, node SG, artefact bucket, deploy-config secret), so the
Tentacle test rides on the real prod path.

### Re-point the key, plan with the deploy-test overrides

```bash
cd ~/Documents/Blockchain/Besu/sbsa/sbsa_besu/terraform/chain
terraform init -reconfigure \
  -backend-config="bucket=besu-tfstate-867728055761" \
  -backend-config="key=besu/sit/chain.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="use_lockfile=true"

terraform plan -var-file=../environments/sit/common.tfvars \
               -var-file=../environments/sit/chain.tfvars \
               -var worker_node_count=4 -var worker_node_min=4 \
               -var kms_deletion_window_days=7 \
               -var secret_recovery_window_days=0 \
               -out=chain.plan
```

The overrides keep the tfvars honest for production while making a throwaway run cheap and
re-runnable: **4 nodes** is the floor (`worker_node_count >= 4` — four validators on distinct
nodes) instead of the prod 6; **KMS 7 days** is the minimum pending-deletion window (prod
30); **secret recovery 0** force-deletes on destroy so the *next* mock does not collide with
23 names still "scheduled for deletion" (the 07-02 trap) — the variable's own description
calls 0 the non-prod value. A `-var` on the command line beats a `-var-file`.

### Review — do not read 3,000 lines, scan for money and design violations

```bash
terraform show -no-color chain.plan | grep -E '^\s*# .* will be created' \
  | sed -E 's/.*# //; s/ will be created//; s/\[.*//; s/^(module\.[^.]+\.)*//' \
  | awk -F. '{print $1}' | sort | uniq -c | sort -rn
terraform show -no-color chain.plan | grep -nE 'aws_eks_cluster"|aws_eks_node_group"|desired_size|min_size|instance_types|endpoint_public_access|resource "aws_lb"|internal  |aws_nat_gateway|aws_internet_gateway|helm_release|kubernetes_|deletion_protection|recovery_window_in_days|deletion_window_in_days|permissions_boundary' \
  | grep -v 'known after'
```

Result today — `Plan: 106 to add`:

| Check | Plan |
|---|---|
| EKS cluster | 1, `endpoint_public_access = false`, `private_access = true`, ledger subnets |
| Node group | 1, `desired 4 / min 4 / max 10`, `m6i.xlarge`, AL2023, 100 GiB gp3, ledger subnets |
| KMS | 2 keys, `deletion_window_in_days = 7` |
| Secrets | 23, all `recovery_window_in_days = 0` |
| IAM | 8 roles, 9 `permissions_boundary` references (H5 live on every role) |
| CloudTrail + 2 buckets | `force_destroy = true` |
| `aws_lb "rpc"` | internal NLB `sbsa-besu-primary-rpc-nlb` in the **lb** subnets, deletion protection `false` — the SWIFT RPC shell; targets arrive with the in-cluster layer |
| Forbidden | zero NAT / IGW / `helm_release` / `kubernetes_*`; the only deletion-protection flag in the plan is that `false` |

```bash
terraform apply chain.plan              # ~15–20 min (control plane ~10–12, node group ~3–5)
terraform output -raw name_prefix; echo         # sbsa-besu-primary
terraform output -raw cluster_name; echo
aws eks describe-cluster --region af-south-1 --name "$(terraform output -raw cluster_name)" \
  --query 'cluster.[status,resourcesVpcConfig.endpointPublicAccess,resourcesVpcConfig.endpointPrivateAccess]' \
  --output text                                 # ACTIVE False True
```

`name_prefix` must be `sbsa-besu-primary` — the two Octopus secrets are named under it and
the runner's deploy policy scopes on it.

---

## 4c. Push the runner bundle + the deploy config (laptop → S3 / Secrets Manager)

**What:** `push-runner-bundle.sh` downloads the pinned toolchain (`runner-tools.manifest`:
kubectl, helm, terraform 1.16.1, a JVM, **the Tentacle tarball 11.0.4398**), verifies each
sha256 against the digests recorded 09-10, and uploads `tools/tools.tar.gz` (293 MiB) plus
`source/source.tar.gz` (`git archive HEAD`, ~500 KiB) to the chain's artefact bucket.
`push-deploy-config.sh` tars the **gitignored** config the archive cannot carry and stores it
base64 in the `…-runner-deploy-config` secret.
**Why:** the runner has no internet and no package manager (D-21) — everything it needs
arrives over the S3 gateway endpoint; the one secret part of the delivery (tfvars) rides in
Secrets Manager, not beside ordinary source. Both must land **before** the runner boots,
because cloud-init fetches them once.

```bash
cd ~/Documents/Blockchain/Besu/sbsa/sbsa_besu
git status --short                                       # bundle ships HEAD: commit first
AWS_REGION=af-south-1 scripts/runner/push-runner-bundle.sh
AWS_REGION=af-south-1 ENV=sit scripts/runner/push-deploy-config.sh
aws s3 ls s3://sbsa-besu-primary-runner-artifacts/ --recursive --human-readable
```

**B22, found before the first push by reading the script:** `push-deploy-config.sh` still
listed `environments/<env>/primary.tfvars` — the besu-aws single-file convention. This repo
split its tfvars into `common.tfvars` + `chain.tfvars` on 08-30, and the script tolerates a
missing candidate, so it would have shipped **only the two hand-overs** and every `terraform
plan` on the runner would have failed on missing variables. Fixed (`b9e5b66`): the log line
now reads `bundling 4 file(s): …common.tfvars …chain.tfvars …network-handover… …egress-handover…`.

**Got (15:47 UTC):** both objects in the bucket; 4 files in the config secret.

---

## 5. `runner` — the in-VPC host (first-ever init of this root; ≈ $0.03/h)

**What:** one `t3.small` in the **first ledger subnet** with a **pinned** private IP
`10.60.0.250` (from `egress-handover.auto.tfvars`, CD-60), no public IP, IMDSv2 required,
20 GiB encrypted root; an IAM role with SSM + the boundaried deploy policy + read on the
artefact bucket; an **EKS access entry** granting the role cluster-admin; an egress-only SG.
Its user-data pulls the two S3 objects and the config secret and writes
`/opt/besu-deploy/BOOTSTRAP_STATUS`, failing **loudly** if anything is missing.
**Why:** the private EKS endpoint is reachable only from inside the VPC; this host is the
Tentacle worker Octopus drives and the SSM break-glass shell. It reads the chain's state for
everything it attaches to, so it is applied after the chain and destroyed before it.

```bash
cd terraform/runner
terraform init -backend-config="bucket=besu-tfstate-867728055761" \
               -backend-config="key=besu/sit/runner.tfstate" \
               -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
terraform plan -var region=af-south-1 -var chain_state_bucket=besu-tfstate-867728055761 \
               -var chain_state_key=besu/sit/chain.tfstate -var chain_state_region=us-east-1 \
               -out=runner.plan                                          # 11 to add
terraform apply runner.plan
terraform output -raw runner_bootstrap_check; echo
```

Plan checks that matter: `private_ip = "10.60.0.250"`, `subnet_id = subnet-0050925bec140b039`
(az1 ledger, `10.60.0.0/24`), `associate_public_ip_address = false`, `http_tokens = required`.
The module refuses at plan time if the pinned IP is not inside the chosen subnet.

**Got (15:52 UTC):** `i-02afc47d1256be9c0`, role `sbsa-besu-primary-runner-role`, policy
`…-runner-deploy-scoped`. Bootstrap check (SSM `send-command`, then `get-command-invocation`):
`status: done` / `OK: tools=5 source=b9e5b66 deploy-config: extracted`. D-21 proven in
af-south-1: a host with no internet fully provisioned over the S3 gateway.

The `runner_bootstrap_check` output string had unquoted parentheses that made bash choke
when pasted; fixed (`9143292`). The corrected check:

```bash
CID=$(aws ssm send-command --instance-ids <id> --region af-south-1 --document-name AWS-RunShellScript \
  --parameters 'commands=["cloud-init status; cat /opt/besu-deploy/BOOTSTRAP_STATUS 2>/dev/null || echo NO STATUS FILE YET - bootstrap still running"]' \
  --query Command.CommandId --output text) && sleep 10 && \
aws ssm get-command-invocation --command-id "$CID" --instance-id <id> --region af-south-1 \
  --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
```

---

## 6 + 7. The eight egress probes

**What:** `mimic_egress/scripts/verify-egress.sh` takes the polling endpoint's certificate
fingerprint **from the laptop (no proxy)** as the baseline, ships
`sbsa_besu/scripts/preflight/verify-egress-proxy.sh` to the runner over SSM for probes 1–7,
then runs probe 8 from a non-allowed source.
**Why:** it is the platform's own **day-one check against the bank's proxy** — the installer
refuses to register if it fails. Each probe maps to one design decision.

```bash
cd ~/Documents/Blockchain/Besu/sbsa/mimic_egress && ./scripts/verify-egress.sh
```

| # | Where | Proves | Decision |
|---|---|---|---|
| 1 | runner | `proxy.egress.mimic.internal` → `10.61.0.42` (PHZ associated to the ledger VPC) | CD-56 |
| 2 | runner | `CONNECT <instance>.octopus.app:443` → **200** (route, NLB client-IP preservation, source `/32` all hold) | CD-59/60 |
| 3 | runner | `CONNECT polling.<instance>.octopus.app:443` → **200** | CD-59 |
| 4 | runner | `CONNECT example.com:443` → **403** | CD-59 |
| 5 | runner | plain HTTP → **403** (tunnels only) | CD-56 |
| 6 | runner | `CONNECT …:10943` → **403** (443 only) | CD-59 |
| 7 | runner | cert fingerprint **through** the proxy == laptop baseline `9B:A5:3F:…:F3:78` → **no TLS interception** | CD-58 |
| 8 | proxy host | a different source is refused (**403**) | CD-60 |

**Got (16:07 UTC):** 8/8 after **B23**. The first run's probe 8 returned `000` (timeout): it
ran on the proxy host **through the VIP**, and an NLB target cannot connect to itself through
its own NLB when client-IP preservation is on (source == destination == its own address; AWS's
documented loopback restriction). The ACL was fine — the runner's 200s already prove the VIP
preserves the client IP. Probe 8 now talks to Squid directly on the proxy host's own address
(`10.61.0.40`), which Squid refuses as a non-allowlisted source. Fixed in `mimic_egress`
(`e3f736e`).

---

## 8. `install-tentacle.sh` — the runner becomes a polling Tentacle worker

**What (CD-57, in order):** re-run the 7 probes and refuse on failure → system user
`tentacle` → `create-instance` / certificate / `configure --noListen` → **polling-proxy ON,
web-request proxy OFF** → one proxied `register-worker` → our own systemd unit.
**Why each is the way it is:** the Tentacle runs as an unprivileged user because Octopus will
execute scripts on this host (CD-62); polling-only means nothing inbound; the web-request
proxy is *exported to every step* as `http(s)_proxy` and would send terraform/kubectl/helm at
the bank proxy instead of the VPC endpoints, so it is set OFF explicitly; `register-worker`
is the one REST call and on Linux ignores the polling proxy, so it alone gets `https_proxy`
in its own environment; the certificate is generated-and-exported **once** into Secrets
Manager (`…-tentacle-cert`) so a rebuilt host can import it and keep its identity (CD-61).

Over SSM, as root — the values used today:

```bash
aws ssm start-session --target i-02afc47d1256be9c0 --region af-south-1
sudo env \
  OCTOPUS_INSTANCE=avishkarabhishek786 \
  OCTOPUS_SPACE='Default' \
  OCTOPUS_WORKER_POOL=sit-ledger-workers \
  OCTOPUS_API_KEY_SECRET=sbsa-besu-primary-octopus-register-key \
  EXPECTED_POLLING_CERT_SHA256='9B:A5:3F:3C:2C:8D:59:0B:83:CD:C1:6E:5E:6B:BE:FF:5D:BB:51:A4:68:4C:7E:53:DD:A3:EB:B5:BC:54:F3:78' \
  TENTACLE_CERT_SECRET=sbsa-besu-primary-tentacle-cert \
  bash /opt/besu-deploy/sbsa_besu/scripts/runner/install-tentacle.sh
```

Three attempts were needed; each one taught something that is now in the script or the runbook:

1. **B24 — `Access to the path '/etc/octopus' is denied`.** Tentacle on Linux keeps its
   instance **index** machine-wide under `/etc/octopus`, not under `$HOME` as the script's
   comment assumed, and the unprivileged user cannot create it. Step 1 now creates
   `/etc/octopus` owned by `tentacle` (it holds a pointer file, no secrets). The failed
   `create-instance` had also left a **full** `tentacle.config` skeleton behind, so the
   `[ -f "$CONFIG" ]` guard skipped step 2 on re-run and step 3 failed with *"Instance
   besu-worker has not been configured on this machine. Available instances: ."* Step 2 now
   decides "instance exists" from Tentacle's own index (`/etc/octopus/Tentacle/instances/`
   or `list-instances`) and removes a config the index does not know. (`444a220`, `94f3fb4`.)
   To refresh the script on a running runner without a rebuild:
   `aws s3 cp s3://<bucket>/source/source.tar.gz /tmp/s.tgz && sudo tar xzf /tmp/s.tgz -C /opt/besu-deploy/sbsa_besu`
   after `push-runner-bundle.sh --source-only` on the laptop.
2. **Octopus: *"A space with name Default could not be found … that the user has access to
   this space."*** The key authenticated (a bad key gives 401); its user — the **service
   account `besu-register`** — was in no team, so from its view no Space existed
   (`GET /api/spaces` → *"You have to have either SpaceView permission or access to the data
   within at least one space"*). Fix in Octopus: **Configuration → Teams → new team
   `BesuTestTeam` → member `besu-register` → user role `Environment manager` scoped to Space
   `Default` → SAVE** (the first attempt was not saved; a team page looks complete before
   SAVE). Verified from the runner through the proxy:
   ```bash
   K=$(aws secretsmanager get-secret-value --secret-id sbsa-besu-primary-octopus-register-key --region af-south-1 --query SecretString --output text)
   curl -sS -x http://proxy.egress.mimic.internal:3128 -H "X-Octopus-ApiKey: $K" https://avishkarabhishek786.octopus.app/api/users/me | jq '{Username,IsService}'
   curl -sS -x http://proxy.egress.mimic.internal:3128 -H "X-Octopus-ApiKey: $K" https://avishkarabhishek786.octopus.app/api/spaces | jq '[.Items[]? | {Id,Name}]'
   unset K
   ```
   **Design answer for the bank (CQ-6):** `register-worker` succeeded with **Environment
   manager scoped to the Space** — no Space Manager needed. That is the least-privilege
   role to request for the registration service account.
3. **Success (16:39 UTC):** `Machine registered successfully` (through Squid), thumbprint
   `55A0F453BBC29B75146AD281E83FCAD9E1E46B8F` generated and stored in
   `sbsa-besu-primary-tentacle-cert`, `tentacle.service` active as `tentacle`, journal:
   *Secure connection established … [::ffff:10.61.0.42]:3128 … Tls13* ×5.

---

## 9. Proof from the Octopus side

**Infrastructure → Workers → `ip-10-60-0-250`**: **Healthy**, thumbprint `55A0F453…6B8F`.
**Tasks → Script Console → Worker pool `sit-ledger-workers` → Bash:**

```bash
set -e
echo "worker: $(hostname) $(hostname -I)"; which kubectl helm terraform aws
aws eks update-kubeconfig --name sbsa-besu-primary-eks --region af-south-1 --kubeconfig /tmp/kc >/dev/null
KUBECONFIG=/tmp/kc kubectl get nodes -o wide
```

**Got:** four nodes, all **`Ready`**, `v1.35.7-eks-cb19647`, AL2023, in `10.60.0/1/2.x`.
This is the point of R-9: **a hosted control plane executing `kubectl` against a private EKS
endpoint, via a worker that only reaches the internet through a `CONNECT` proxy.** `Ready`
also means the VPC CNI pulled its images through `ecr.api`/`ecr.dkr` + the S3 gateway — the
endpoint-policy traps (#20/#23) are clear in this account.

---

## 10. Stop/start — the identity survives (CD-61)

```bash
aws ec2 stop-instances  --instance-ids i-02afc47d1256be9c0 --region af-south-1
aws ec2 wait instance-stopped --instance-ids i-02afc47d1256be9c0 --region af-south-1
aws ec2 start-instances --instance-ids i-02afc47d1256be9c0 --region af-south-1
aws ec2 wait instance-running --instance-ids i-02afc47d1256be9c0 --region af-south-1
```

**Got:** the worker returned **Healthy** on the same thumbprint; on the runner
`systemctl is-active tentacle.service` → `active`, five fresh *Secure connection
established* lines — nothing re-registered. The pinned IP is the ENI's primary address and
the Tentacle instance lives on the root volume, so stop/start keeps everything the
allowlist and the registration depend on.

---

## Findings from this run

| # | Where | One line | Commit |
|---|---|---|---|
| B21 | `modules/network-contract` | NAT gate `coalesce("", "")` errors on any non-local route; had only ever seen an empty list | `3537577` |
| B22 | `scripts/runner/push-deploy-config.sh` | bundled a `primary.tfvars` this repo does not have; would have shipped hand-overs only | `b9e5b66` |
| B23 | `mimic_egress/scripts/verify-egress.sh` | probe 8 hairpinned through the NLB from a target (impossible with client-IP preservation) | `e3f736e` |
| B24 | `scripts/runner/install-tentacle.sh` | Tentacle's index lives in `/etc/octopus`; config-file presence is not "instance exists" | `444a220`, `94f3fb4` |
| — | `terraform/runner/outputs.tf` | bootstrap-check one-liner had unquoted parentheses | `9143292` |
| — | Octopus | registration service account needs a team + a Space-scoped role; **Environment manager suffices** | runbook E.1 step 3 |

Common shape of B21/B23/B24 (and B19/B20 before them): a check or a script that passes on
the input it was written against is not evidence it works on the input it will meet. Every
one of these was found by running the real thing once.

---

## Teardown — delete everything from AWS (same day, mandatory)

Order is the reverse of creation, and the reason is dependencies, not tidiness: the runner
reads chain state; the chain's nodes/NLB/ENIs live in the mimic's subnets; the egress
project's routes and hosted-zone association live *in the ledger VPC*; interface-endpoint
ENIs sit in the endpoint subnets. Destroying a VPC with anything still inside it fails slowly
and ambiguously, so **check the leaks before each VPC-level destroy**.

Nothing was applied in-cluster from the laptop (`deploy_in_cluster_resources = false`), so
there is no `state rm` step today. If a future run applies Helm from the runner, `state rm`
the `helm_release`/`kubernetes_*` addresses from the chain state before the laptop destroy —
the laptop cannot reach the private endpoint to destroy them, and the cluster deletion takes
them anyway.

Every `destroy` needs the **same var-files/vars as its apply** — the variables still validate
even though the values come from state.

### T0. Octopus

After T1, **Infrastructure → Workers → `ip-10-60-0-250` → Delete** — tidier than a dead
registration; the next run imports the same certificate from Secrets Manager and registers
under the same thumbprint anyway. **Keep both `sbsa-besu-primary-*` secrets** — they are in
no state and cost ~$0.03/day; deleting `…-tentacle-cert` would force a new identity next run.
Leave `BesuTestTeam` and the service account: they are free and the next run needs them.

### T1. `runner`

```bash
cd ~/Documents/Blockchain/Besu/sbsa/sbsa_besu/terraform/runner
terraform plan -destroy -var region=af-south-1 \
  -var chain_state_bucket=besu-tfstate-867728055761 \
  -var chain_state_key=besu/sit/chain.tfstate \
  -var chain_state_region=us-east-1 -out=runner-destroy.plan          # 11 to destroy
terraform apply runner-destroy.plan
```

(Exactly the `-var`s the runner was applied with.) The runner goes **before** the chain: its
EKS access entry and instance profile reference chain resources. Gotcha from besu-aws: never
*stop* the runner mid-teardown — a stopped runner holding a lock stalls the chain destroy;
destroy it, or leave it running until its own destroy. Exit any SSM session first.

### T2. `chain` (~10–15 min; EKS deletes the node group first, then the cluster)

```bash
cd ~/Documents/Blockchain/Besu/sbsa/sbsa_besu/terraform/chain
terraform plan -destroy -var-file=../environments/sit/common.tfvars \
               -var-file=../environments/sit/chain.tfvars \
               -var worker_node_count=4 -var worker_node_min=4 \
               -var kms_deletion_window_days=7 -var secret_recovery_window_days=0 \
               -out=chain-destroy.plan          # expect: 106 to destroy
terraform apply chain-destroy.plan
```

`plan -destroy -out` + `apply` is the same review discipline as the create. Secrets are
force-deleted (window 0); the two CMKs go to **pending deletion for 7 days** — that is
expected, not a leak, and pending keys do not bill. `force_destroy = true` on the trail and
runner-artifacts buckets lets non-empty buckets go.

If the destroy hangs on the cluster's security group or subnet: an orphaned ENI (usually from
a load balancer or a pod) is still attached — find it with the ENI describe in T6 and delete
it, then re-run the destroy.

### T3. `shared` (~3–5 min; 45 ENIs)

```bash
cd ~/Documents/Blockchain/Besu/sbsa/sbsa_besu/terraform/shared
terraform plan -destroy -var-file=../environments/sit/common.tfvars -out=shared-destroy.plan   # 27
terraform apply shared-destroy.plan
```

Shared goes *after* the chain for the same reason it was applied before it: the endpoints
are what anything **inside** the VPC uses to reach AWS. On the day, the in-cluster destroy
(Helm, PVCs) runs from the runner and needs them; a laptop-driven destroy would not, but the
runbook keeps one order (`app` → `chain` → `runner` → `shared`) so there is nothing to think
about under pressure.

### T4. `mimic_egress` — check the egress VPC for leaked NLB ENIs first

```bash
EVPC=$(aws ec2 describe-vpcs --region af-south-1 \
  --filters "Name=tag:DeletionGroup,Values=sbsa-egress-sit-2026-09-17" --query 'Vpcs[0].VpcId' --output text)
aws ec2 describe-network-interfaces --region af-south-1 --filters "Name=vpc-id,Values=$EVPC" \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,InterfaceType,Status,Description]' --output table
```

Only the proxy's own ENI and the NLB's ENI should be listed; both are destroyed by Terraform.
Anything else (an `interface` ENI with an empty description, a stale `network_load_balancer`
one) is a leak that will make the VPC delete fail — delete it by hand first.

```bash
cd ~/Documents/Blockchain/Besu/sbsa/mimic_egress/terraform
terraform plan -destroy -var-file=environments/sit/primary.tfvars -out=destroy.plan   # 29
terraform apply destroy.plan
```

This removes the three ledger routes, the peering and the hosted-zone association — the
pieces that live inside the ledger VPC — so it **must** precede `mimic_vpc`.

### T5. `mimic_vpc` (optional — free to leave up; delete for a true zero)

```bash
cd ~/Documents/Blockchain/Besu/sbsa/mimic_vpc/terraform
terraform plan -destroy -var-file=environments/sit/primary.tfvars -out=destroy.plan   # 65
terraform apply destroy.plan
```

The runbook allows leaving the mimic running between phases (only flow logs bill, and an
empty VPC generates almost none). Destroy it when the instruction is "everything".

### T6. Sweep + zero-check — direct describes, never the tag API (B16)

```bash
R=af-south-1
for DG in sbsa-sit-2026-09-17 sbsa-egress-sit-2026-09-17 sbsa-net-sit-2026-09-17; do
  echo "== $DG"
  aws ec2 describe-volumes --region $R --filters "Name=tag:DeletionGroup,Values=$DG" \
    --query 'Volumes[].[VolumeId,State,Size]' --output text          # PVC/root leaks: delete-volume each
  aws ec2 describe-vpcs --region $R --filters "Name=tag:DeletionGroup,Values=$DG" \
    --query 'Vpcs[].VpcId' --output text
  aws ec2 describe-instances --region $R --filters "Name=tag:DeletionGroup,Values=$DG" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
done
aws ec2 describe-vpcs --region $R --query 'Vpcs[?IsDefault==`false`].VpcId' --output text         # empty
aws eks list-clusters --region $R --query 'clusters' --output text                                  # empty
aws elbv2 describe-load-balancers --region $R --query 'LoadBalancers[].LoadBalancerName' --output text
aws ec2 describe-vpc-endpoints --region $R --query 'VpcEndpoints[].VpcEndpointId' --output text     # empty
aws ec2 describe-vpc-peering-connections --region $R \
  --query 'VpcPeeringConnections[?Status.Code!=`deleted`].VpcPeeringConnectionId' --output text
aws ec2 describe-network-interfaces --region $R --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
aws ec2 describe-volumes --region $R --query 'Volumes[].VolumeId' --output text                     # empty
aws route53 list-hosted-zones --query 'HostedZones[].Name' --output text                            # no chain.internal / egress.mimic.internal
aws secretsmanager list-secrets --region $R --include-planned-deletion \
  --query 'SecretList[].Name' --output text                          # ONLY the two sbsa-besu-primary-* kept ones
aws kms list-keys --region $R --query 'Keys[].KeyId' --output text | xargs -n1 -I{} \
  aws kms describe-key --region $R --key-id {} --query 'KeyMetadata.[KeyId,KeyState]' --output text  # PendingDeletion is fine
aws logs describe-log-groups --region $R --query 'logGroups[].logGroupName' --output text
aws s3api list-buckets --query 'Buckets[?starts_with(Name,`sbsa-`)].Name' --output text            # empty
aws cloudtrail list-trails --region $R --query 'Trails[].Name' --output text                       # empty
aws ec2 describe-internet-gateways --region $R --query 'InternetGateways[].InternetGatewayId' --output text  # only the default VPC's
```

Anything with a `DeletionGroup` tag still listed → delete it by hand (`delete-volume`,
`delete-network-interface`, …) and record it as a finding.

### T7. Backstop when state is lost or a destroy is stuck — `full-delete.sh`

Tag-keyed, dry-run by default, H26-guarded (refuses unless the caller names the deploy-test
account and region and they match the live identity), and requires typing
`DELETE <deletion_group>` to act. One DeletionGroup at a time, chain first:

```bash
cd ~/Documents/Blockchain/Besu/sbsa/sbsa_besu
export AWS_REGION=af-south-1 EXPECT_REGION=af-south-1 EXPECT_ACCOUNT_ID=867728055761
scripts/maintenance/full-delete.sh sbsa-sit-2026-09-17                 # dry-run: prints the inventory
scripts/maintenance/full-delete.sh sbsa-sit-2026-09-17 --confirm
scripts/maintenance/full-delete.sh sbsa-egress-sit-2026-09-17 --confirm
scripts/maintenance/full-delete.sh sbsa-net-sit-2026-09-17 --confirm
```

Read the dry-run inventory before confirming — it is keyed strictly on the tag, so a wrong
DeletionGroup deletes nothing, but a right one deletes keys and data irreversibly.

### T7b. Recorded results — ALL DESTROYED, ZERO-CHECK CLEAN (17:20 UTC)

| Root | Destroyed (UTC) | Count | Notes |
|---|---|---|---|
| `runner` | 16:57 | 11 | Octopus worker deleted from the pool afterwards |
| `chain` | 17:06 | 106 | 2 CMKs → `PendingDeletion` (7 d) as expected; 23 secrets force-deleted |
| `shared` | 17:13 | 27 | |
| `mimic_egress` | 17:17 | 29 | |
| `mimic_vpc` | 17:18 | 65 | |
| zero-check | 17:20 | — | VPCs/EKS/EC2/LBs/endpoints/peering/ENIs/volumes/logs/buckets/trails all **empty**; IGW = the account-default VPC's only; secrets = the two kept `sbsa-besu-primary-*`; KMS = 2 customer keys `PendingDeletion` + 2 AWS-managed |

(Times are the S3 state objects' `LastModified` — each root's state is written at the end
of its destroy, which makes it the exact stop time without anyone watching a clock.)

**Spend:** `shared` 15:09→17:13 (2.1 h × $0.45) ≈ $0.93; `chain` ~15:35→17:06 (1.5 h ×
~$1.25) ≈ $1.9; runner + egress mimic ≈ $0.1; ≈ **$3.0 for the day**, well inside the $15 cap.

### T8. Close the run

- The rows are in `docs/test-run-log.md` (applies: mimics 14:3x/14:5x, `shared` 15:09,
  `chain` ~15:35, `runner` 15:52 UTC; destroys 16:57–17:18; ≈ $3.0 total).
- Code fixes are committed (B21–B24 + the output fix); the state objects in S3 stay (cheap,
  reused by the next init). **Doc drift to fix at the next re-init:** the two mimic roots
  are still on `besu/network/{main,egress}.tfstate` (no `<env>` segment) — move them to
  `besu/sit/…` the same way `shared`/`chain`/`runner` were moved today.
- The three DeletionGroups are spent — bump them again before the next run.

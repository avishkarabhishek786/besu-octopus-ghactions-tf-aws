# RUNBOOK — building the SBSA Besu platform on a cloud-team VPC

**Status:** 2026-09-21 · **CT-5: the cloud team provides a shared EKS cluster and a namespace — we no
longer build EKS.** Design record `CLOUD_TEAM_REDESIGN_NOTES.md` §12; asks `CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md`
(#27–#38). Phases B, C and E.1 (the R-9 mock) stand; **Phase D is paused at item 4** until it is answered
(see §2). Branch `shared-eks-namespace`; the own-cluster build is frozen on `own-eks-cluster-design`.
The three projects live in one repository since 2026-09-18 (§1).
**Audience:** the operator. Deployment is **advise-only** — this document tells
you what to run; nothing is executed for you.

---

> **Looking for which script to run?** [`../scripts/README.md`](../scripts/README.md) is the
> index: all 31, what each does, **where it has to run** (laptop vs In-VPC EC2 Runner vs build
> host — not a preference; the API endpoint is private and the VPC has no egress), and
> whether it is read-only, mutating, or irreversible. The detail is in each script's own
> header, which `-h` prints.

## 1. Orientation — three projects, one repository

| Directory | Role | Lifetime |
|---|---|---|
| `besu-aws` (beside this repository, not in it) | The proven single-VPC build. **Reference only** — source of truth for porting. | Frozen |
| `mimic_vpc/` | Impersonates the bank cloud team's network hand-over. | Throwaway — delete when the real VPC exists |
| `mimic_egress/` | Impersonates the bank's shared egress proxy (R-9, CD-63). | Throwaway — delete when the R-10 ticket is answered |
| `sbsa_besu/` | The platform: Besu and everything around it, in **a namespace of the cloud team's shared cluster** (CT-5; was 2 EKS clusters of our own). | Permanent |
| `mimic_eks/` | Impersonates the shared EKS cluster and our namespace (CT-5, D-32). **Built 2026-10-09, `profile = "hostile"` by default** — it breaks every platform gate deliberately, so each can be seen to fire. Bills per hour, unlike `mimic_vpc`. | Throwaway |

They were **separate git repositories until 2026-09-18** and are now three
subdirectories of one. The reason they were kept apart still stands — the
mimics' `CLAUDE.md` says *"create the VPC"*, the platform's says *"NEVER create
network-layer resources"*, and the second rule is the one that protects the
cloud team's network — but the three move together: the hand-over file
`mimic_vpc` emits is an input to `mimic_egress`, whose own hand-over is an input
to `sbsa_besu`, so one change to the contract was three commits in three
histories with nothing tying them together. The guard against dilution is now
structural rather than repository-level: each subtree keeps its own `CLAUDE.md`
and its own `.gitignore`, the root `.gitignore` is the floor beneath all three,
and the IAM control is untouched — the platform is deployed by Octopus
`besu-infra` under its own role, which can still be denied `ec2:CreateVpc`
outright, while the mimics are only ever applied from the laptop and never ship.
The pre-merge histories are kept outside the repository at
`../_sbsa-git-history-backup-2026-09-18/`.

The platform was forked from `besu-aws@prod`, so it already carries the
C6 / C10 / C12 + H1–H27 hardening baseline. `upstream` still points at the source
repo for cherry-picking later fixes.

> **How the platform gets built — who runs what.** GitHub Actions mirrors images into ECR
> and packages the platform; it **never deploys**. Octopus deploys: the AWS-layer Terraform
> from a hosted worker, and — **since R-9 closed on 2026-09-14** — the in-cluster layer and the
> validator upgrades too, by driving the in-VPC EC2 runner as a **polling Tentacle worker**
> through the bank's shared egress proxy (`CICD_DESIGN_NOTES.md` §7, CD-55..CD-63). Until that
> Tentacle path is built and tested (CD-64), the runner still does that work over SSM exactly
> as in `besu-aws`; afterwards SSM remains the **break-glass** path. **`CICD_DESIGN_NOTES.md`
> §0 is the full picture** — read it before touching the pipeline. Do **not** remove the EC2
> runner: it is both the Tentacle host and the only shell that can reach the cluster.

> **CT-5 note.** None of the above changed — but the runner matters more, not less: it is
> the only host that can ask the cluster-side questions in `modules/cluster-contract`,
> because the EKS endpoint is private. Its cluster access becomes a namespace-scoped
> access entry the cloud team creates (#32), not the admin entry we create today.

## 2. Where things stand

**Done**

- All design documents consolidated into `sbsa_besu/docs/` — see `docs/README.md`
- `mimic_vpc` complete — VPC, 15 subnets, route tables, NACLs, DHCP options,
  flow logs, gateway endpoints. `terraform validate` passes.
- `sbsa_besu` forked; `module "network"` and `modules/network/` **deleted** — it
  can no longer create a VPC.
- `modules/network-contract` — creates nothing, asserts everything. **8 gates.**
- Region made explicit and portable; `scripts/preflight/verify-region.sh` added.
- **Phase B done (2026-08-30, torn down 2026-09-04)** — mimic was applied in us-east-1,
  `vpc-083910a0dc47618aa`, 65 resources; `verify-contract.sh` **27/27**.
- **Phase C done (2026-08-30)** — hand-over emitted and consumed; the platform
  root plans clean against the live mimic with all 8 gates passing, and the
  **negative test passed**: dropping `kubernetes.io/role/internal-elb` from one
  lb subnet aborted the plan citing #4. Tag restored.

- **Phase E.1 mock DONE (2026-09-17)** — the R-9 polling-Tentacle path validated live in
  af-south-1 end to end: `mimic_vpc` → `mimic_egress` → `shared` (first platform apply) →
  `chain` AWS layer (4 nodes) → `runner` → 8/8 probes → `install-tentacle.sh` → worker
  **Healthy** → Script Console `kubectl get nodes` (4 Ready) → stop/start keeps the identity.
  CD-56..CD-61 confirmed. Four defects found and fixed live (**B21–B24**); one design answer
  (Environment manager scoped to the Space is enough to register — CD-65). Full record with
  every command, output and the teardown: `docs/deploy-run-2026-09-17-r9-mock.md`. State keys
  for `shared`/`chain`/`runner` now carry the `<env>` segment (`besu/sit/…`). The two mimic
  roots were last initialised on the old `besu/network/{main,egress}.tfstate`; their docs and
  `backend.tf` now specify `besu/<env>/{network,egress}.tfstate`, so **their next
  `terraform init` must pass the new key**. Everything is destroyed, so a fresh init is
  enough — no `-migrate-state`; the two old objects hold empty state and can be deleted.

**CT-5 — 2026-09-21.** The cloud team runs a **shared EKS cluster** and allots us a
**namespace**; their VPC has **role-separated subnets with rules they define**. Everything
cluster-scoped leaves the platform (`modules/eks`, the node/cluster IAM roles, the EBS CSI
addon + StorageClass, the runner's admin access entry, and the four add-on `helm_release`s —
LBC, Secrets Store CSI + provider, kube-prometheus-stack, Fluent Bit). What replaces it: a
cluster hand-over (`eks-handover.auto.tfvars`), a `modules/cluster-contract` that asserts it,
a `verify-subnet-rules.sh` preflight for the nine flows in §12.4 of the redesign notes, and a
third mimic, `mimic_eks`. The E.1 result (runner + Tentacle + egress) is unchanged and more
important, not less: the runner is the only host that can ask the cluster-side questions.
**Nothing is rebuilt until `CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md` is answered** — the three
command outputs in shared-cluster requirements §4 decide which files are deleted versus made conditional. The one item
that is not configuration: **#29, a written node-maintenance agreement** — their node rotation
can halt the chain (H1), and no setting on our side prevents it.

**Phase D in progress (2026-08-30)** — items 1–3 of `PORTING.md` complete, item 4
partial. All local, all free; nothing of the platform is applied. **Paused 2026-09-21 (CT-5).**

| Item | State |
|---|---|
| 1. Four-root split | ✅ `terraform/{shared,runner,chain}/`; `app/` deferred to item 5 |
| 2. `shared` endpoints root | ✅ 15 interface endpoints × 3 AZ + PHZ; plans clean (27 resources) |
| 3. Dead network variables | ✅ four removed; `output "vpc_cidr"` was reporting a VPC that does not exist |
| 4. Air-gapped supply chain | ◐ images + CA trust done; pull secret, Helm proxy repos, and the chart-image gap open |
| 5. Second cluster · 5a. Event pipeline · 6. Isolation · 7. Teardown | not started |

Both roots plan clean against the live mimic: `shared` 27 resources, `chain` 101,
no warnings.

Also split: the tfvars, into `common.tfvars` (the six values every root shares)
and `chain.tfvars`. `deletion_group` is the teardown key — roots disagreeing
about it would leave a whole root running after a "successful" teardown.

**Next:** finish `PORTING.md` item 4, then item 5. Phase A (sending the
requirements document to the cloud team, Q-2/Q-3/Q-5 and Q-4a..Q-4e still open) and
the ECR mirror build run in parallel and block neither.

**Remaining platform work** is tracked in `PORTING.md`; defects found along the
way are in `docs/build-findings.md`.

## 3. Prerequisites

| | |
|---|---|
| Tools | **`terraform >= 1.10`** — the roots require it: `use_lockfile` (S3-native state locking) landed in 1.10 and DynamoDB locking is deprecated as of 1.11, so a 1.5–1.9 CLI cannot `init` these backends at all. `aws` CLI, `jq`. The pinned version the runner and CI both use is **1.16.1**, from `scripts/runner/runner-tools.manifest`. |
| State | Reuse the existing S3 bucket from `besu-aws`. Keys are **environment-scoped**: `besu/<env>/network.tfstate` (mimic) and `besu/<env>/{shared,runner,chain,app}.tfstate`, where `<env>` is **`sit` | `uat` | `prod`**. **The `<env>` segment is load-bearing** — without it the three environments share state and the second apply reconciles one environment against another's resources. |
| Region | **`af-south-1` for ALL THREE environments** (`sit`/`uat`/`prod` = Octopus SIT/UAT/PROD; three environments as of 2026-09-09). Confirmed enabled on the target bank account 2026-09-09. ✅ **Region readiness VERIFIED 2026-09-04** — `scripts/preflight/verify-region.sh af-south-1 m6i.xlarge 1.35` returned **7 passed / 0 failed**: region ENABLED, 3 AZs, `m6i.xlarge` in all 3, all 15 interface endpoint services + both gateway services available, EKS 1.35 offered. `az_ids = ["afs1-az1","afs1-az2","afs1-az3"]`. |
| Runner bundle (D-21) | Between the chain AWS-layer apply and applying `terraform/runner`: `AWS_REGION=af-south-1 scripts/runner/push-runner-bundle.sh` (toolchain + source) then `... ENV=sit scripts/runner/push-deploy-config.sh` (gitignored config). The runner has **no internet and no package manager** — if the bundle is missing, cloud-init fails loudly rather than hanging. ✅ **All four toolchain digests recorded 2026-09-10**, so the bundle build verifies against our own pin instead of warning; re-run `push-runner-bundle.sh --record` only when a pinned version changes. |
| Registry (**private ECR**, CT-3a) | Needed before Phase E, not before. Design record: `CLOUD_TEAM_REDESIGN_NOTES.md` §11. It is a **mirror you populate**, not a proxy — pull-through cache cannot work in this VPC (D-17). |

---

## Phase A — Send the requirements document

Send `NETWORK_REQUIREMENTS_CLOUD_TEAM.md` to the cloud team. It is the long pole
— Q-2 to Q-5 remain open and **Q-2 alone is worth ~$400/month**. Everything below
proceeds regardless of when they reply.

*(Git housekeeping in `besu-aws` is deliberately skipped: all design documents now
live here in `sbsa_besu/docs/`, which is version-controlled. `besu-aws` is
reference-only and frozen.)*

---

## Phase B — Apply the mimic (~$0)

> ### ✅ ONE-TIME MIGRATION — DONE 2026-09-04 (kept as the record of why)
>
> The mimic VPC was applied in `us-east-1` while the tfvars moved to `af-south-1`.
> It was destroyed first — **65 destroyed, zero-check clean** — then the region flipped.
> Nothing to do; this box explains the ordering in case a region ever changes again.
>
> **Never apply first after a region change.** Changing `region` changes the AWS *provider*, so Terraform
> would look for the existing resource IDs in af-south-1, not find them, plan to create
> everything fresh, and leave the us-east-1 resources **orphaned from state but still
> alive**. Destroy them while state still matches, using an explicit region override:
>
> ```bash
> cd mimic_vpc/terraform
> terraform plan -destroy \
>   -var-file=environments/sit/primary.tfvars \
>   -var region=us-east-1 \
>   -var 'az_ids=["use1-az1","use1-az2","use1-az4"]'      # review: expect ~65 resources
> terraform destroy \
>   -var-file=environments/sit/primary.tfvars \
>   -var region=us-east-1 \
>   -var 'az_ids=["use1-az1","use1-az2","use1-az4"]'
> ```
>
> `terraform destroy` works from state, so the name/tag values in the file do not matter —
> only `region`, which must match where the resources actually are. Then confirm zero:
>
> ```bash
> aws ec2 describe-vpcs --region us-east-1 \
>   --filters "Name=tag:DeletionGroup,Values=sbsa-net-2026-08-30" \
>   --query 'Vpcs[].VpcId' --output text        # expect: empty
> ```
>
> Only then apply in the new region. If a destroy is ever run *after* a region flip and
> the resources are orphaned, `full-delete.sh` keyed on that `DeletionGroup` **in the old
> region** is the recovery path.
>
> **Zero-check with direct describes, not the tag API** — it kept listing 3 already-deleted
> ARNs for minutes after this teardown (**B16**).

AZ IDs are **account-specific**. Look up yours:

```bash
aws ec2 describe-availability-zones --region af-south-1 \
  --query 'AvailabilityZones[].[ZoneName,ZoneId]' --output table
```

```bash
cd ~/Documents/Blockchain/Besu/besu-octopus-ghactions-tf-aws/mimic_vpc/terraform
cp environments/sit/primary.tfvars.example environments/sit/primary.tfvars
# edit: az_ids, owner, cost_center, deletion_group

terraform init -backend-config="bucket=<state-bucket>" \
               -backend-config="key=besu/<env>/network.tfstate"   # sit | uat | prod \
               -backend-config="region=<state-region>"
terraform plan -var-file=environments/sit/primary.tfvars
```

Expect **~65 resources, all free**:

| Count | Resource |
|---|---|
| 15 | subnets |
| 15 | route tables (one per subnet — #12 keeps ledger routing separate) |
| 15 | route-table associations |
| 9 | NACLs + their allow-all baseline rules (3 each) |
| 8 | VPC, secondary CIDR association, DHCP options + association, flow log + log group + IAM role + policy |
| 2 | gateway endpoints (S3, DynamoDB) |
| 1 | `terraform_data` region gate (no infrastructure) |

Review the plan before applying. The only billable line is the flow-log group.

```bash
terraform apply -var-file=environments/sit/primary.tfvars
cd .. && ./scripts/verify-contract.sh
```

`verify-contract.sh` asserts the contract against **live AWS**, not state,
because the platform will meet reality rather than state.

> **Leave the mimic running.** VPC, subnets, route tables, NACLs and gateway
> endpoints cost nothing; only flow logs bill, and an empty VPC with no ENIs
> generates almost no records. The same-day teardown rule exists for compute and
> does not apply here. Having the mimic up throughout Phase D is worth a lot.

---

## Phase C — Prove the gate (free — **do not skip the negative test**) ✅ DONE 2026-08-30

```bash
./scripts/emit-handover.sh          # also symlinks the result into every platform root

cd ../sbsa_besu/terraform/chain
terraform init -backend-config="bucket=<state-bucket>" \
               -backend-config="key=besu/<env>/chain.tfstate" \     # sit | uat | prod
               -backend-config="region=<state-region>" \
               -backend-config="use_lockfile=true"
terraform plan -var-file=../environments/sit/common.tfvars \
               -var-file=../environments/sit/chain.tfvars
```

All eight gates should pass. Now **break it deliberately**:

```bash
aws ec2 delete-tags --resources <lb-subnet-id> --region af-south-1 \
  --tags Key=kubernetes.io/role/internal-elb

terraform plan -var-file=../environments/sit/common.tfvars \
               -var-file=../environments/sit/chain.tfvars   # must FAIL citing #4
```

If it does not fail, the gate is decorative and must be fixed. Restore with
`terraform apply` in the mimic afterwards — and **answer `yes`**: cancelling the
apply leaves the mimic in the broken state the test created.

This costs nothing and tests the single most likely go-live failure: a missing
tag whose absence otherwise surfaces days later, at Service-creation time, after
budget is spent.

**Result (2026-08-30):** both halves passed. The plan resolved every gate,
module and output against the live mimic; the negative test aborted the plan
with the intended #4 message. This was the first time any gate had been observed
*failing* — until then they had only ever been seen passing, which given four
gate bugs found during construction (two of which passed silently) was not
evidence they worked.

Two placeholder values in the env tfvars had to be set first: `chain_id` (the
H12 validation rejects the `0` default by design) and `environment`. Verified
harmless: `permissioning_admin_account = ""` is unused while
`account_permissioning_mode = "off"`, and `besu_version = ""` falls back to
`26.6.1` at `terraform/main.tf:26`.

---

## Phase D — Port (free, local)

Follow `PORTING.md` in order: four-root split → `shared` endpoints root → dead
variables → registry/images → second cluster → isolation model → teardown.

Everything is `terraform validate`-checkable against the running mimic.
The ECR mirror build slots in before the image parameterisation.

**Done so far (2026-08-30):** the four-root split and the `shared` endpoints root.
Each root is a sibling directory under `terraform/`; `contract/handover.tf` and the
emitted `network-handover.auto.tfvars` are symlinked into each so the contract
cannot drift. Re-run `mimic_vpc/scripts/emit-handover.sh` after any mimic change —
it now recreates those symlinks too.

**tfvars are split per scope.** `common.tfvars` holds the six values every root
shares (`project_name`, `environment`, `deletion_group`, `owner`, `cost_center`,
`primary_region`); `chain.tfvars` holds the rest. Every root gets `common.tfvars`,
and `chain` additionally gets `chain.tfvars`. They are defined once rather than
copied because `deletion_group` is the teardown key — `full-delete.sh` finds
resources by that tag, so two roots given different values would leave a whole
root's resources running after a "successful" teardown, and interface endpoints
bill about $11/day.

Roots initialise independently, each with its own backend key:

```bash
cd ~/Documents/Blockchain/Besu/besu-octopus-ghactions-tf-aws/sbsa_besu/terraform/shared
terraform init -backend-config="bucket=<state-bucket>" \
               -backend-config="key=besu/<env>/shared.tfstate"     # sit | uat | prod \
               -backend-config="region=<state-region>" \
               -backend-config="use_lockfile=true"
terraform plan -var-file=../environments/sit/common.tfvars
```

The `shared` plan is the one to read carefully: it is the first root that creates
billable resources. Expect **45 interface endpoint ENIs** (15 services × 3 AZ) and
a hosted zone; the gateway endpoints should be **absent**, because the mimic
reports `gateway_endpoints_exist = true`. Interface endpoints bill per ENI-hour
and are the largest fixed cost in the air-gapped design — `terraform output
billable_endpoint_eni_count` states the number plainly.

---

## Phase E — First deploy-test (billable)

Only once the registry is populated and `scripts/preflight/verify-images.sh -e sit` passes
**from the In-VPC EC2 Runner** (under CT-3a the registry is ECR, populated by an explicit
`crane copy` mirror — ECR pull-through cache cannot work here, see D-17).

> **`-e` is required** and takes `sit` | `uat` | `prod`. It lost its default on 2026-09-09:
> with three environments a defaulted flag resolves the image list from one environment's
> tfvars while the operator believes they are checking another.
>
> **Two other endpoint checks belong here, and both must run from the runner too:**
> `scripts/preflight/verify-endpoints.sh <vpc-id> af-south-1 --route-tables <ids>` asserts the
> 16 endpoints exist, Private DNS is on where its absence is fatal, the endpoint security
> group admits 443, the S3 gateway is associated with our route tables, and both ECR policy
> traps (#20, #23). `verify-images.sh` then proves an actual pull. **A laptop passes both
> while the cluster still cannot pull**, which is the whole reason they run in-VPC.
>
> **CT-5 (D-38) extends that sentence one step further:** on a cluster we do not own, the
> *runner* passes while the cluster cannot pull, because the runner authenticates as itself
> and kubelet pulls as the cloud team's node role. `verify-images.sh` cannot see that
> difference. The gate that can is a **canary pod** in our namespace (#38) — redesign notes
> §12.13.
>
> **The CT-5 preflight sequence, all from the runner, all read-only, all free** (built
> 2026-10-09; each failure cites a requirement number from
> `CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md` §3):
>
> ```bash
> # 1. the cluster-side contract: version ceiling, CRDs + controllers, StorageClass,
> #    quota headroom, access scope (including what we must NOT be able to do), CNI policy
> scripts/preflight/verify-cluster.sh -n <ledger-ns> -a <app-ns> -s <storageclass>
>
> # 2. will the namespace actually ACCEPT our pods? (Pod Security, quota, LimitRange,
> #    RBAC, missing CRDs — all in one server-side dry-run)
> helm template <release> helm/charts/besu-node -f <values> > /tmp/rendered.yaml
> scripts/preflight/verify-admission.sh -n <ledger-ns> -f /tmp/rendered.yaml
>
> # 3. can THE CLUSTER pull, as opposed to can WE pull? (#38 — the only authoritative form)
> scripts/preflight/verify-pull-canary.sh -n <ledger-ns> -i <one mirrored image ref>
>
> # 4. the endpoints — add --pod-identity if #31 answered Pod Identity, or eks-auth is
> #    missing and the symptom is a credential call that HANGS
> scripts/preflight/verify-endpoints.sh <vpc-id> af-south-1 --route-tables <ids> [--pod-identity]
>
> # 5. the cloud team's SUBNET RULES against our flow table (#34). Rule-order aware,
> #    both protocols, and the stateless return path — which is where half the
> #    failures in this class live.
> #    --control-plane is the cluster's subnets (where its control-plane ENIs may go):
> #      aws eks describe-cluster --name <c> --query 'cluster.resourcesVpcConfig.subnetIds'
> #    Without it the CLUSTER's own flows C-1..C-3 and F-7 are skipped — and those are
> #    what stopped a node joining on 2026-10-09 (B27) while every F-n check passed.
> scripts/preflight/verify-subnet-rules.sh --region af-south-1 \
>     --node <node subnets> --lb <lb subnets> --control-plane <cluster subnets> \
>     [--endpoint <ids>] [--data <ids>] [--runner <id>] [--node-sg sg-xxx]
> ```
>
> **Read its WARNs, not only its FAILs.** It distinguishes three things a pass/fail would
> hide: a flow permitted only by a `0.0.0.0/0` rule (allowed, but the run is not evidence
> about that flow); a flow permitted *incidentally* by a stateless return rule, because
> every port we listen on is inside 1024-65535; and a flow where one direction could not be
> evaluated at all.
>
> **After deploying**, the assertions that are only observable then — and three of which
> look like success until asserted:
>
> ```bash
> scripts/validation/verify-deployed.sh -n <ledger-ns> -N 4 \
>     -R <our-irsa-role-arn-substring> -g <target-group-arn> -r <ops-rpc-url> -j <jwt> \
>     --probe-netpol
> ```
>
> **Do not read a skipped assertion as a pass.** `verify-deployed.sh` counts anything it
> could not evaluate as a WARN and says so in its summary, because a check that cannot fail
> is worse than no check (CICD §11.3).

**Two decisions needed first:**

1. **The cost cap.** Two-cluster burn ≈ **USD 2.40/hour** in af-south-1 (~31% above
   the us-east-1 figure of $1.85 this was originally sized against), so the
   inherited USD 15 cap buys ~8 hours. Recommendation: **USD 25** for full
   two-cluster runs, USD 15 retained for chain-only. This raises a standing hard
   rule and needs your explicit sign-off.
2. **Chain-only first.** Run Phase 2 alone before adding the app cluster —
   fewer moving parts, and it is the half carrying the SWIFT plane.

Same-day teardown is mandatory. Order: `app` → `chain` → `runner` → `shared`.
Append a row to `docs/test-run-log.md` for every apply/destroy cycle.

### E.1 — The Octopus worker path (R-9 closed 2026-09-14; CD-55..CD-65) ✅ VALIDATED LIVE 2026-09-17

Additive to the SSM path above, which stays as break-glass. **Advise-only, as always.**
**Run in full on 2026-09-17** (`docs/deploy-run-2026-09-17-r9-mock.md`): steps 1–10 passed,
CD-56..CD-61 confirmed. The table below carries what that run taught, step by step.

| Step | Where | What | Why |
|---|---|---|---|
| 1 | laptop | `mimic_vpc` applied — with `pinned_ip_reservations` set to the runner's address (B43: otherwise the EKS nodes' CNI warm pool can take it); `cp mimic_vpc/network-handover.auto.tfvars mimic_egress/terraform/` | the egress mimic peers with the ledger VPC and routes its **ledger** tables (CD-60) |
| 2 | laptop | `mimic_egress`: fill `environments/sit/primary.tfvars` (**`octopus_instance`** = your free-tier instance label, **`runner_private_ip`** = an address in a ledger subnet, `egress_vpc_cidr` disjoint from the /20 and from 100.64/16) → `plan` (~25 resources; NLB + `t3.micro` are the billables, ≈ $0.6/day) → `apply` → `scripts/emit-handover.sh` | builds the assumed egress shape (CD-63) and writes `egress-handover.auto.tfvars` into `sbsa_besu/terraform/` + the `runner/` symlink |
| 3 | laptop | in Octopus Cloud: a **Space**, a **Static worker pool** `sit-ledger-workers`, a service account + API key (Full Access on the key; scope lives on the user) that may register workers. Then two Secrets Manager secrets **named with the chain's `name_prefix`** (`terraform -chdir=terraform/chain output -raw name_prefix` — currently `<project>-primary`, NOT `<project>-<env>`): `<name_prefix>-octopus-register-key` (the key, via `file://`, never on argv) and `<name_prefix>-tentacle-cert` (created EMPTY; `install-tentacle.sh` fills it, CD-61). **No IAM change:** the runner's deploy policy already scopes `<name_prefix>-*` secrets (read + write) in both `full-stack` and `in-cluster` modes, so `deploy_extra_secret_arns` is NOT needed for these. **The service account must be a member of a team that holds a Space-scoped role, and the team must be SAVED** — otherwise `register-worker` fails with *"A space with name … could not be found … the user has access to this space"* (the key authenticates; a bad key gives 401). **Environment manager scoped to the Space is sufficient** (2026-09-17, CD-65); Space Manager is not needed. Verify before installing: `GET /api/spaces` with the key, through the proxy, must list the Space | the runner reads the key once, from Secrets Manager — never from a tfvars; the mock uses service account `besu-register` in team `BesuTestTeam` |
| 4 | laptop | **`shared` → `chain` (AWS layer)** first — the runner root reads the chain's state (VPC, ledger subnets, EKS cluster for its access entry, node SG, artefact bucket, deploy-config secret), so the Tentacle test rides on the real prod path and its cost (~$1.5–2/h, EKS + nodes). Then `push-runner-bundle.sh` (the bundle now carries `tentacle/`; ships **HEAD** — commit first) and `ENV=sit push-deploy-config.sh` (ships `common.tfvars` + `chain.tfvars` + **both** hand-overs — B18, B22; the log line must say **4 file(s)**) | the Tentacle binary arrives over the S3 gateway, never from `download.octopusdeploy.com` (CD-59) |
| 5 | laptop | `terraform/runner` (init key `besu/<env>/runner.tfstate`; vars `region`, `chain_state_bucket/key/region`): `plan` = **11 to add**, the instance with **`private_ip` = the hand-over's /32** and the subnet for `runner_az_id`; `apply`; then the `runner_bootstrap_check` one-liner → `status: done` / `OK: tools=5 source=<sha> deploy-config: extracted` | CD-60: the allowlisted source is pinned, not observed |
| 6 | laptop | baseline: `openssl s_client -connect polling.<instance>.octopus.app:443 -servername polling.<instance>.octopus.app </dev/null 2>/dev/null \| openssl x509 -fingerprint -sha256 -noout` | the reference for probe 7 (no-interception, CD-58) |
| 7 | laptop | `mimic_egress/scripts/verify-egress.sh` — all **8 probes** must pass (it takes the step-6 baseline itself; probe 8 runs on the proxy host **direct to Squid**, not via the VIP — a target cannot hairpin through its own NLB, B23) | proves allow ×2, deny ×4, no interception, other-source refused |
| 8 | runner (SSM, root) | `install-tentacle.sh` with `OCTOPUS_INSTANCE`, `OCTOPUS_SPACE`, `OCTOPUS_WORKER_POOL`, `OCTOPUS_API_KEY_SECRET`, `EXPECTED_POLLING_CERT_SHA256`, `TENTACLE_CERT_SECRET` (the `runner_tentacle_install_hint` output prints the line; the filled-in line used on 2026-09-17 is in the run doc §8). Idempotent — re-run after fixing anything. Tentacle's instance index lives in `/etc/octopus` (B24; the script creates it). To refresh the script on a live runner: `push-runner-bundle.sh --source-only` on the laptop, then on the runner `aws s3 cp s3://<bucket>/source/source.tar.gz /tmp/s.tgz && sudo tar xzf /tmp/s.tgz -C /opt/besu-deploy/sbsa_besu` | CD-57 exactly: probe → user → instance/cert → polling-proxy ON, web proxy OFF → one proxied `register-worker` → our systemd unit |
| 9 | Octopus | Infrastructure → Workers: the worker is **healthy** (thumbprint = the one in `…-tentacle-cert`); **Tasks → Script Console → worker pool** → `aws eks update-kubeconfig --name <cluster> --region af-south-1 --kubeconfig /tmp/kc && KUBECONFIG=/tmp/kc kubectl get nodes -o wide` (binding a Kubernetes target to the pool is the deployment-project form of the same thing) | the hosted control plane reaches the private endpoint through the in-VPC worker |
| 10 | Octopus | **stop** the runner (`aws ec2 stop-instances`), wait, **start** it: the worker returns healthy with the same thumbprint and IP | CD-61 stop/start; the identity survives |
| 11 | teardown | `sbsa_besu` roots → `mimic_egress` → `mimic_vpc`. Check the egress VPC for leaked NLB ENIs first | this project's routes/zone live in the ledger VPC; destroy it before the VPC |

**What must NOT be done:** set `HTTP(S)_PROXY` anywhere on the runner; enable `Tentacle proxy`
(the web-request one); add a third hostname or a wildcard to the allowlist; add the egress
route to app/lb/endpoint/data tables; run `install-tentacle.sh --skip-probe` against the
bank's proxy.

### E.2 — B27 live proof: a cluster on the restrictive NACLs (≈ $0.5, ≈ 1 h) ✅ RUN 2026-10-10

> **Result:** every prediction below held — checker live 46/0/12/4, break → C-1 ×6 + F-7 ×3;
> 3/3 nodes joined with control-plane ENIs in az1/az2 only; C-3 live; C-1 removed → only the
> az3 node NotReady, restored → Ready. B27 closed. The teardown found **B34** (step 8 now
> sweeps for it). Full log: `docs/deploy-run-2026-10-10-b27-live.md`.

**Why.** On 2026-10-09 a node in the one AZ without a control-plane ENI never joined, because
`mimic_vpc`'s `flows` NACLs carried none of the cluster's own traffic (B27). The fix
(`862f6c2`, keys `d12903e`) adds #34's C-1..C-4 and F-7's missing half (B32), and was
proven **offline only**: the real checker against each plan's rules. This run repeats the
exact 10-09 failure — **hostile profile, nodes in the app subnets, `nacl_mode = flows`** —
and expects it not to happen.

**What it proves:** the rules exist in AWS as planned (the checker reads them live); C-1 (a
node registering across a NACL); C-3 (API server → kubelet across a NACL); and, optionally,
that removing C-1 takes a joined node down. **What it does not:** **C-2** — no image with a
shell can be pulled yet (ECR is empty, no `crane` on the laptop, the add-on images have no
shell), so pods → CoreDNS stays offline-proven until the mirror runs; and **F-7 as a runner
path** — no runner is built. F-7 shares C-1's ingress 443 rule on the control-plane subnets,
so C-1's evidence covers the rule, not the runner.

Advise-only (§0.6): every command below is for the operator. Times and outputs go in a
`docs/deploy-run-<date>-b27-live.md` log, as on 10-09. `$SP` is any scratch directory.

**0. Pre-checks** — the account is clean; same commands as the 10-09 log §0 (VPCs, EKS,
KMS aliases, log groups, `sbsa*` roles all empty; only the two kept Octopus secrets).

**1. `mimic_vpc` on `flows` (free).** Do **not** pass `-var nacl_mode=…`: `flows` is the
default and is the thing under test.

```bash
cd mimic_vpc/terraform
sed -i 's/sbsa-net-sit-2026-10-09/sbsa-net-sit-<DATE>/' environments/sit/primary.tfvars
terraform init      # backend already on besu/sit/network.tfstate
terraform plan -var-file=environments/sit/primary.tfvars -out=$SP/mvpc.plan   # expect 333 to add
terraform apply $SP/mvpc.plan
cd .. && ./scripts/verify-contract.sh && ./scripts/emit-handover.sh            # 27 passed
```

**2. The checker, live — positive (free).** `--control-plane` is the app subnets because the
hostile cluster is built in them (`mimic_eks` `node_subnet_ids`; the cluster's subnets are
the node subnets).

```bash
H=mimic_vpc/network-handover.auto.tfvars
j(){ grep "^$1 " $H | sed 's/^[^=]*= *//' | jq -r '[.[]]|join(",")'; }
RUNNER_SUBNET=$(grep "^ledger_subnet_ids " $H | sed 's/^[^=]*= *//' | jq -r '.["afs1-az1"]')
sbsa_besu/scripts/preflight/verify-subnet-rules.sh --region af-south-1 \
  --node "$(j app_subnet_ids)" --control-plane "$(j app_subnet_ids)" \
  --lb "$(j lb_subnet_ids)" --endpoint "$(j endpoint_subnet_ids)" --data "$(j data_subnet_ids)" \
  --runner "$RUNNER_SUBNET"
```

Expected (computed offline from the same plan): **exit 0, `46 passed, 0 failed, 12
warnings, 4 skipped`**. The warnings are all expected and none is a pass in disguise:
C-1 ×6 and F-7 ×3 *"permitted, but only by a 0.0.0.0/0 rule"* — outbound 443 matches
F-6's S3 rule (150, `0.0.0.0/0` while `s3_cidrs` is empty) before F-7's own rule (180);
F-9 ×3 *incidental*, as on 10-09. Skipped: F-8 (no `--proxy`), F-10, C-4, #33. **Any FAIL
here means the live rules differ from the plan — stop and diff `nacl_rules_authored`
against the checker's output.**

**3. The checker, live — negative (free).** Remove C-1 and watch the checker name it.

```bash
cd mimic_vpc/terraform
terraform plan -var-file=environments/sit/primary.tfvars -var 'nacl_break_flow=C-1' -out=$SP/break.plan
#   expect: 0 to add, 1 to change (nacl_budget), 12 to destroy — every one tcp/443
terraform apply $SP/break.plan
# re-run step 2 → exit 1, `46 passed, 9 failed, 3 warnings, 4 skipped`: C-1 ×6 + F-7 ×3, nothing else
terraform plan -var-file=environments/sit/primary.tfvars -out=$SP/restore.plan   # 12 to add, 1 to change
terraform apply $SP/restore.plan
# re-run step 2 → back to exit 0
```

**4. `shared` — billing starts (≈ $0.45/h).** As in the 10-09 log §2: bump `deletion_group`
in `environments/sit/common.tfvars`, `init` on `besu/sit/shared.tfstate`, plan (27 to add),
apply. The nodes cannot bootstrap without these endpoints.

**5. `mimic_eks` hostile — the reproduction (≈ 25 min).**

```bash
cd mimic_eks/terraform
cp ../../mimic_vpc/network-handover.auto.tfvars .
sed -i 's/mimic-eks-sit-2026-10-09/mimic-eks-sit-<DATE>/' environments/sit/mimic.tfvars
terraform plan -var-file=environments/sit/mimic.tfvars -out=$SP/hostile.plan     # 20 to add, 1.37, 3 × m6i.xlarge
terraform apply $SP/hostile.plan
aws eks update-kubeconfig --name sbsa-besu-sit-shared --region af-south-1 --kubeconfig $SP/kc
KUBECONFIG=$SP/kc kubectl get nodes -o wide
```

**Pass:** the apply completes (no `NodeCreationFailure`), the node group is `ACTIVE`, and
**3 nodes are Ready, one per app subnet**. On 10-09 this was `CREATE_FAILED` with 2.

**6. Was the cross-subnet path actually exercised?** EKS chooses where its control-plane
ENIs go. If every app subnet holds one, every node reached the API inside its own subnet,
where NACLs do not apply — and step 5 proved nothing about C-1.

```bash
aws ec2 describe-network-interfaces --region af-south-1 \
  --filters "Name=description,Values=Amazon EKS sbsa-besu-sit-shared" \
  --query 'NetworkInterfaces[].[SubnetId,PrivateIpAddress]' --output text
```

At least one app subnet with **no** ENI → its node registered across a NACL: **C-1 proven
live**. All three hold one → record **inconclusive for C-1** and do not close B27 on it.

**7. C-3 live, and the optional decisive negative.** For a node in an ENI-less subnet (from
step 6), its `aws-node` pod's logs travel API server → kubelet 10250 across a NACL:

```bash
KUBECONFIG=$SP/kc kubectl -n kube-system get pods -l k8s-app=aws-node -o wide
KUBECONFIG=$SP/kc kubectl -n kube-system logs <aws-node pod on that node> -c aws-node --tail=3   # returns lines = C-3 live
```

*Optional, ≈ 5 min, the strongest evidence available:* make a **fresh** break plan (step
3's is stale — its restore apply changed the state, and Terraform refuses a stale saved
plan) and apply it with the cluster up:

```bash
cd mimic_vpc/terraform
terraform plan -var-file=environments/sit/primary.tfvars -var 'nacl_break_flow=C-1' -out=$SP/break2.plan && terraform apply $SP/break2.plan
KUBECONFIG=$SP/kc kubectl get nodes -w        # ~1 min
terraform plan -var-file=environments/sit/primary.tfvars -out=$SP/restore2.plan && terraform apply $SP/restore2.plan
```

Expect **only** the node(s) in ENI-less subnets to go `NotReady` (kubelet can no longer
reach the API), the others to stay Ready — then all Ready after the restore. That is B27
reproduced and cured on demand, on a live cluster.

**8. Teardown — reverse order, same vars as each apply.**

```bash
cd mimic_eks/terraform && terraform plan -destroy -var-file=environments/sit/mimic.tfvars -out=$SP/hostile-destroy.plan && terraform apply $SP/hostile-destroy.plan

# B34 — EKS leaves things Terraform never owned. LOOK first, delete only what carries the
# cluster's tag and is unattached; then the VPC destroy is ~1 min instead of a 10-min retry.
C=sbsa-besu-sit-shared
aws ec2 describe-network-interfaces --region af-south-1 \
  --filters Name=tag:cluster.k8s.amazonaws.com/name,Values=$C Name=status,Values=available \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,Description,SubnetId]' --output text
#   → aws ec2 delete-network-interface --network-interface-id <each>
aws ec2 describe-security-groups --region af-south-1 --filters Name=tag:aws:eks:cluster-name,Values=$C \
  --query 'SecurityGroups[].[GroupId,GroupName]' --output text
#   → aws ec2 delete-security-group --group-id <each>   (after the ENIs: they reference it)

# shared: as in the 10-09 log teardown
cd mimic_vpc/terraform && terraform plan -destroy -var-file=environments/sit/primary.tfvars -out=$SP/mvpc-destroy.plan && terraform apply $SP/mvpc-destroy.plan
```

`mimic_vpc`'s destroy takes **no** `nacl_mode` var this time — it was applied on the
default. If step 7's break was left applied, the destroy still works (it removes what is
there), but restore first so the destroy plan is the one you expect. Then the 10-09
zero-check by direct describes, both regions.

**9. Record.** The run log; a row in `docs/test-run-log.md`; and in `build-findings.md`
move **B27** to Closed citing steps 5–7 (or leave it open with "inconclusive" if step 6 says
so). **B32** stays open for its runner half until a run with a runner exercises F-7 itself.

### E.3 — Octopus as code, and a release from GitHub (CD-67, CD-68) — steps 1–3 ✅ APPLIED 2026-10-10

All of it lives in `octopus/` (its README has the exact commands); first run:
`docs/deploy-run-2026-10-10-octopus-space.md`. **Advise-only**, and every apply below is
one a person runs.

| Step | Who / where | What | Why |
|---|---|---|---|
| 1 | AWS admin, laptop | `octopus/aws-trust`: plan → apply (5 resources) | the IAM OIDC provider for the instance and a deploy role per environment, trusted **only** for `space:<s>:project:besu-infra:environment:<e>`. Never applied by Octopus |
| 2 | Octopus admin, UI | service account `besu-terraform` in a team with **Space manager** on the space; API key with **read-write** access level (check: `GET /api/users/<id>/apikeys` → `AccessLevel: FullAccess`), stored with `read -rs K && aws secretsmanager create-secret … --secret-string "$K"` | a ReadOnly key plans cleanly and then fails every create |
| 3 | laptop, Space-manager key | `octopus/terraform`: plan → apply (33 objects) → plan again with `-detailed-exitcode`, expecting exit 0 | the environment, lifecycle, runner pool, OIDC account, variable set and the three projects. Don't set an environment `sort_order`: Octopus appends new environments, and provider 1.20.0 taints the resource. If it happens, `untaint` it, don't replace it |
| 4 | Octopus admin, laptop | `octopus/ci-trust`: plan → apply (8 objects), with an **administrator's** key | the `besu-ci` service account, its GitHub OIDC identities and its two roles. The Space-manager key can't create users, and shouldn't be able to change CI's permissions |
| 5 | GitHub UI | Repository **variables**: `OCTOPUS_URL`, `OCTOPUS_SPACE`, `OCTOPUS_SERVICE_ACCOUNT_ID` (the GUID: `GET /api/serviceaccounts/<user id>/oidcidentities/v1?skip=0&take=1` → `ExternalId`) | no secret: nothing to rotate |
| 6 | GitHub Actions | `release` with project **`none`** | proves the checks, the package and the OIDC sign-in without deploying anything |
| 7 | GitHub Actions | `release` with **`besu-infra`** — **billable**: SIT then applies `shared` → `chain` → "runner bundle + config" → `runner`. Only after `push-deploy-config.sh` has filled `<prefix>-sit-octopus-deploy-config`, and with the runner's /32 **reserved** in its subnet (mimic_vpc `pinned_ip_reservations`; in the bank, the R-10 ask). If `terraform: runner` stops at plan on *"pinned IP … is held by eni-…"* (B43), the message carries the two commands that free it; run them, then re-deploy the same release | the first real deployment, and the first proof of OIDC on a hosted worker. ✅ ServerTasks-1518, 2026-10-10 |
| 8 | runner (SSM) | `install-tentacle.sh` with `OCTOPUS_WORKER_POOL=besu-runner-sit` (E.1 step 8) | `besu-workloads` and `besu-validators` run on that pool |
| 9 | GitHub Actions, then Octopus | `release` with `besu-workloads`, then with `besu-validators` (approve the gate in Octopus while the workflow waits) | the smoke path (CD-67), then the manual gate |
| 10 | teardown | as in E.2, plus the B34 sweep. `aws-trust`, the space and `ci-trust` stay | they're configuration, not compute |

**What must NOT be done:** put an Octopus API key in GitHub; widen `ci-trust`'s
`deploy_environments` past SIT; add a `push` trigger to `release.yml` without deciding that
every merge should deploy SIT.

---

## Phase F — Switch to production (af-south-1)

```bash
scripts/preflight/verify-region.sh af-south-1 m6i.xlarge 1.35
aws account enable-region --region-name af-south-1   # takes a few minutes
# then: primary_region + az_ids in the prod tfvars
# and re-request the network hand-over — subnet IDs do not travel either
```

Full procedure: `CLAUDE.md` §10a.

---

## 4. Important points

### Things that are irreversible

| | Why it matters |
|---|---|
| **VPC `instance_tenancy`** | Cannot be changed on an existing VPC. `dedicated` forces every instance onto dedicated tenancy regardless of the launch template: ~USD 1,460/mo in per-region fees, and EKS managed node groups do not support dedicated *host* placement at all. Gate 1. |
| **EKS service CIDR** | Immutable after cluster creation. A collision found later means rebuilding the cluster. Gate 6 tests it with real integer CIDR arithmetic — Terraform has no overlap function. |
| **VPC CIDR blocks** | Cannot be resized after association. Hence asking for a /20 from a reserved /18. |

### Failures that are slow and ambiguous, not clean errors

**There is no Internet Gateway, so misrouted calls hang until timeout rather
than being refused.** This is the defining operational hazard of the design.

| Symptom | Cause |
|---|---|
| Every AWS SDK call hangs; nodes never bootstrap | a VPC DNS attribute is false (#2), or the DHCP option set points only at on-prem DNS (#3) |
| Cluster builds fine; the SWIFT NLB never appears | `kubernetes.io/role/internal-elb=1` missing — fails at **Service-creation time**, days later |
| Generic `ImagePullBackOff`, no useful signal | Three endpoint-policy causes, all silent: the S3 gateway endpoint policy must allow `prod-<region>-starport-layer-bucket/*` (ECR serves manifests, but **layers come from S3**); Private DNS must be on for `ecr.api`/`ecr.dkr`; and the ECR endpoint policy must not be scoped to one account (the addons pull cross-account). All three are caught by `verify-endpoints.sh` (policy-level, before anything is applied) and `verify-images.sh -e <env>` (an actual pull), both run **from the runner** — never from the laptop. |
| Ledger subnets black-hole everything | a NACL was created without explicit allow rules — **an empty NACL denies all traffic** |
| `apply` fails authorizing the S3 endpoint | ~~no permission to associate a gateway endpoint to the route tables (#10)~~ — **CT-5: we associate nothing; #10 is withdrawn.** The S3 *policy* trap remains and is the one that matters: it must admit `prod-af-south-1-starport-layer-bucket/*` (#20), or image pulls stall part-way through a layer |
| Validator pods unschedulable after an app team scales | ledger and applications share a subnet (#11) |

### Design invariants — do not "fix" these

- **The mimic has no egress toggle.** No `enable_egress` variable, deliberately.
  The moment one exists someone flips it during a frustrating debug and the
  platform quietly grows an internet dependency that fails at go-live. If
  something cannot build without egress, that is a platform finding to fix.
- **The platform never reads the mimic's Terraform state.** The hand-over is a
  tfvars file. The real cloud team will not grant state access, so a
  `terraform_remote_state` dependency would work in every deploy-test and fail
  at go-live.
- **`az_ids` is the one input that does not travel between regions.** Gate 7
  catches both a wrong-region AZ ID and a stale hand-over file.
- **NEVER upgrade validators all at once.** QBFT needs 3 of 4 online. H1 makes a
  blanket apply a no-op on validators (`ignore_changes` + `OnDelete`); use
  `scripts/maintenance/rolling-besu-apply.sh`. The PDB does **not** protect
  against this — it gates evictions, not StatefulSet image updates.
- **Never `--force` a node-group update.** It ignores PDBs and can drop a validator.

### Cost

| | |
|---|---|
| Mimic running | **~$0** (flow logs only) — leave it up |
| Phase C gate testing | **$0** |
| Two-cluster deploy-test | **~$2.40/hour** (af-south-1; was ~$1.85 in us-east-1) |
| Interface endpoints alone | ~$0.48/hour — 3% of a $15 cap per hour before a node boots |
| Production steady-state | ~$1,140–1,596/mo chain-only (af-south-1), depending on Q-2 |

**Q-2 is worth ~$400/month.** With centralised endpoints the air-gapped design
is *cheaper* than the current NAT-based one; owning all 15 yourself costs ~50%
more. Lead the next cloud-team conversation with it.

---

## 5. Open questions

| # | Status |
|---|---|
| Q-0 region | ✅ `af-south-1` for **both** environments (2026-09-04). **Opt-in — must be ENABLED on the account first.** Exactly 3 AZs, all consumed. |
| Q-1 RAM-shared | ✅ Assumed **own account**. PrivateLink unconstrained. Confirm with the cloud team — the one answer that would force a redesign. |
| Q-2 central endpoints | ⬜ Worth ~$400/mo. **Ask first.** |
| Q-3 egress model | ⬜ Building for full air-gap regardless. |
| **Q-4a..Q-4e (ECR)** | ⬜ Blocks Phase D image work. Need written confirmation that ECR is the registry, the ECR account topology, any CVE-gating requirement, and who owns the mirror pipeline. See `NETWORK_REQUIREMENTS_CLOUD_TEAM.md` §8.4. |
| ~~Q-5 golden AMI~~ | **Moot under CT-5** — the nodes are the cloud team's. |
| ~~Q-2 central endpoints~~ | **Answered by CT-5** — their cluster already needs every endpoint we do; `shared` creates none in the bank (CD-39). The ~$400/mo is not ours either way. |
| **Q-8..Q-18 (CT-5)** | ⬜ **Blocks the rebuild.** App estate in this cluster? IRSA or Pod Identity? NACLs or SGs? node-SG rule or SGP? PSA level? which add-ons exist? node-rotation policy? IP headroom? LBC policy tag condition? cluster-wide PSA? All answered by the four command outputs in `CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md` §4. Record: `CLOUD_TEAM_REDESIGN_NOTES.md` §12.11; the per-requirement detection table is shared-cluster requirements §6 / §12.13. |

## 6. Quick reference

| Task | Command |
|---|---|
| Look up AZ IDs | `aws ec2 describe-availability-zones --region <r> --query 'AvailabilityZones[].[ZoneName,ZoneId]' --output table` |
| Check region readiness | `sbsa_besu/scripts/preflight/verify-region.sh <region> m6i.xlarge 1.35` |
| Verify the network contract | `mimic_vpc/scripts/verify-contract.sh` |
| Emit the hand-over | `mimic_vpc/scripts/emit-handover.sh` |
| Check region opt-in | `aws account get-region-opt-status --region-name af-south-1` |

# Deploy run — 2026-10-09 — CT-5 gate test (A) + own-cluster regression (B)

> **Live log.** Written step by step during the run: every command that was executed, in
> order, with what came back. Times are UTC. Run by Claude Code on the operator's explicit
> instruction ("A and B both. You run but maintain a log for each steps/commands") — the
> advise-only rule (CLAUDE.md §0.6) was lifted for this run only.

**Source under test:** branch `shared-eks-namespace` @ `7b9b41d`. Nothing committed since
`b9e5b66` (the 2026-09-17 run) had ever been applied.

**What each half proves**

| | Builds | Proves |
|---|---|---|
| **A** — CT-5 gate test | `mimic_vpc` → `shared` → `mimic_eks` (**hostile**, then **strict** with one knob broken) | `mimic_eks` applies at all (first run ever); its own `verify-contract.sh`; that `modules/cluster-contract` (11 plan-time gates), `verify-cluster.sh`, `verify-admission.sh`, `verify-subnet-rules.sh` **fail against the hostile cluster for the reason they name**, and pass against strict |
| **B** — regression | `mimic_vpc` → `mimic_egress` → `shared` → `chain` (own cluster) → `runner` | Nothing broke since 09-17: chart image parameterisation, D-39 required anti-affinity, `verify-deployed.sh`, runner bootstrap |

**Ground rules:** USD 15 cap; same-day teardown; `plan -out` then `apply <file>`; every
destroy uses the same vars as its apply; zero-check by direct describes (B16).

**State layout today**

| Root | Backend | Note |
|---|---|---|
| `mimic_vpc` | S3 `besu/sit/network.tfstate` | **moved** from `besu/network/main.tfstate` (doc drift noted 09-17); old key empty after the 09-17 destroy, so `-reconfigure`, no migration |
| `mimic_egress` | S3 `besu/sit/egress.tfstate` | moved from `besu/network/egress.tfstate`, same reasoning |
| `mimic_eks` | local | by design (`backend.tf`) |
| `shared` / `chain` / `runner` | S3 `besu/sit/{shared,chain,runner}.tfstate` | unchanged |

DeletionGroups for this run: `sbsa-net-sit-2026-10-09`, `sbsa-egress-sit-2026-10-09`,
`mimic-eks-sit-2026-10-09`, `sbsa-sit-2026-10-09`.

---

## 0. Pre-checks (09:52)

```bash
git status --short                      # only the untracked Confluence draft
git rev-parse --short HEAD              # 7b9b41d
aws secretsmanager list-secrets --region af-south-1 --include-planned-deletion \
  --query 'SecretList[].[Name,DeletedDate]' --output text
#   sbsa-besu-primary-octopus-register-key  None
#   sbsa-besu-primary-tentacle-cert         None
aws ec2 describe-vpcs --region af-south-1 --query 'Vpcs[?IsDefault==`false`].VpcId' --output text   # (empty)
aws eks list-clusters --region af-south-1                                                          # (empty)
aws kms list-aliases / aws logs describe-log-groups / aws iam list-roles (sbsa*)                   # all empty
aws iam list-open-id-connect-providers   # only token.actions.githubusercontent.com (CI, not ours to touch)
aws eks describe-cluster-versions --region af-south-1   # 1.37 1.36 1.35 … — hostile's 1.37 is offered
```

Account clean apart from the two deliberately-kept Octopus secrets. Tools on the laptop:
Terraform 1.16.1, kubectl 1.36.3, helm 3.21.3.

---

## 1. `mimic_vpc` (09:53 → 10:00, ~$0)

```bash
cd mimic_vpc/terraform
sed -i 's/sbsa-net-sit-2026-09-09/sbsa-net-sit-2026-10-09/' environments/sit/primary.tfvars
aws s3api head-object --bucket besu-tfstate-867728055761 --key besu/sit/network.tfstate --region us-east-1   # 404 — fresh key
aws s3 cp s3://besu-tfstate-867728055761/besu/network/main.tfstate - | jq '.resources|length'                # 0 — old key empty
terraform init -reconfigure -backend-config="bucket=besu-tfstate-867728055761" \
  -backend-config="key=besu/sit/network.tfstate" -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
terraform plan -var-file=environments/sit/primary.tfvars -out=mimic.plan
terraform show -json mimic.plan | jq -r '.resource_changes[]|select(.change.actions|index("create"))|.type' | sort | uniq -c
terraform apply mimic.plan
cd .. && ./scripts/verify-contract.sh && ./scripts/emit-handover.sh
```

| | Result |
|---|---|
| Plan | **321 to add** (was 65 on 09-17). The difference is **249 `aws_network_acl_rule` + 15 NACLs** — the D-32 restrictive NACL baseline from `0512e7d`, live for the first time. No NAT, no IGW. NACL rules are free |
| Apply | 09:53:57 → 09:58:16, `321 added`. VPC **`vpc-01da3f34fbd0137ff`** |
| `verify-contract.sh` | **27 passed, 0 failed** |
| Hand-over | 3363 bytes, `vpc_id` matches, symlinked into `shared/` and `chain/` |

## 2. `shared` — 15 interface endpoints (10:01 → 10:04; **billing ≈ $0.45/h from here**)

```bash
cd sbsa_besu/terraform
sed -i 's/sbsa-sit-2026-09-17/sbsa-sit-2026-10-09/' environments/sit/common.tfvars
cd shared
terraform init -backend-config="bucket=besu-tfstate-867728055761" -backend-config="key=besu/sit/shared.tfstate" \
  -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
terraform plan -var-file=../environments/sit/common.tfvars -out=shared.plan
terraform apply shared.plan
terraform output billable_endpoint_eni_count
```

Plan `27 to add` (15 `aws_vpc_endpoint`, 8 `terraform_data` gates, SG + 2 rules, PHZ) —
identical to 09-17. Apply 10:01:42 → 10:04:00, `27 added`, **45 ENIs**. The network contract's
8 gates passed against the new restrictive-NACL VPC.

---

# Part A — CT-5 gate test against `mimic_eks`

## A1. `mimic_eks` hostile — first attempt FAILED → finding **B25** (10:05)

```bash
cd mimic_eks/terraform
cp ../../mimic_vpc/network-handover.auto.tfvars .
cat > environments/sit/mimic.tfvars   # environment=sit, deletion_group=mimic-eks-sit-2026-10-09,
                                      # owner/cost_center as mimic_vpc, region=af-south-1, runner_role_arn=""
terraform init
terraform plan -var-file=environments/sit/mimic.tfvars -out=hostile.plan     # 20 to add: 1.37, public+private, 3 × m6i.xlarge in app subnets
terraform apply hostile.plan
```

**Failed after 18 s:** `CreateSecurityGroup … InvalidVpcID.NotFound: The vpc ID 'vpc-01da3f34fbd0137ff' does not exist`.

**B25 — `mimic_eks` had no `provider "aws"` block.** The provider fell back to the laptop
profile's default region (`aws configure get region` → `us-east-1`), so the IAM roles, KMS key,
log group and launch template were created **in us-east-1**, and the first VPC-scoped resource
failed. The `region_agreement` gate passed throughout: it compared `var.region` with
`var.network_region` — two variables, both correctly `af-south-1` — and never asked the provider.
Same shape as B19–B24: a gate that checks what it was told rather than what is real.

Clean-up with the **unfixed** config first (fixing the region first would have orphaned the
strays — Terraform would look for them in af-south-1 and drop them from state):

```bash
terraform plan -destroy -var-file=environments/sit/mimic.tfvars -out=destroy-useast1.plan   # 13 to destroy
terraform apply destroy-useast1.plan
terraform state list | wc -l                                                                   # 0
aws kms describe-key --region us-east-1 --key-id alias/sbsa-besu-sit-eks-secrets               # NotFound (key → PendingDeletion)
aws iam list-roles --query 'Roles[?starts_with(RoleName,`sbsa-besu-sit-eks`)]'                 # empty
```

Fix (`mimic_eks/terraform/versions.tf`, `main.tf`): a `provider "aws" { region = var.region; default_tags { tags = local.tags } }`
block matching the two sibling mimics, plus a `region_agreement` precondition on
`data.aws_region.current.name == var.region` so the gate now reads the provider's real region.
`terraform fmt -check` + `validate` clean. Re-plan: `20 to add`, provider region → `var.region`.

**Side finding B26 — WITHDRAWN (same day, on review).** I first logged "`*.plan` files are
tracked in git and may carry secrets". Tracking them is a **recorded decision** (`c0717ec`,
2026-09-18: the saved plans are the evidence of what each run intended; the one plan carrying the
CA key, `chain/chain-destroy.plan`, is ignored by name, and `.gitignore` records the check). The
check, run on all nine tracked plans with GNU grep (control string = 1): **`PRIVATE KEY` = 0 in
every one**; in `chain.plan` all six `random_password` results and `tls_private_key.ca` are
`after_unknown = true` — a create plan records that a secret *will* be generated, not its value.
Nothing to fix. Lesson: the first pass used the harness's `grep`, which skips binary input and
printed nothing — read as a pass it would have been a false negative; read as a finding it was a
false positive. Today's own plans went to the scratchpad and were not committed.

## A2. `verify-subnet-rules.sh` (#34, D-29) — positive and NEGATIVE, against live NACLs (10:08 → 10:14, free)

Our pods' subnets under CT-5 are mimic_vpc's **app** subnets (where `mimic_eks` puts its node group).

```bash
H=mimic_vpc/network-handover.auto.tfvars; j(){ grep "^$1 " $H | sed 's/^[^=]*= *//' | jq -r '[.[]]|join(",")'; }
sbsa_besu/scripts/preflight/verify-subnet-rules.sh --region af-south-1 \
  --node "$(j app_subnet_ids)" --lb "$(j lb_subnet_ids)" --endpoint "$(j endpoint_subnet_ids)" \
  --data "$(j data_subnet_ids)" --runner subnet-03a3f13ad39310b83
```

**Positive: `28 passed, 0 failed, 3 warnings, 3 skipped`, exit 0.** Warnings: F-9 (5432 pods→data)
"permitted INCIDENTALLY" ×3 — allowed by a broader rule, not a dedicated one; correct to flag.
Skips: F-8 (no `--proxy`), F-10 (not evaluable from rules), #33 (no `--node-sg`) — each says why.

**Negative — drop one flow on purpose and prove the checker sees it:**

```bash
cd mimic_vpc/terraform
terraform plan -var-file=environments/sit/primary.tfvars -var 'nacl_break_flow=F-1 peer UDP' -out=break.plan
#   0 add, 1 change (nacl_budget), 36 destroy — confirmed every destroy is protocol 17 / port 30303
terraform apply break.plan
# re-run the checker (same args, no --runner)
```

**Got: `21 passed, 6 failed`, exit 1** — exactly the six `#34 F-1 BLOCKED: 10.60.x.0/23 -> 10.60.y.0/23 [udp] (udp/30303)`
pairs between the three app subnets, **TCP F-1 still passing**. That is the dangerous case
(static peers connect, discovery dead, chain looks fine) and the checker names it by flow,
protocol and port. ✅

Restore: `terraform plan … -out=restore.plan` (`36 add, 1 change`) → apply → checker
`27 passed, 0 failed` (one fewer than above only because `--runner` was not passed).

## A3. `mimic_eks` hostile — second attempt (10:08 → 10:50): cluster ACTIVE, node group **CREATE_FAILED** → finding **B27**

```bash
terraform plan -var-file=environments/sit/mimic.tfvars -out=hostile.plan     # 20 to add
terraform apply hostile.plan                                                    # run in background
```

Cluster `sbsa-besu-sit-shared` 1.37 ACTIVE after ~10 min; then **`NodeCreationFailure: Instances
failed to join the kubernetes cluster`** on `i-069295f39a652f0ed` after the node-group wait timed out.

Diagnosis:

```bash
aws ec2 get-console-output --instance-id i-069295f39a652f0ed --latest   # nodeadm "done!", kubelet running — bootstrap + endpoints FINE
aws eks update-kubeconfig --name sbsa-besu-sit-shared --kubeconfig $SP/kc-mimic   # public endpoint (hostile) → laptop can reach it
kubectl get nodes -o wide
#   ip-10-60-5-110 (az1)  Ready
#   ip-10-60-7-174 (az2)  Ready
#   — the az3 node (10.60.9.65) never registered
aws ec2 describe-network-interfaces --filters "Name=description,Values=Amazon EKS sbsa-besu-sit-shared"
#   control-plane ENIs: 10.60.5.89 (app az1), 10.60.6.54 (app az2) — NONE in az3
aws ec2 describe-network-acls --filters Name=association.subnet-id,Values=<app az3>
#   egress 180 allows tcp/443 → 10.60.0.0/20, but INGRESS has no 443 rule at all
```

**B27 — the D-32 restrictive NACLs model OUR flows (#34 F-1..F-10) and none of the CLUSTER's own.**
EKS puts its control-plane ENIs in the cluster's subnets (here the app subnets, two of three
AZs). A node reaching an ENI in **another** app subnet crosses that subnet's NACL, whose ingress
has no 443 → the az3 node can never register; az1/az2 nodes work only because each has an ENI in
its own subnet (intra-subnet traffic is not NACL-evaluated). Same class, not yet observed: pods →
CoreDNS on 53 across AZs (both CoreDNS replicas landed on the az1 node), webhooks → pods.
`verify-subnet-rules.sh` passed 28/28 against these NACLs **because the flows it checks are the
ones we listed** — the omission is in the flow table, so no checker built from it can see it.
Consequences:
1. **mimic_vpc** `nacl_mode=flows` cannot host any EKS cluster across 3 AZs as it stands. The fix
   adds cluster flows (C-1 node→API 443 between node subnets, C-2 DNS 53 tcp/udp between node
   subnets, C-3 control plane→kubelet 10250 — already covered by the ephemeral-range rule); that
   pushes each app/ledger NACL past the **20-rule default** (ingress is at 18 today) — the same
   quota finding #34 already records, now with a cluster-side cause.
2. **The cloud-team requirements (point 8)** list only our flows. They implicitly assume the
   cluster's own flows already work in the subnets they choose — true for a real cluster they run,
   but it should be stated so a tenant-specific NACL change cannot remove them.

**Decision for today:** the hostile cluster has 2 Ready nodes — enough for every gate test,
which reads the AWS and Kubernetes APIs, not workloads — so Part A continues on it. Before the
strict run and Part B, `mimic_vpc` goes to `nacl_mode=permissive` (the 09-17 baseline); the
flow-table fix is recorded as an open item, not done mid-run.

## A4. The mimic is what it claims (10:52)

```bash
export KUBECONFIG=$SP/kc-mimic
cd mimic_eks && ./scripts/verify-contract.sh      # 5 passed, 0 failed, 6 by design
./scripts/apply-tenancy.sh                        # 2 ns at restricted, ledger-quota cpu 6 / mem 18Gi, sc gp3-immediate (Immediate, no expansion)
./scripts/emit-handover.sh                        # → sbsa_besu/terraform/eks-handover.auto.tfvars, defect list in the header
```

Two weaknesses in `verify-contract.sh` itself (minor, noted not fixed): it reports
`nodes=3` from the node group's **desired** size and does not notice the group is
`CREATE_FAILED` with 2 joined; and it labels the AWS service-linked role
`AWSServiceRoleForAmazonEKS`'s cluster-scoped policies as a "BY DESIGN" #32 defect — noise.

## A5. `modules/cluster-contract` against the live hostile cluster (10:55 → 11:10)

No platform root loads `contract/eks-handover.tf` until CT-5 cutover (its header; `emit-handover.sh`
says "pass these to modules/cluster-contract directly"), so a throwaway harness root in the
session scratchpad does exactly that: `eks-handover.tf` **symlinked** from `sbsa_besu/terraform/contract/`,
an `aws` provider in af-south-1, one `module "cluster"` passing every hand-over variable plus
`deploy_region`, `node_role_ecr_auth_confirmed`, `irsa_role_names`.

```bash
cd $SP/cc-harness && cp sbsa_besu/terraform/eks-handover.auto.tfvars .
terraform init && terraform plan -var node_role_ecr_auth_confirmed=true
```

**First run — 7 gates refused, one of them wrongly → finding B28.**
`#31 VIOLATED: the hand-over's OIDC issuer 'oidc.eks.af-south-1…/id/0D55…' is not this cluster's
issuer ('https://oidc.eks.af-south-1…/id/0D55…'). The IAM OIDC provider belongs to a DIFFERENT cluster`.
It is the same cluster. **B28:** CG-4 trimmed only a trailing `/`; EKS reports the issuer with
`https://`, IRSA trust conditions (and so the mimic's hand-over) use the bare form, and the cloud
team may paste either. Fixed in `modules/cluster-contract/main.tf` (CG-4 compares with
`trimprefix(…, "https://")` on both sides). Proven both ways: correct issuer → passes; hand-over
issuer changed to `…/id/DEADBEEF…` → refused with the same message.

**Hostile, after the fix — 6 gates refuse, each naming its requirement:**

| Gate | Message (first line) |
|---|---|
| CG-2 | `#32 VIOLATED: the cluster's API endpoint is PUBLIC.` |
| CG-3 | `#36 VIOLATED: the cluster runs Kubernetes 1.37, ABOVE the newest minor we have validated (1.36)` |
| CG-7 | `#30 VIOLATED: the cluster does not provide the AWS Load Balancer Controller.` |
| CG-8 | `#27 VIOLATED: psa_level is 'restricted' and the F32 ownership-fix init container still runs as uid 0` |
| CG-9 | `ISOLATION FLOOR VIOLATED (#28 and #35 both absent)` |
| CG-10 | `#32: runner_access_entry_created is false.` (no runner in Part A — expected) |

**The gates whose hostile input is clean, each driven to failure by editing ONE hand-over value:**

| Edit | Gate | Got |
|---|---|---|
| `cluster_version = "1.36"` | CG-1 | `STALE HAND-OVER: eks-handover declares Kubernetes 1.36, the live cluster is 1.37` |
| `cluster_region = "eu-west-1"` | CG-0 | `REGION MISMATCH: this root deploys into 'af-south-1' but the cluster…` (fires despite the cluster lookup — the CG-0 split works) |
| `pod_identity = true` (OIDC still set) | CG-0 | `#31 VIOLATED: the hand-over declares pod_identity = true and also supplies…` |
| swap the az1/az2 subnet IDs | CG-11 | `Hand-over mismatch: cluster_node_subnet_ids is keyed by AZ ID, but at least one subnet is not in the AZ its key names` |
| `node_role_arn = ""` | CG-6 | `#38: node_role_arn is empty.` |
| `-var node_role_ecr_auth_confirmed=false` | CG-6 | `#38, second half: node_role_ecr_auth_confirmed is false.` |

`gates_skipped` printed both honest skips: `#31 IRSA trust-policy scoping — no irsa_role_names
supplied` and `#38 ECR repository policies — not checkable at plan time`.

**CG-5 (IRSA scoping) — needs real roles, so three throwaway IAM roles trusting this cluster's OIDC provider:**

```bash
aws iam create-role --role-name cc-test-good    # aud + sub = system:serviceaccount:besu-ledger:quorum-node-secrets-sa
aws iam create-role --role-name cc-test-nosub   # aud only
aws iam create-role --role-name cc-test-wrongns # aud + sub in kube-system
terraform plan … -var 'irsa_role_names=["cc-test-good"]'                     # no CG-5 failure (6 baseline)
terraform plan … -var 'irsa_role_names=["cc-test-good","cc-test-nosub"]'     # #31 VIOLATED: IRSA role(s) ["cc-test-nosub"] have NO `:sub` condition
terraform plan … -var 'irsa_role_names=["cc-test-good","cc-test-wrongns"]'   # #31 VIOLATED: … permits service accounts OUTSIDE our namespaces
aws iam delete-role --role-name cc-test-{good,nosub,wrongns}                 # deleted
```

**All 12 `terraform_data` gate blocks have now been seen to refuse against a live cluster.** ✅

## A6. Runner preflights against the hostile cluster (11:10 → 11:25)

Run from the laptop as `tfuser` (the hostile endpoint is public, and `tfuser` is
cluster-admin by creator bootstrap). Caveat recorded: the hostile `grant_custom_resource_rbac=false`
knob is about the **runner's** role, so the `may create <custom kind>` PASS lines below say
nothing about it — that needs a run as the runner identity.

```bash
sbsa_besu/scripts/preflight/verify-cluster.sh -n besu-ledger -a besu-app -s gp3-immediate
```

**`16 passed, 16 failed, 3 warnings`, exit 1** — every hostile defect it owns:
#36 ceiling; #30 `targetgroupbindings` CRD ABSENT (no fallback) + 3 WARN fallbacks
(SecretProviderClass, PodMonitor, PrometheusRule); #30 `Immediate`; #30 no expansion; #27
`restricted` on both namespaces; #27 quota `requests.cpu` 6000m < 8000m, `requests.memory`
18 < 24 GiB, and the two `limits.*`; #32 five NEGATIVE probes all ALLOWED (create pods in
kube-system, delete nodes, create clusterrolebindings, list secrets all-ns, create namespaces);
#35 VPC CNI network policy off.

```bash
helm template validator-0 sbsa_besu/helm/charts/besu-node -n besu-ledger -f sbsa_besu/helm/values/besu-validator.yaml \
  --set fullnameOverride=validator-0 --set role=validator --set nodeSecretName=validator-0-keys \
  --set besuImage=<acct>.dkr.ecr.af-south-1.amazonaws.com/mirror/hyperledger/besu@sha256:000… \
  --set toolsImage=<acct>.dkr.ecr.af-south-1.amazonaws.com/mirror/alpine/k8s@sha256:000… \
  --set storage.storageClassName=gp3-immediate --set storage.size=20Gi > $SP/validator-rendered.yaml
#   PDB, SecretProviderClass, Service, StatefulSet; required podAntiAffinity (D-39) present; F32 init runAsUser: 0
sbsa_besu/scripts/preflight/verify-admission.sh -n besu-ledger -f $SP/validator-rendered.yaml
```

**First run: exit 1, but both diagnoses were wrong or incomplete → finding B29.**
1. *As rendered:* refused for PSA (warning) **and** `resource mapping not found … ensure CRDs are
   installed first` (SecretProviderClass, #30) — the hint named only #27, because `classify` was a
   `case` (first match only) and its #30 pattern did not include kubectl apply's wording.
2. *Bare Pod:* refused with `error looking up service account besu-ledger/quorum-node-secrets-sa`
   — the SA does not exist before the first apply, the **ServiceAccount admission plugin runs
   before Pod Security**, and the catch-all `*[Ff]orbidden*` attributed it to **#32 RBAC**. So the
   probe that exists to obtain the PSA verdict (D-40) never reached PSA, and blamed the cloud team
   for a grant problem that does not exist.

After fixing the SA, a third layer surfaced: `spec.containers[0].volumeMounts[0].name: Not found: "data"`
— a StatefulSet's `volumeClaimTemplates` only become volumes when the controller makes the Pod.

Fixes in `scripts/preflight/verify-admission.sh`: `classify` names **every** matching cause; #30
matches `resource mapping not found` / `ensure CRDs are installed`; #32 only on a real RBAC
denial (`forbidden: User … cannot …`); a missing SA is reported as "not a cluster finding"; an
unmatched refusal says "unclassified" instead of guessing; the bare-Pod probe runs as `default`
with no token, and stands in an `emptyDir` for each claim template (allowed at every PSA level,
so it cannot change the verdict).

**After the fix: exit 1, `0 passed, 2 failed`:** as-rendered → `#27` **and** `#30`; bare Pod →
`pods "validator-0-admission-probe" is forbidden: violates PodSecurity "restricted:latest": unrestricted
capabilities (container "build-config" must not include "CHOWN", "DAC_OVERRIDE", "FOWNER"…)` → `#27`.
That is the hard-enforcement verdict D-40 asks for. ✅

## A7. Hostile down; NACLs to permissive; strict up (11:00 → )

```bash
cd mimic_eks/terraform
terraform plan -destroy -var-file=environments/sit/mimic.tfvars -out=hostile-destroy.plan   # 17 to destroy
terraform apply hostile-destroy.plan                                                         # 11:00 → 11:11, state empty, no cluster/instances left
```

Strict needs a **new** cluster anyway — EKS cannot downgrade 1.37 → 1.36.

```bash
cd mimic_vpc/terraform
terraform plan -var-file=environments/sit/primary.tfvars -var nacl_mode=permissive -out=permissive.plan
#   30 add / 15 change / 250 destroy — aws_network_acl_rule + aws_network_acl + the nacl_budget terraform_data only
terraform apply permissive.plan                                                              # 11:10 → 11:11
```

**Every later `mimic_vpc` command today must carry `-var nacl_mode=permissive`**, including its
destroy, or a plain plan would put the flow rules back.

```bash
cd mimic_eks/terraform
terraform plan -var-file=environments/sit/mimic.tfvars -var profile=strict -var endpoint_public_access=true -out=strict.plan
#   22 to add: cluster 1.36 + 4-node general group + 4-node tainted `dedicated=besu-ledger:NoSchedule` group,
#   all in the LEDGER subnets (#28 granted), + the #33 node-SG rule
terraform apply strict.plan
```

**One knob broken on purpose:** `endpoint_public_access=true`, so the laptop can run the
Kubernetes-side checks (no runner in Part A). Expected: **CG-2 is the only cluster gate that
fires**, plus CG-10 because no runner role exists yet.

**Not run in parallel with Part B, on purpose:** B's runner takes the pinned IP `10.60.0.250` in
ledger az1, and 8 strict nodes' VPC-CNI warm pools in the same subnets could allocate it first.

# Part B — own-cluster regression (prep while strict builds)

```bash
cd sbsa_besu/terraform/chain
terraform init -backend-config="bucket=besu-tfstate-867728055761" -backend-config="key=besu/sit/chain.tfstate" \
  -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
terraform plan -var-file=../environments/sit/common.tfvars -var-file=../environments/sit/chain.tfvars \
  -var worker_node_count=4 -var worker_node_min=4 -var kms_deletion_window_days=7 -var secret_recovery_window_days=0 \
  -out=$SP/chain.plan             # plan written to the scratchpad
terraform show -json $SP/chain.plan | jq …   # review by type
```

`Plan: 106 to add` — identical to 09-17. EKS 1.35 `public=false private=true`; node group
`4/4/10 × m6i.xlarge`; 23 secrets all `recovery_window_in_days = 0`; 2 KMS keys `[7,7]`; the
RPC NLB `deletion_protection=false` (the only such flag); **zero** NAT / IGW / VPC / subnet /
route / `helm_release` / `kubernetes_*`.

## A8. Strict — the positive control (11:12 → 11:37)

Strict applied 11:12:33 → 11:24:02, `22 added`. **All 8 nodes Ready** (4 general + 4
`workload=besu-ledger` tainted) across the three ledger subnets — with permissive NACLs every
node joined, which confirms B27's diagnosis.

```bash
export KUBECONFIG=$SP/kc-mimic     # re-pointed: aws eks update-kubeconfig … (new cluster, same name)
cd mimic_eks && ./scripts/verify-contract.sh && ./scripts/apply-tenancy.sh && ./scripts/emit-handover.sh
cd $SP/cc-harness && cp sbsa_besu/terraform/eks-handover.auto.tfvars . && terraform plan -var node_role_ecr_auth_confirmed=true
sbsa_besu/scripts/preflight/verify-cluster.sh -n besu-ledger -a besu-app -s gp3-wffc
sbsa_besu/scripts/preflight/verify-admission.sh -n besu-ledger -f $SP/validator-rendered.yaml   # storageClassName → gp3-wffc
```

| Check | Strict result | Reading |
|---|---|---|
| `verify-contract.sh` | 7 passed, 3 failed | `public endpoint ON` = my override ✓. The two "cluster-scoped grant in the strict profile" FAILs are the AWS service-linked role and `tfuser` (creator) — **not** the runner. In strict that is a false FAIL: the check should look only at `runner_role_arn`'s entry (**B30**, mimic) |
| `cluster-contract` | **exactly CG-2 + CG-10** | as predicted: the one broken knob, and no runner role. The other ten gate blocks PASS against a compliant cluster ✅ |
| `verify-cluster.sh` | 25 passed, 7 failed, 3 warn | see below |
| `verify-admission.sh` | PSA **passed** (baseline); bare Pod refused by **the quota** | see P-1 |

**`verify-cluster.sh` on strict, failure by failure:**

- `#30 CRD targetgroupbindings ABSENT` + 3 WARN — the strict hand-over **says**
  `cluster_provides_lbc = true` etc., but `mimic_eks` installs no add-on at all (no Helm/CRDs in
  the project). The check caught a hand-over that disagrees with the live cluster — correct
  behaviour; the gap is mimic fidelity (**B30**: strict should install at least the four CRDs).
- `#32` five negative probes ALLOWED — expected, run as `tfuser` (cluster-admin), not as the runner.
- **`#35 the VPC CNI does not have network policy enabled` — FALSE FAIL → finding B31.** The add-on
  is `v1.22.4-eksbuild.3` with `configurationValues {"enableNetworkPolicy":"true"}`; the switch is
  the **`aws-eks-nodeagent` container's argument `--enable-network-policy=true`**, while `aws-node`'s
  env carries only `NETWORK_POLICY_ENFORCING_MODE=standard` (present whether on or off). The check
  read only the env. Fixed in `verify-cluster.sh` (accept the env form OR the node-agent arg; an
  explicit `=false` still fails). Re-run: `aws-eks-nodeagent: --enable-network-policy=true` →
  **PASS**, `26 passed, 6 failed`. **The cloud-team document's point 22 command 2 has the same blind
  spot** — it greps `aws-node`'s env; it should also print the node agent's args.

**P-1 — a real PLATFORM defect, found only because the namespace had a quota.**

```
pods "validator-0-admission-probe" is forbidden: failed quota: ledger-quota: must specify limits.cpu for: besu,build-config,wait-peer-dns
```

The mimic's quota sets `limits.cpu`; our chart sets no CPU limit (`values.yaml`
`resources.limits` is memory only) and the two **init containers declare no resources at all**.
To separate the two causes, the mimic quota was replaced by the **exact shape we ask for in
point 2** (requests.cpu 8, requests.memory 24Gi, limits.memory 48Gi, pods 40, PVC 12, storage 300Gi):

```bash
kubectl -n besu-ledger apply -f - <<'Q' … Q
verify-admission.sh …
#   failed quota: ledger-quota: must specify limits.memory for: build-config,wait-peer-dns;
#   requests.cpu for: build-config,wait-peer-dns; …
```

**So under the very quota we request, every validator pod is refused.** It never showed on our
own cluster (no quota). Fixed in `helm/charts/besu-node`: a new `initResources` value
(`requests 50m / 64Mi, limits memory 256Mi`, deliberately no CPU limit) applied to both init
containers. `helm lint` clean; re-rendered; **bare Pod now PASSES admission** under the point-2
quota + `baseline` — the only remaining refusal is the absent SecretProviderClass CRD (B30). ✅

Two follow-ons: (1) point 2 now says "no `limits.cpu` in the quota" (edited the same day);
(2) not done — the same audit for the
other charts' init containers (`besu-blockscout` backend/stats have them).

`verify-admission.sh` also gained the `failed quota` / `must specify limits.X` pattern
(it said "unclassified" on the first strict run).

Strict destroyed 11:31:57 → 11:37:28, `22 destroyed`, state empty (`terraform plan -destroy … -var profile=strict -var endpoint_public_access=true`).

## B1. `mimic_egress` (10:13 → 10:18, ≈ $0.03/h) — applied early, during A3

```bash
aws s3 cp s3://besu-tfstate-867728055761/besu/network/egress.tfstate - | jq '.resources|length'   # 0 — old key empty
cp mimic_vpc/network-handover.auto.tfvars mimic_egress/terraform/                                   # vpc_id = vpc-01da3f34fbd0137ff
sed -i 's/sbsa-egress-sit-2026-09-17/sbsa-egress-sit-2026-10-09/' mimic_egress/terraform/environments/sit/primary.tfvars
cd mimic_egress/terraform
terraform init -reconfigure -backend-config="bucket=besu-tfstate-867728055761" -backend-config="key=besu/sit/egress.tfstate" \
  -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
terraform plan -var-file=environments/sit/primary.tfvars -out=egress.plan
#   29 to add — 3 × ledger_to_egress 10.61.0.0/24 (3 ledger tables), ONE 0.0.0.0/0 (default_to_igw, egress VPC),
#   peering → vpc-01da3f34fbd0137ff, proxy t3.micro — matches the 09-17 checklist
terraform apply egress.plan                                     # 10:13:38 → 10:17:01, 29 added
# wait for the Squid target: initial → healthy at 10:18:07
cd .. && ./scripts/emit-handover.sh                             # proxy.egress.mimic.internal:3128, egress_allowed_source 10.60.0.250/32, linked → runner/
```

## B2. `chain` — AWS layer (11:32 → 11:49, ≈ $1.1–1.4/h)

```bash
terraform apply $SP/chain.plan        # the plan reviewed in "Part B — prep"
terraform output -raw name_prefix     # sbsa-besu-primary
aws eks describe-cluster --name sbsa-besu-primary-eks --query 'cluster.[status,version,…endpointPublicAccess,…endpointPrivateAccess]'
#   ACTIVE 1.35 False True ; node group ACTIVE, desired 4
```

`106 added`, 11:32:17 → 11:48:52, no error — the restrictive-NACL problem (B27) did not arise
because `mimic_vpc` was already permissive.

## B3. Runner bundle + deploy config (11:38 → 11:43, while the chain finished)

```bash
AWS_REGION=af-south-1 scripts/runner/push-runner-bundle.sh sbsa-besu-primary-runner-artifacts
#   5 × "digest verified"; tools.tar.gz 294M; source.tar.gz 892K = shared-eks-namespace@7b9b41d
#   (WARN: working tree dirty — today's fixes are NOT in the bundle; nothing in B depends on them)
AWS_REGION=af-south-1 ENV=sit scripts/runner/push-deploy-config.sh
#   bundling 4 file(s): common.tfvars chain.tfvars network-handover egress-handover → secret sbsa-besu-primary-runner-deploy-config
```

## B4. `runner` (11:49 → 11:50)

```bash
aws ec2 describe-network-interfaces --filters Name=addresses.private-ip-address,Values=10.60.0.250   # (none) — pinned IP free
cd terraform/runner
terraform init -backend-config="bucket=besu-tfstate-867728055761" -backend-config="key=besu/sit/runner.tfstate" \
  -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
terraform plan -var region=af-south-1 -var chain_state_bucket=besu-tfstate-867728055761 \
  -var chain_state_key=besu/sit/chain.tfstate -var chain_state_region=us-east-1 -out=$SP/runner.plan
#   11 to add; ip 10.60.0.250, subnet-03a3f13ad39310b83 (ledger az1), public=false, IMDSv2 required, t3.small
terraform apply $SP/runner.plan       # 11:49:52 → 11:50:27, 11 added → i-0c2f73922bd85d754
```

## B5. Runner proofs (11:50 → 11:55)

```bash
# bootstrap — SSM send-command, then get-command-invocation
cloud-init status; cat /opt/besu-deploy/BOOTSTRAP_STATUS
#   status: done   OK: tools=5 source=7b9b41d deploy-config: extracted       (first poll, 11:50:59)

cd mimic_egress && ./scripts/verify-egress.sh --runner i-0c2f73922bd85d754
#   baseline fingerprint 9B:A5:3F:…:F3:78 (same as 09-17)
#   PASS 1 resolves 10.61.0.58 · 2 CONNECT instance 200 · 3 CONNECT polling · 4 example.com 403
#   PASS 5 plain HTTP 403 · 6 :10943 403 · 7 no TLS interception · 8 other source 403
#   ALL PROBES PASSED

# on the runner, over SSM (tools are at /usr/local/besu-tools/bin, via /etc/profile.d)
aws eks update-kubeconfig --name sbsa-besu-primary-eks --region af-south-1 --kubeconfig /tmp/kc
kubectl get nodes -o wide          # 4 × Ready, v1.35.8-eks, 10.60.0/1/2.x (ledger subnets)
kubectl -n kube-system get pods    # aws-node ×4, coredns ×2, ebs-csi-controller ×2, ebs-csi-node ×4, kube-proxy ×4 — all Running
```

**Regression verdict: the 09-17 baseline holds on `7b9b41d`** — chain AWS layer, D-21 bundle
bootstrap, CD-56..CD-60 egress, runner → private endpoint via its access entry.

**What B could NOT cover, said plainly:** ECR in af-south-1 holds **no repositories** in this
account, so nothing in-cluster could be installed — no validators, therefore no live proof of
D-39's required anti-affinity, no `verify-deployed.sh`, no `verify-pull-canary.sh`. That needs the
mirror pipeline run first (`scripts/supply-chain/`) and a `deploy_in_cluster_resources=true` apply
from the runner. The Octopus Tentacle registration (E.1 steps 8–10) was also **not** repeated — it
writes to the external Octopus Cloud instance and was not part of today's ask.

---

# Teardown

Reverse order of creation. Every destroy used the same vars as its apply (`mimic_vpc` with
`-var nacl_mode=permissive`); every destroy plan written to the session scratchpad, not the repo.

```bash
cd sbsa_besu/terraform/runner && terraform plan -destroy -var region=af-south-1 -var chain_state_bucket=… -var chain_state_key=besu/sit/chain.tfstate -var chain_state_region=us-east-1 -out=$SP/runner-destroy.plan && terraform apply $SP/runner-destroy.plan
cd ../chain  && terraform plan -destroy -var-file=../environments/sit/common.tfvars -var-file=../environments/sit/chain.tfvars \
                -var worker_node_count=4 -var worker_node_min=4 -var kms_deletion_window_days=7 -var secret_recovery_window_days=0 -out=$SP/chain-destroy.plan && terraform apply $SP/chain-destroy.plan
aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=vpc-01da3f34fbd0137ff     # 45 × vpc_endpoint only — no leaks
cd ../shared && terraform plan -destroy -var-file=../environments/sit/common.tfvars -out=$SP/shared-destroy.plan && terraform apply $SP/shared-destroy.plan
aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<egress vpc>              # proxy ENI + NLB ENI only; ledger VPC: 0
cd mimic_egress/terraform && terraform plan -destroy -var-file=environments/sit/primary.tfvars -out=$SP/egress-destroy.plan && terraform apply $SP/egress-destroy.plan
cd mimic_vpc/terraform && terraform plan -destroy -var-file=environments/sit/primary.tfvars -var nacl_mode=permissive -out=$SP/mvpc-destroy.plan && terraform apply $SP/mvpc-destroy.plan
```

| Root | Destroyed (UTC) | Count |
|---|---|---|
| `mimic_eks` us-east-1 strays (B25) | 10:07 | 13 |
| `mimic_eks` hostile | 11:00 → 11:11 | 17 |
| `mimic_eks` strict | 11:31 → 11:37 | 22 |
| `runner` | 11:53 → 11:54 | 11 |
| `chain` | 11:55 → 12:00 | 106 |
| `shared` | 12:01 → 12:06 | 27 |
| `mimic_egress` | 12:06 → 12:09 | 29 |
| `mimic_vpc` | 12:10 → 12:11 | 101 (permissive NACLs) |

**Zero-check (12:12), direct describes, both regions:** VPCs, EKS, LBs, endpoints, peering, ENIs,
volumes, instances, hosted zones, log groups, `sbsa-*` buckets, trails, launch templates, `sbsa*`/`cc-test*`
IAM roles, local IAM policies — **all empty**; per-DeletionGroup volume/instance sweeps empty for all
four groups. Remaining, all expected: the two kept `sbsa-besu-primary-*` secrets; the default VPC's
IGW; the GitHub CI OIDC provider; KMS af-south-1 = 4 customer keys `PendingDeletion` (chain ×2,
mimic_eks secrets key ×2) + 2 AWS-managed; us-east-1 = the one B25 stray key `PendingDeletion`.
No log group or launch template left in us-east-1.

Housekeeping: the stale `eks-handover.auto.tfvars` (strict) deleted from `sbsa_besu/terraform/`;
the three tracked plan files this run overwrote (`mimic.plan`, `egress.plan`, `shared.plan`)
restored to HEAD, and the untracked plan files it created deleted.

**Spend (estimate):** `shared` 10:01→12:06 (2.1 h × $0.45) ≈ $0.94; `mimic_eks` hostile ~1.05 h ×
(cp $0.10 + 3 × m6i.xlarge) ≈ $0.90; strict ~0.4 h × (cp + 8 nodes) ≈ $0.88; `chain` 11:32→12:00
≈ $0.60; runner + egress ≈ $0.10 → **≈ $3.4**, inside the $15 cap.

---

# Findings

| # | Where | One line | Status |
|---|---|---|---|
| **P-1** | `helm/charts/besu-node` | Init containers `wait-peer-dns` / `build-config` declared **no resources**; under the quota we ask for (point 2) **every validator pod is refused** at admission. Invisible on our own cluster (no quota) | **FIXED** — `initResources` (50m / 64Mi, limit 256Mi memory); bare Pod now admitted under the point-2 quota |
| **B25** | `mimic_eks/terraform` | No `provider "aws"` block → applied into the profile's default region (us-east-1); `region_agreement` compared two variables and passed | **FIXED** — provider block + a precondition on the provider's real region |
| ~~B26~~ | repo `.gitignore` | ~~`*.plan` tracked, may carry secrets~~ — **withdrawn**: tracking is the `c0717ec` decision; all 9 tracked plans pass its `PRIVATE KEY` check and hold no secret values | WITHDRAWN |
| **B27** | `mimic_vpc` NACLs (D-32) | Restrictive `flows` mode models only OUR flows; the cluster's own (node → API 443 between node subnets, pods → CoreDNS 53) are missing, so a node in an AZ without a control-plane ENI never joins | **OPEN** — add cluster flows (blows the 20-rule NACL default); worked around today with `nacl_mode=permissive` |
| **B28** | `modules/cluster-contract` CG-4 | OIDC issuer compared with/without `https://` → a correct issuer refused, message blaming "a DIFFERENT cluster" | **FIXED** — scheme-insensitive; proven both ways |
| **B29** | `scripts/preflight/verify-admission.sh` | (a) `classify` named only the first cause, missed kubectl's CRD wording; (b) bare-Pod probe kept the template SA → refused by SA admission before PSA, blamed on #32 RBAC; (c) claim-template volumes missing in the bare Pod | **FIXED** — every cause named, RBAC only on a real denial, probe runs as `default` with `emptyDir` for claim templates; PSA verdict now reached |
| **B30** | `mimic_eks` | (a) strict reports add-ons it never installs (no CRDs at all); (b) `verify-contract.sh` judges the creator and AWS service-linked access entries as if they were the runner's, and reports desired node count, not joined | **OPEN** (mimic fidelity) |
| **B31** | `scripts/preflight/verify-cluster.sh` #35 | Read only `aws-node` env; current VPC CNI puts the switch on `aws-eks-nodeagent` `--enable-network-policy=true` → compliant cluster FAILED | **FIXED** — either form accepted, explicit false still fails |

**Cloud-team documents — edited the same day** (`CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md`
and the Confluence draft, item for item): §1 / point 2 name the quota keys and ask for **no
`limits.cpu`** (P-1); #34 / point 8 add a table of **the cluster's own flows** that any subnet rules
must keep (B27); #35 / point 9 say where the network-policy switch actually appears, and §4 /
point 22 command 2 now prints the node agent's argument and the add-on configuration (B31).

**What was proven live for the first time today:** all 12 `cluster-contract` gate blocks refuse
against a live cluster and only the expected ones refuse against a compliant one;
`verify-subnet-rules.sh` detects an absent flow by protocol; `verify-cluster.sh` fires on every
hostile defect it owns; `verify-admission.sh` reaches a hard PSA refusal. **Still never run
live:** `verify-pull-canary.sh`, `verify-deployed.sh`, D-39 placement, and any preflight as the
runner's (namespace-scoped) identity — all need in-cluster workloads, which need the ECR mirror.

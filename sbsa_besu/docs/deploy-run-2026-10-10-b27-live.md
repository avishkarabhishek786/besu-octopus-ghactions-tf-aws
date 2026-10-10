# Deploy run — 2026-10-10 — B27 live proof (RUNBOOK §E.2)

> **Live log.** Written step by step during the run: every command executed, in order, with
> what came back. Times are UTC. Run by Claude Code on the operator's explicit instruction
> ("You run and go live this time. I'll do it when everything is proven and run as
> expected") — the advise-only rule (CLAUDE.md §0.6) was lifted for this run only.

**Source under test:** branch `shared-eks-namespace` @ `51755fe` — the B27/B32/B33 fix
(`862f6c2`), its review follow-ups (`0318e45`), content-based NACL rule keys (`d12903e`) and
the RUNBOOK section this run follows (`51755fe`).

**What it must show** (RUNBOOK §E.2): the exact 2026-10-09 failure — `mimic_eks` hostile,
nodes in the app subnets, `mimic_vpc` on `nacl_mode = flows` — does **not** recur. The
expected checker output was computed offline from the same plans before the run.

**Ground rules:** USD 15 cap (expected ≈ $1.5–2); same-day teardown; `plan -out` then
`apply <file>`, plans in the session scratchpad (`$SP`), not the repo; every destroy with
the same vars as its apply; zero-check by direct describes.

DeletionGroups: `sbsa-net-sit-2026-10-10`, `sbsa-sit-2026-10-10`, `mimic-eks-sit-2026-10-10`.

---

## 0. Pre-checks (07:17)

```bash
aws sts get-caller-identity                    # 867728055761 / user/tfuser
aws secretsmanager list-secrets --include-planned-deletion   # only the two kept Octopus secrets
aws ec2 describe-vpcs (non-default) · eks list-clusters · ec2 describe-instances · kms list-aliases (custom)
aws logs describe-log-groups · iam list-roles (sbsa*, cc-test*) · ec2 describe-vpc-endpoints    # all empty
aws eks describe-cluster-versions              # 1.37 1.36 1.35 … — hostile's 1.37 offered
```

Account clean apart from the two deliberately-kept Octopus secrets. Terraform 1.16.1,
kubectl 1.36.3.

## 1. `mimic_vpc` on `flows` (07:18 → 07:23, ~$0)

```bash
cd mimic_vpc/terraform
sed -i 's/sbsa-net-sit-2026-10-09/sbsa-net-sit-2026-10-10/' environments/sit/primary.tfvars
terraform init                                  # backend already on besu/sit/network.tfstate (1347-byte empty state)
terraform plan -var-file=environments/sit/primary.tfvars -out=$SP/mvpc.plan     # NO -var nacl_mode: flows is the default under test
terraform apply $SP/mvpc.plan
cd .. && ./scripts/verify-contract.sh && ./scripts/emit-handover.sh
```

| | Result |
|---|---|
| Plan | **333 to add** — as predicted; 261 `aws_network_acl_rule` (was 249 on 10-09: +24 cluster-flow rules, −12 from B33's merge of duplicates — one per direction on each of the 6 workload NACLs). No IGW / NAT / EIP / route |
| Apply | 07:19:08 → 07:20:45, `333 added`. VPC **`vpc-0fbb0d4b8a3d40512`** |
| `verify-contract.sh` | **27 passed, 0 failed** |
| Hand-over | emitted 07:21:14Z, linked into `shared/` and `chain/` |

## 2. `verify-subnet-rules.sh`, live — positive (07:23, free)

```bash
APP=subnet-05782a0dbe7ddeed7,subnet-0dd68417bf98fe9fb,subnet-09f4258902e14aeaf     # app subnets = hostile cluster's subnets
sbsa_besu/scripts/preflight/verify-subnet-rules.sh --region af-south-1 --node $APP --control-plane $APP \
  --lb <3 lb> --endpoint <3 endpoint> --data <3 data> --runner subnet-066ef6e5dbbc167b9   # ledger az1
```

**`46 passed, 0 failed, 12 warnings, 4 skipped`, exit 0 — exactly the offline prediction.**
Warnings: C-1 ×6 and F-7 ×3 *"permitted, but only by a 0.0.0.0/0 rule"* (outbound 443
matches F-6's S3 rule 150 before F-7's 180 — predicted); F-9 ×3 *incidental*, as on 10-09.
Skipped: F-8, F-10, C-4, #33.

## 3. Live negative — break C-1, restore (07:24 → 07:26, free)

```bash
terraform plan -var-file=environments/sit/primary.tfvars -var 'nacl_break_flow=C-1' -out=$SP/break.plan
#   0 add, 1 change (nacl_budget), 12 destroy — 6 ingress + 6 egress, every one tcp/443
terraform apply $SP/break.plan            # 07:24:45, 12 destroyed
# checker, same args
terraform plan -var-file=environments/sit/primary.tfvars -out=$SP/restore.plan   # 12 add, 1 change
terraform apply $SP/restore.plan          # 07:25:05 → 07:25:54
# checker again
```

| | Checker |
|---|---|
| C-1 broken | **`46 passed, 9 failed, 3 warnings`, exit 1 — C-1 ×6 + F-7 ×3, nothing else.** e.g. `#34 C-1 BLOCKED: node 10.60.4.0/23 -> control plane 10.60.6.0/23 (tcp/443) — DENIED by acl-… ingress rule 32767 (0.0.0.0/0) — forward in` |
| Restored | `46 passed, 0 failed, 12 warnings`, exit 0 |

The break removed exactly the 12 rules it named and replaced nothing else — content-based
keys (`d12903e`) live.

## 4. `shared` — 15 interface endpoints (07:26 → 07:29; **billing ≈ $0.45/h from here**)

```bash
cd sbsa_besu/terraform
sed -i 's/sbsa-sit-2026-10-09/sbsa-sit-2026-10-10/' environments/sit/common.tfvars
cd shared && terraform init -backend-config=… key=besu/sit/shared.tfstate …
terraform plan -var-file=../environments/sit/common.tfvars -out=$SP/shared.plan    # 27 to add — identical to 10-09
terraform apply $SP/shared.plan                                                     # 07:26:42 → 07:28:35
terraform output billable_endpoint_eni_count                                        # 45
```

The network contract's 8 gates passed against the restrictive-NACL VPC, as on 10-09.

## 5. `mimic_eks` hostile — the reproduction (07:30 → )

```bash
cd mimic_eks/terraform
cp ../../mimic_vpc/network-handover.auto.tfvars .          # vpc-0fbb0d4b8a3d40512
sed -i 's/mimic-eks-sit-2026-10-09/mimic-eks-sit-2026-10-10/' environments/sit/mimic.tfvars
terraform init
terraform plan -var-file=environments/sit/mimic.tfvars -out=$SP/hostile.plan
#   20 to add: cluster 1.37, public endpoint, 3 subnets; node group 3 × m6i.xlarge in the three app subnets;
#   provider region = var.region (the B25 fix) — identical shape to the 10-09 run that failed
terraform apply $SP/hostile.plan                             # in the background
```

Apply 07:29:25 → 07:40:13, **`20 added`, no error**. Cluster ACTIVE 07:37:50; **node group
created in 1m43s** (on 10-09 the same step timed out into `NodeCreationFailure`).

```bash
aws eks update-kubeconfig --name sbsa-besu-sit-shared --kubeconfig $SP/kc
kubectl get nodes -o wide
#   ip-10-60-4-27  (af-south-1a / afs1-az1)  Ready
#   ip-10-60-7-74  (af-south-1b / afs1-az2)  Ready
#   ip-10-60-9-36  (af-south-1c / afs1-az3)  Ready      ← the one that never joined on 10-09
aws eks describe-nodegroup … --query 'nodegroup.[status,length(health.issues)]'     # ACTIVE 0
```

**3/3 Ready, node group ACTIVE, zero health issues.** ✅

## 6. Was the cross-subnet path exercised? — yes (07:37 → 07:40)

```bash
aws ec2 describe-network-interfaces --filters "Name=description,Values=Amazon EKS sbsa-besu-sit-shared" \
  --query 'NetworkInterfaces[].[SubnetId,AvailabilityZone,PrivateIpAddress]'
#   07:37:50 (cluster ACTIVE):  app az2 10.60.7.61                      — one ENI only
#   07:40:30 (after nodes):     app az1 10.60.5.3 · app az2 10.60.7.61  — NONE in az3
```

The same placement as 10-09: no control-plane ENI in the az3 app subnet, so the az3 node
could reach the API **only across a NACL**. Its registration is therefore C-1 crossing the
fixed rules, not traffic inside one subnet. **C-1 proven live.** ✅

CoreDNS landed on the az2 and az3 nodes, so the az1 node's pods resolve across a subnet
boundary (C-2's case), but C-2 could not be exercised: no pullable image with a shell
exists yet (RUNBOOK §E.2).

## 7. C-3 live, and B27 reproduced and cured on demand (07:40 → 07:47)

```bash
kubectl -n kube-system logs aws-node-qkvkr -c aws-node --tail=2        # pod on the az3 node
#   time="2026-10-10T07:39:55Z" level=info msg="Successfully copied CNI plugin binary and config file."
kubectl -n kube-system logs <coredns pod on the az3 node> --tail=2     # CoreDNS-1.14.7 …
```

Logs reached the API from the az3 kubelet's 10250, served to control-plane ENIs in az1/az2
— across the NACL. **C-3 proven live.** ✅

**The decisive negative — remove C-1 with the cluster up:**

```bash
cd mimic_vpc/terraform
terraform plan -var-file=environments/sit/primary.tfvars -var 'nacl_break_flow=C-1' -out=$SP/break2.plan   # 0/1/12, as in step 3
terraform apply $SP/break2.plan                                       # 07:41:52 → 07:42:04
kubectl get nodes   (every ~15 s)
terraform plan -var-file=environments/sit/primary.tfvars -out=$SP/restore2.plan && terraform apply $SP/restore2.plan   # 07:46:17 → 07:46:32
terraform plan -detailed-exitcode …                                   # 0 — no drift after the restore
```

| Time | az1 node (has ENI) | az2 node (has ENI) | **az3 node (no ENI)** |
|---|---|---|---|
| 07:42:04 | C-1 removed | | |
| 07:42:41 | Ready | Ready | Ready |
| **07:42:58** | Ready | Ready | **NotReady** |
| 07:45:34 | Ready | Ready | NotReady (held 2.5 min) |
| 07:46:32 | C-1 restored | | |
| **07:46:42** | Ready | Ready | **Ready** |

**Only the node without a control-plane ENI in its subnet went `NotReady`, ~54 s after the
rule went (the kubelet's lease grace), and it recovered within ~10 s of the restore.** That
is B27 reproduced on demand and cured by the fix, on a live cluster — the strongest
evidence this fixture can produce. ✅

---

# Teardown (07:47 → 08:11)

Reverse order of creation; every destroy with the same vars as its apply (`mimic_vpc` with
**no** `nacl_mode` — it was applied on the default); destroy plans in `$SP`.

```bash
cd mimic_eks/terraform && terraform plan -destroy -var-file=environments/sit/mimic.tfvars -out=$SP/hostile-destroy.plan && terraform apply $SP/hostile-destroy.plan
#   07:47:30 → 07:54:07, 20 destroyed, state empty
aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=vpc-0fbb0d4b8a3d40512   # 45 vpc_endpoint + 1 "interface"  ← see B34
cd sbsa_besu/terraform/shared && terraform plan -destroy -var-file=../environments/sit/common.tfvars -out=$SP/shared-destroy.plan && terraform apply $SP/shared-destroy.plan
#   07:54:37 → 07:59:21, 27 destroyed, state empty — 1 ENI still in the VPC
```

**B34 — the `mimic_eks` destroy leaked two resources, and the second blocked the VPC.**

```bash
aws ec2 describe-network-interfaces … 
#   eni-0964f4498be47cc88  available  "aws-K8S-i-02e51cbbd487c2869"  app az2  10.60.6.93
#   tags: eks:eni:owner=amazon-vpc-cni, cluster.k8s.amazonaws.com/name=sbsa-besu-sit-shared, createdAt 07:39:44
aws ec2 describe-instances --instance-ids i-02e51cbbd487c2869      # terminated
aws ec2 delete-network-interface --network-interface-id eni-0964f4498be47cc88    # 07:59:59
cd mimic_vpc/terraform && terraform plan -destroy -var-file=environments/sit/primary.tfvars -out=$SP/mvpc-destroy.plan && terraform apply $SP/mvpc-destroy.plan
#   08:00:41 — subnets gone in seconds, then DeleteVpc retried for 10 min (on 10-09 the whole destroy took ~1 min)
aws ec2 describe-security-groups --filters Name=vpc-id,Values=vpc-0fbb0d4b8a3d40512
#   sg-0633b935356b67cf6  eks-cluster-sg-sbsa-besu-sit-shared-1525306412  (aws:eks:cluster-name=sbsa-besu-sit-shared)
aws ec2 delete-security-group --group-id sg-0633b935356b67cf6      # 08:10:51
#   → terraform: 333 destroyed at 08:10:59, state empty
```

A VPC CNI secondary ENI on one node outlived the node. The EKS cluster security group is
created and deleted by EKS, not Terraform; it was most likely still referenced by that ENI
when EKS deleted the cluster, and EKS does not retry — so it stayed, and pinned the VPC.
Both were ours by tag and creation time, and both were deleted only after confirming the
instance was terminated and nothing referenced the group. Not seen on 10-09 — the leak is
intermittent, which is why it needs a sweep, not luck.

**Zero-check (08:13), direct describes, both regions:** VPCs, EKS, instances (non-terminated),
volumes, ENIs, non-default SGs, endpoints, LBs, launch templates, log groups, hosted zones,
`sbsa*`/`cc-test*` IAM roles, local `sbsa*` policies — **all empty**. The tagging API still
listed resources under all three of today's DeletionGroups; every one described directly is
`NotFound`, `terminated` or (KMS) `PendingDeletion` — index lag, as B16 records, which is why
the zero-check is by direct describe. Remaining, all expected: the two kept
`sbsa-besu-primary-*` secrets; the GitHub CI OIDC provider; KMS af-south-1 = 5 customer keys
`PendingDeletion` (4 from 10-09 + today's `mimic_eks` secrets key, 2026-10-17); us-east-1 =
the one B25 key.

Housekeeping: `$SP` plans and logs are outside the repo; no tracked plan file was touched.
The three tfvars `deletion_group` bumps are in gitignored files.

**Spend (estimate):** `shared` 07:26 → 07:59 (0.55 h × $0.45) ≈ $0.25; `mimic_eks` control
plane 07:30 → 07:54 + 3 × m6i.xlarge ~07:38 → 07:54 ≈ $0.25 → **≈ $0.5**, against the $15 cap.

---

# Findings

| # | One line | Status |
|---|---|---|
| **B27** | Restrictive NACLs omitted the cluster's own flows | **CLOSED — proven live.** 3/3 joined with the az3 node registering across a NACL; C-3 live; C-1 removed → only the ENI-less node NotReady, restored → Ready |
| **B32** | F-7 (runner → API) blocked by the mimic, never checked | **NACL half proven live** — the C-1 ingress 443 rule it shares is what the az3 node used. **Runner half still open**: no runner in this run |
| **B34** | `mimic_eks` destroy leaked a VPC CNI ENI, which pinned the EKS cluster SG and blocked the VPC delete for 10 min | **OPEN** — needs a sweep by cluster tag between the `mimic_eks` destroy and the `mimic_vpc` destroy |

**What was proven live for the first time:** a cluster on the restrictive NACLs, the
cluster's own flows C-1 and C-3 across them, the checker's C-1/F-7 sections against live
rules, and a live NACL change toggling exactly one node. **Not covered** (RUNBOOK §E.2):
C-2 (no pullable image with a shell — after the mirror), F-7 from an actual runner, and
anything to do with GitHub Actions or Octopus Deploy, which this run did not touch.

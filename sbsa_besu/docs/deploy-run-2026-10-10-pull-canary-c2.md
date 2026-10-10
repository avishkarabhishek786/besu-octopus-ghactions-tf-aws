# Deploy run — 2026-10-10 (2nd) — pull canary (#38) + C-2 live

> **Live log.** Every command executed, in order, with what came back. Times UTC. Run by
> Claude Code on the operator's explicit instruction ("yes let's do it", after the first CI
> mirror) — advise-only (CLAUDE.md §0.6) lifted for this run only.

**Source under test:** `shared-eks-namespace` @ `974f9a7` + the canary admissibility fix
(below, committed with this log).

**What it must show**
1. **#38 / D-38 — the cluster can pull our mirror.** The first time a cluster pulls from
   the registry the GitHub Actions workflow filled (run `38040455269`), by digest, as the
   **node role** via kubelet's ECR credential provider — not as a human or the runner.
2. **C-2 live** — pods resolve through CoreDNS across a NACL (closes what the B27 run could
   not: it had no image with a shell), and removing C-2's rule breaks exactly that.

**Shape:** `mimic_vpc` on `flows` → `shared` → `mimic_eks` **strict**, `node_count = 3`
(3 general + 3 tainted ledger nodes, in the ledger subnets — #28 granted), public endpoint
on (the laptop drives kubectl; no runner in this run — as on 10-09's strict pass).

**Not proven by this run, said up front:** cross-account pull. Registry and cluster share an
account here, so the node role's `AmazonEC2ContainerRegistryReadOnly` is sufficient and no
repository policy is involved. In the bank the registry is a central shared-services account
(CD-27) and the repository policy must name the cloud team's node role (#38's first half);
`--check-policy` reports that half and is expected to say "no repository policy" here.

DeletionGroups: `sbsa-net-sit-2026-10-10b`, `sbsa-sit-2026-10-10b`, `mimic-eks-sit-2026-10-10b`.
USD 15 cap; expected ≈ $2. Same-day teardown.

---

## Found before running — the canary could never have reached the registry (B35)

`verify-pull-canary.sh` created its pod with a bare `kubectl run`: no resources, no
securityContext. Under any `ResourceQuota` that names requests — exactly what #27 asks
for — that pod is refused at admission (P-1's lesson), and under `restricted` Pod Security
too. The script then reports *"the API server refused … NOT a registry failure"* and never
tests a pull. Neither the mimic nor our asks include a `LimitRange` that would default the
resources. Fixed: the pod carries small explicit requests/limits and a restricted-compliant
securityContext (`runAsNonRoot`, uid 65534, drop ALL, `RuntimeDefault`), so the pull is
the only thing under test. Client-side render checked; the live run below is the proof.

## 0. Pre-checks (09:36)

```bash
aws ec2 describe-vpcs · eks list-clusters · ec2 describe-instances · ec2 describe-vpc-endpoints   # all empty
aws iam list-roles (sbsa*)              # sbsa-besu-sit-ecr-push — the long-lived push role, expected
aws ecr describe-repositories           # 28 — the mirror, expected
```

## 1. `mimic_vpc` on `flows` (09:37 → 09:41, ~$0)

DG bumped to `sbsa-net-sit-2026-10-10b`; plan **333 to add**; apply 09:37:20 → 09:38:58; VPC
**`vpc-0a7e483b05b3379ef`**; `verify-contract.sh` **27/0**; hand-over emitted.

## 2. `shared` (09:41 → 09:43; **billing ≈ $0.45/h from here**)

DG `sbsa-sit-2026-10-10b`; 27 to add; apply 09:41:30 → 09:43:15.

## 3. `verify-subnet-rules.sh` — the STRICT layout (ledger subnets), live (09:44, free)

```bash
L=<3 ledger subnets>
verify-subnet-rules.sh --region af-south-1 --node $L --control-plane $L --lb … --endpoint … --data … --runner <ledger az1>
```

**`25 passed, 12 failed, 9 warnings, 4 skipped`, exit 1 — correct, and not a blocker for this
run.** Every flow this run depends on passes: C-1, C-2, C-3, F-5 (endpoints), F-6 (S3). The
12 FAILs are **F-2 ×9** (NLB → pods: the LB NACL's return rule covers only the app subnets)
and **F-9 ×3** (database return, likewise): the mimic is on its default
`ledger_subnets_in_use = false` ("#28 not granted"), so pods in the ledger subnets are not
rule sources. Setting it adds the ledger rules and exceeds the 20-rule default — #34's quota
finding, now seen live from the consumer's side. F-1 between ledger subnets is
*incidental* (rides the VPC-CIDR ephemeral rule), for the same reason.

## 4. `mimic_eks` strict (09:43 → 09:54)

```bash
terraform plan -var-file=environments/sit/mimic.tfvars -var profile=strict -var endpoint_public_access=true -var node_count=3 -out=$SP/strict.plan
#   22 to add: 1.36, public+private, general group 3 nodes + ledger group 3 nodes (taint dedicated=besu-ledger:NoSchedule), ledger subnets
terraform apply $SP/strict.plan          # 09:43:28 → 09:53:32; node groups 1m22s / 1m33s
./scripts/apply-tenancy.sh               # besu-ledger/besu-app at baseline; quota requests+limits cpu 8 / mem 24Gi; gp3-wffc
```

**6/6 Ready**, two per AZ (one general, one `workload=besu-ledger`). Control-plane ENIs in
**az1 and az3 only** → both az2 nodes joined across a NACL: **C-1 live again, on the ledger
subnets**. CoreDNS on the az2 and az3 **general** nodes → the az1 general node
`ip-10-60-0-242` has none: the C-2 test point.

## 5. #38 — the pull canary, live (09:55, free)

```bash
kubectl -n besu-ledger run old-canary --image=$TOOLS --restart=Never --dry-run=server …   # the PRE-FIX pod shape
#   Forbidden: failed quota: ledger-quota: must specify limits.cpu, limits.memory, requests.cpu, requests.memory   ← B35, live
verify-pull-canary.sh -n besu-ledger -i <acct>.dkr.ecr.af-south-1.amazonaws.com/mirror/alpine/k8s@sha256:3ac15bcb…1681 -t 180
#   PASS  the cluster pulled …/mirror/alpine/k8s@sha256:3ac15bcb…      (09:55:04 → 09:55:21)
verify-pull-canary.sh -n besu-ledger -i <acct>.dkr.ecr.af-south-1.amazonaws.com/mirror/hyperledger/besu@sha256:ac85d23b…d0bc -t 300
#   PASS  the cluster pulled …/mirror/hyperledger/besu@sha256:ac85d23b… (09:55:21 → 09:55:37)
```

**#38 proven live (same-account):** the cluster's node role, through kubelet's ECR credential
provider, pulled two images the GitHub Actions workflow mirrored — by digest, through the
air-gapped VPC's `ecr.api`/`ecr.dkr`/S3 endpoints — in a namespace with baseline Pod Security
and a quota. First pull of our registry by any cluster.

```bash
verify-pull-canary.sh … --check-policy arn:aws:iam::<acct>:role/sbsa-besu-sit-eks-node-role -R mirror/alpine/k8s -R mirror/hyperledger/besu
#   FAIL  mirror/alpine/k8s has NO repository policy — their node role cannot pull (#38)     ← contradicted by the PASS above
```

**B36** — the policy half did not know that a same-account pull needs no repository policy.
Fixed after teardown: when the repository's `registryId` equals the node role's account it
passes with that explanation; cross-account it still demands the policy (both branches
exercised with stub `kubectl`). The node role's managed policies:
`AmazonEC2ContainerRegistryReadOnly`, `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`,
`AmazonSSMManagedInstanceCore`.

## 6. C-2 live — DNS across a NACL, and cut on demand (09:56 → 09:59)

A probe pod on the az1 general node (no CoreDNS there), image = our mirrored `alpine/k8s`;
`python3` sends 20 A-queries for `kubernetes.default.svc.cluster.local` to the cluster DNS
service `172.20.0.10` over UDP and 20 over TCP (kube-proxy spreads them over both CoreDNS
replicas, az2 and az3 — every one crosses a subnet boundary).

| Time | NACL state | UDP | TCP |
|---|---|---|---|
| 09:56:33 | as built | **20/20** | **20/20** |
| 09:57:35 | `nacl_break_flow = "C-2 pods -> CoreDNS (udp)"` applied (6 destroyed — udp/53 ingress on the 6 workload NACLs) | **0/20 — TimeoutError** | **20/20** |
| 09:59:03 | restored (6 added); `plan -detailed-exitcode` = 0 | **20/20** | **20/20** |

**C-2 proven live**, both protocols, and the cut reproduces #34's partly-silent class: DNS over
UDP dead, TCP alive — most resolvers retry over TCP only on truncation, so most pods would
simply fail to resolve while some tools "work". `busybox nslookup` agreed (`Address: 172.20.0.1`).

---

# Teardown (10:00 → 10:13)

```bash
kubectl -n besu-ledger delete pod dnsprobe                         # no canary pods left (the script cleans its own)
mimic_eks: plan -destroy (same vars) → 22 destroyed, 10:00:24 → 10:05:27, state empty
B34 sweep (RUNBOOK §E.2 step 8): available ENIs tagged with the cluster — none; EKS cluster SG — none
shared:    27 destroyed, 10:06:19 → 10:11:10; VPC then held 0 ENIs, no non-default SG
mimic_vpc: 333 destroyed, 10:11:44 → 10:13:00 (76 s — no leak this time; B34 is intermittent)
```

**Zero-check (10:13), direct describes, both regions:** VPCs, EKS, instances, volumes, ENIs,
non-default SGs, endpoints, LBs, launch templates, log groups, hosted zones — **all empty**.
Long-lived by design: `sbsa-besu-sit-ecr-push` and the 28 `mirror/` repositories.

**Spend (estimate):** `shared` 09:41 → 10:11 ≈ $0.23; `mimic_eks` control plane 09:43 → 10:05
+ 6 × m6i.xlarge ~09:52 → 10:05 ≈ $0.35 → **≈ $0.6**.

# Findings

| # | One line | Status |
|---|---|---|
| **#38** | Cluster pulls our mirror as the node role | **PROVEN LIVE (same-account).** Cross-account policy half: still the bank's question (CD-27) |
| **C-2** | Pods → CoreDNS across a NACL | **PROVEN LIVE**, UDP + TCP; cut → UDP 0/20, TCP 20/20; restored |
| **B35** | The pull canary's bare pod was refused by any quota naming requests | **FIXED** — explicit resources + restricted-compliant securityContext; refusal of the old shape shown live |
| **B36** | `--check-policy` FAILed a same-account registry the canary proved pullable | **FIXED** — same-account branch; cross-account unchanged |
| **B34** | Teardown leak | **Not reproduced** (intermittent); the sweep ran and found nothing |

**Still not proven:** cross-account pull; F-7 from an actual runner; `verify-deployed.sh` and
D-39 with real validators; anything through **Octopus Deploy**.

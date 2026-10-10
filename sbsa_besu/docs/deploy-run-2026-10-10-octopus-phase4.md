# Deploy run — 2026-10-10 (Octopus) — CD-67 Phase 4: the first deployments from a GitHub release

> **Live log, reconstructed the same day** from the session transcript, the Octopus task API
> and CloudTrail. The operator's terminal log of the teardown was lost; the teardown is
> evidenced instead by the read-only zero-check in §6. Times UTC. **Who ran what:** *operator*
> = in GitHub, the Octopus UI, an SSM shell, or a `terraform apply` the permission layer
> refused to Claude; *Claude* = read-only API/AWS calls and plans from the laptop. The Octopus
> API key is read from Secrets Manager into a variable and unset; never printed.

**Source under test:** `shared-eks-namespace` @ `191bcff` (release 2026.10.10.6 onward), then
`d777d07` (B43; not exercised by a deployment).

**What it must show:**
1. `release.yml` → Octopus → AWS, end to end: GitHub signs in to Octopus by OIDC, Octopus
   signs in to AWS by OIDC, and `besu-infra` applies `shared` → `chain` → runner bundle →
   `runner` on a hosted worker.
2. The **in-VPC path**: a Tentacle on the In-VPC EC2 Runner, polling through the egress
   proxy, runs `besu-workloads` against the private EKS endpoint.
3. The **CD-5 gate**: `besu-validators` stops for a person in SIT.

**Outcome:** ✅ all three. Four defects on the way (B40–B43), all fixed. Cost ≈ $4.5.

---

## 1. Mimics and deploy config (14:05 → 14:27, operator)

`mimic_vpc` (flows + the B40 F-8 rule, DG `sbsa-net-sit-2026-10-10c`, 345 resources;
`vpc-08e7261dbbdd3e45b`), `mimic_egress` (29; proxy `i-0434c113818c2e3c1`, peering
`pcx-0db4cf7845606f677`), `emit-handover.sh`, then `ENV=sit push-deploy-config.sh
sbsa-besu-sit-octopus-deploy-config` → 4 files.

## 2. `besu-infra` — three releases (14:24 → 15:08)

| Release | GitHub run | Octopus task | Result |
|---|---|---|---|
| 2026.10.10.4 | 38059442057 | `ServerTasks-1516` 14:24:50 → 14:25:29 | ❌ `terraform: shared` exit 141 after `Terraform v1.16.1`, before any AWS call (**B41**). GitHub's "Find the SIT deployment" 404'd on the slug route (**B42**). Fixed in `191bcff` |
| 2026.10.10.5 | 38059916117 | `ServerTasks-1517` 14:32:09 → 14:53:23 | ❌ `shared` ✅, `chain` ✅ (cluster `sbsa-besu-primary-eks`), runner bundle ✅, `terraform: runner`: `RunInstances … InvalidIPAddress.InUse: Address 10.60.0.250 is in use` (**B43**) |
| 2026.10.10.6 | 38061896284 | `ServerTasks-1518` 15:01:54 → 15:07:56 | ✅ after the operator freed the address (below); runner `i-0327de796af004b24` booted `[bootstrap] ready. source=191bcff/2026.10.10.6` |

**B43 unblock (operator, ~14:58):**

```bash
aws ec2 create-subnet-cidr-reservation --subnet-id subnet-091f5334481a0b4e9 \
  --cidr 10.60.0.250/32 --reservation-type explicit --region af-south-1   # scr-00405fb7285c2d5bf
aws ec2 unassign-private-ip-addresses --network-interface-id eni-0f3a9de898fbcc343 \
  --private-ip-addresses 10.60.0.250 --region af-south-1                   # an aws-K8S-i-… node ENI
```

CloudTrail showed `AssumeRoleWithWebIdentity` for `sbsa-besu-sit-octopus-deploy` with subject
`space:default:project:besu-infra:environment:sit`, so Octopus → AWS OIDC works on a hosted worker.

## 3. Tentacle on the runner (16:15 → 16:18)

**Operator**, over SSM as root:

```bash
sudo env OCTOPUS_INSTANCE=avishkarabhishek786 OCTOPUS_SPACE='Default' OCTOPUS_WORKER_POOL=besu-runner-sit \
  OCTOPUS_API_KEY_SECRET=sbsa-besu-primary-octopus-register-key \
  EXPECTED_POLLING_CERT_SHA256='9B:A5:…:F3:78' TENTACLE_CERT_SECRET=sbsa-besu-primary-tentacle-cert \
  bash /opt/besu-deploy/sbsa_besu/scripts/runner/install-tentacle.sh
# … Machine registered successfully
# OK  tentacle.service running as tentacle; polling https://polling.avishkarabhishek786.octopus.app via http://proxy.egress.mimic.internal:3128
```

Same hostname (`ip-10-60-0-250`) and the 09-17 certificate, so `--force` **updated** the existing
`Workers-1` and moved it from `sit-ledger-workers` to `besu-runner-sit` (`WorkerPools-43`), rather
than adding a second worker. Its status still read Unavailable from 07:46. **Claude** ran a health
check: `POST /api/Spaces-1/tasks {"Name":"Health","Arguments":{"MachineIds":["Workers-1"]}}` →
`ServerTasks-1520` Success → **Healthy** ("old version of Tentacle (11.0.4398)": the manifest pin,
a warning only).

## 4. `besu-workloads` (16:28:49 → 16:29:59)

GitHub run 38067772108, release 2026.10.10.7, `ServerTasks-1521` ✅. The first deployment
**inside the VPC**: the package (421 KB) went to the Tentacle through the proxy, and the step ran
on the runner with its instance role. 4/4 nodes Ready over the private endpoint; namespace
`besu-smoke` + quota created; **#38 pull canary PASS** (`mirror/alpine/k8s@sha256:3ac15bcb…`, as
the node role); **C-2 DNS PASS** over UDP and TCP.

## 5. `besu-validators` (16:33:19 → 16:38:37)

GitHub run 38068070695, release 2026.10.10.8, `ServerTasks-1522` ✅. The deployment paused at
**"Approve validator roll (QBFT: one validator at a time)"**; the operator approved it at
16:38:09. The roll step ran on the runner (delta upload: 255 KB instead of 422 KB) and printed
*"No validator releases in besu-ledger — nothing to roll … NOT proven: the rolling procedure
itself"*. The GitHub run waited on the gate throughout and went green.

## 6. Teardown (≈ 16:44 → 16:58) and zero-check (Claude, read-only)

**Operator:** `runner` → `chain` → B34 sweep → `shared` → `mimic_egress` → delete
`scr-00405fb7285c2d5bf` → `mimic_vpc`, each `plan -destroy -out` then `apply`. CloudTrail:
`TerminateInstances` from 16:44:00, last `DeleteVpc` 16:58:10.

Zero-check, af-south-1 unless stated:

| Check | Result |
|---|---|
| Remote state `besu/sit/{shared,chain,runner}.tfstate` | 0 resources each |
| Non-default VPCs (af-south-1 and us-east-1), EKS clusters, instances, ENIs, VPC endpoints, load balancers, active peerings, EIPs, volumes, hosted zones, log groups | none |
| Subnet CIDR reservation | gone: its subnet `subnet-091f5334481a0b4e9` no longer exists (`InvalidSubnetID.NotFound`), and a reservation can't outlive its subnet |
| KMS | AWS-managed only, plus customer keys in `PendingDeletion` (today's runs, 7-day window) |
| Kept on purpose | secrets `sbsa-besu-primary-octopus-register-key`, `…-tentacle-cert`, `sbsa-besu-sit-octopus-deploy-config`, `sbsa-besu-octopus-terraform-key`; roles `sbsa-besu-sit-ecr-push` (mirror CI), `sbsa-besu-sit-octopus-deploy` (aws-trust); state bucket; the Octopus space, `ci-trust`, and worker `Workers-1` (now Unavailable, re-registers with `--force`) |

**Cost:** mimics from 14:05, chain from ≈ 14:35, all gone by 16:58: ≈ **$4.5**.

## 7. What's still open

- **The rolling procedure** (`rolling-besu-apply.sh` under Octopus) needs validators, so it waits
  for the CT-5 in-cluster rewrite.
- **The B43 bank-side reservation** is an R-10 ask. `d777d07` has the mimic reservation and the
  runner plan guard, but no deployment has run them yet; the next fresh build does.
- Follow-ups: fail-loud unscoped defaults for `Besu.Cluster` / `Besu.DeployConfigSecret`; delete
  pool `sit-ledger-workers`; narrow the deploy role (it needs `ec2:DescribeNetworkInterfaces` and
  `ec2:DescribeInstances` for the B43 guard); a persistent runner ENI.

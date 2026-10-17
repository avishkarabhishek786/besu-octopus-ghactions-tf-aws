# Practice run — 2026-10-17 — the whole stack, by hand, one step at a time

**What this is:** a simple version of RUNBOOK E.3 + E.4: the same path that worked on 2026-10-11,
with the lessons from that day already built in. Each step says **why** it exists, the
**commands**, what you **should see**, and what to **tell Claude**. Claude writes the log
(bottom of this file) from what you report.

**Goal:** a 4-validator chain in a private cluster, a transaction you send yourself, seen in
Blockscout. Then delete everything.

**Cost:** about **$2/hour** from Step 5 until the teardown finishes. A clean run is ~3 hours
≈ **$6**. The clock is what makes the teardown non-optional.

**Rules for today**
- Do one step, check the "should see", tell Claude the result, then move on.
- If a result doesn't match, **stop** — don't improvise a fix. Paste the error.
- Never paste a secret (private key, API key) into the chat or onto a command line. Use `read -rs`.

**The order, and why it's that order**

```
mimic_vpc ─► mimic_egress ─► deploy-config ─► besu-infra (shared → chain → runner) ─► Tentacle ─► besu-workloads ─► tx
 network       proxy          runner's input    AWS layer, from Octopus                 runner joins   chain + explorer
                                                                                         Octopus
teardown = the reverse
```

Each thing needs the one before it: the platform must sit inside a VPC, the runner needs the
proxy to talk to Octopus, and the chain can only be installed from inside the VPC — by the runner.

---

## What we deliberately skip today (already done, and it persists)

| Skipped | Why it's safe to skip | When you'd run it again |
|---|---|---|
| **`supply-chain.yml`** (the ECR mirror) | The mirror isn't torn down — it's not compute and costs cents. 29 repositories in af-south-1, **tag-immutable, no expiry** (a tag can't be overwritten or aged out), last populated 2026-10-11 from `f8ad533`. Nothing about which images or charts we use has changed since. | Whenever an image, chart or version changes (e.g. a Besu bump) — **before** the deploy, or the pull hangs (no internet to fall back on). And in a fresh account / the bank, once, first. **Steps: Appendix A1–A2** |
| **Octopus setup** (`aws-trust`, `octopus/terraform`, `ci-trust`, GitHub variables, Tentacle secrets) | Configuration, not compute — applied 2026-10-10/11 and kept | When `octopus/terraform` changes, or in a new space / instance / account. **Steps: Appendix A3–A7** |

Check the mirror yourself (read-only):

```bash
aws ecr describe-repositories --region af-south-1 --query 'length(repositories)' --output text   # → 29
aws ecr describe-images --region af-south-1 \
  --repository-name mirror/prometheus-operator/prometheus-config-reloader \
  --query 'imageDetails[].imageTags' --output text                                                # → v0.91.0 (the one added 10-11)
```

> **🏦 In the bank** the mirror lives in the cloud team's shared-services ECR account
> (CD-27), and who runs the mirror pipeline is still an open question (Q-4d).

---

## Before you start — have the test sender's private key to hand

Step 11 sends a transaction, and on this chain **only accounts funded in genesis have any
ETH** (F20 — there is no faucet, and genesis is written once, in Step 9). The funded address
is set in `sbsa_besu/terraform/environments/sit/chain.tfvars` → `genesis_funded_accounts`
(currently `0x9f7edFa32Bc9b82C9E684917BBcd205306a1b248`, set 2026-10-11).

**Only the address travels through the pipeline** (Step 4 ships `chain.tfvars`, Step 9 writes
genesis). **The private key never does** — by design, the platform needs to know who to fund,
never how to sign as them. So it's on you to have it before Step 9: if you don't, either find
it, or put a *new* address you hold the key for into `genesis_funded_accounts` **before Step 4**
(after Step 9 it's too late without rebuilding the chain).

```bash
# a new sender, kept encrypted — the raw key never sits in a shell variable or history
cast wallet new                                       # note the Address; the key is shown once
cast wallet import besu-sit-sender --interactive      # paste that key + choose a password
cast wallet address --account besu-sit-sender         # → the address to put in genesis_funded_accounts
```

**Check you hold the right key, without showing it:** `cast wallet address --account besu-sit-sender`
(or `--private-key "$PK"` after `read -rs PK`) must print the funded address.

---

## Step 0 — Set up your terminal and check the account is empty (laptop · free)

**Why:** every later command uses these variables, and starting from a clean account means
anything you find at the end was created today.

```bash
export REPO=~/Documents/Blockchain/Besu/besu-octopus-ghactions-tf-aws
export SP=~/besu-run-2026-10-17          # scratch folder for plan files
mkdir -p $SP

aws sts get-caller-identity --query Account --output text        # → 867728055761
aws ec2 describe-vpcs --region af-south-1 --filters Name=is-default,Values=false \
  --query 'Vpcs[].VpcId' --output text                            # → (empty)
aws eks list-clusters --region af-south-1 --query clusters --output text   # → (empty)
```

> Opening a new terminal later? Run the two `export` lines again.

**Tell Claude:** the account number, and whether both lists were empty.

---

## Step 1 — Give today's resources a new tag (laptop · free)

**Why:** every resource is tagged with a `deletion_group`. The teardown and the final
zero-check search by that tag, so each run gets its own value — leftovers from one day can
never be mistaken for another's. There are three of them: network, proxy, platform.

```bash
cd $REPO
sed -i '/^deletion_group/s/2026-10-11/2026-10-17/' \
  mimic_vpc/terraform/environments/sit/primary.tfvars \
  mimic_egress/terraform/environments/sit/primary.tfvars \
  sbsa_besu/terraform/environments/sit/common.tfvars
grep -h '^deletion_group' mimic_vpc/terraform/environments/sit/primary.tfvars \
  mimic_egress/terraform/environments/sit/primary.tfvars sbsa_besu/terraform/environments/sit/common.tfvars
```

**Should see:** `sbsa-net-sit-2026-10-17`, `sbsa-egress-sit-2026-10-17`, `sbsa-sit-2026-10-17`.

---

## Step 2 — Build the fake bank network: `mimic_vpc` (laptop · ~free · ~3 min)

**Why:** in the bank, the cloud team hands us a VPC. Here we impersonate it. It has **no
internet** on purpose — the platform must work without it. Its "hand-over" file is how the
platform learns the VPC and subnet IDs (never by reading the mimic's state).

```bash
cd $REPO/mimic_vpc/terraform
terraform init                                    # already points at besu/sit/network.tfstate
terraform plan -var-file=environments/sit/primary.tfvars -out=$SP/mvpc.plan
#   read the last line: expect ~347 to add, 0 to change, 0 to destroy
terraform apply $SP/mvpc.plan
cd .. && ./scripts/verify-contract.sh && ./scripts/emit-handover.sh
```

**Should see:** apply complete; `verify-contract.sh` → **27 passed**; `emit-handover.sh` writes
`network-handover.auto.tfvars`.
**Why `-out`:** you apply exactly the plan you read, not a fresh one that might differ.
**What the two scripts do:**

- **`verify-contract.sh` — "is the network really what we were promised?"** Read-only. It
  asks the **live AWS API** (not Terraform's state file — state can be stale; the platform will
  meet reality) whether the VPC meets the requirements the platform depends on, e.g. #1
  default tenancy, #2 DNS support + hostnames on, #4 the `internal-elb` tag on the 3 LB
  subnets, #5 subnets in exactly 3 AZs, #12 **no `0.0.0.0/0` route anywhere** (no internet),
  #17 the secondary CG-NAT CIDR attached but unused. Each check cites its requirement number,
  so a failure can be quoted straight back to the cloud team. With the real bank, you'd run
  this against *their* VPC on day one.
- **`emit-handover.sh` — "write down the network's IDs for the platform."** Reads the mimic's
  Terraform outputs and writes `mimic_vpc/network-handover.auto.tfvars` (VPC ID, subnet IDs per
  AZ, route tables, NACLs…). It copies that into `sbsa_besu/terraform/` and symlinks it into
  the `shared`, `chain` and `app` roots, so all three read one identical file. **Why a file
  and not Terraform state:** the bank's cloud team will never give us their state — they'll
  send a list of IDs. This file *is* that list, so the platform is built exactly as it will
  be at go-live. It writes to a temp file first and only replaces the old one if every value
  was read (B19 — a half-written hand-over once pointed at a deleted VPC).

**The `.plan` file looks like gibberish — that's normal.** It's a binary zip for Terraform, not
for people. Read it with `terraform show $SP/mvpc.plan` (full list) or
`terraform show -no-color $SP/mvpc.plan | grep '^Plan:'` (just the count — `-no-color` is
needed, or the colour codes in front of `Plan:` stop `grep` matching and you get nothing).

> **🏦 In the bank — this step disappears too.** The cloud team builds the VPC and sends a
> list of IDs. You type them into `sbsa_besu/terraform/network-handover.auto.tfvars` (same
> shape as the emitted one) and run `verify-contract.sh <vpc-id> af-south-1` against *their*
> VPC — it is read-only and works on any VPC.

**Tell Claude:** the plan count, the new `vpc-…` ID, the verify result.

---

## Step 3 — Build the fake bank proxy: `mimic_egress` (laptop · ~$0.03/h · ~3 min)

**Why:** the runner must reach Octopus Cloud, and in the bank the only way out is the bank's
proxy, which allows just two Octopus hostnames. This builds a copy of that proxy.

**The `cp` line is the lesson of 10-11:** `mimic_egress` keeps its own copy of the network
hand-over. Skip it and the proxy tries to peer with *last week's* deleted VPC.

```bash
cd $REPO/mimic_egress
cp ../mimic_vpc/network-handover.auto.tfvars terraform/      # TODAY's VPC — don't skip
cd terraform
terraform init
terraform plan -var-file=environments/sit/primary.tfvars -out=$SP/egress.plan
terraform show -no-color $SP/egress.plan | grep -E '^Plan:|vpc-0574f5d1fd5c5766a' | head -5
#   ↑ STOP here and check: "Plan: 29 to add, 0 to change, 0 to destroy."
#     and at least one line with TODAY's VPC ID (Step 2). Then:
terraform apply $SP/egress.plan
cd .. && ./scripts/emit-handover.sh
```

**Should see:** the plan line `29 to add`, at least one line naming **today's** VPC
(`vpc-0574f5d1fd5c5766a`) — proof it will peer with the right network — then 29 added and the
egress hand-over written.

**Check it yourself (read-only, free)** — the IDs come from the apply's `Outputs:` block
(or `terraform output` in `mimic_egress/terraform`):

```bash
# the peering between the ledger VPC and the proxy VPC → expect: active
aws ec2 describe-vpc-peering-connections --region af-south-1 \
  --vpc-peering-connection-ids pcx-00f0e3594a9bf88cc \
  --query 'VpcPeeringConnections[0].Status.Code' --output text
# the Squid proxy instance → expect: running
aws ec2 describe-instances --region af-south-1 --instance-ids i-0b8edfea435d1f27d \
  --query 'Reservations[0].Instances[0].State.Name' --output text
```

"Apply complete" means AWS accepted the requests; these two ask AWS what the things *are now*.
A peering can sit in `pending-acceptance` or `failed`, and an instance can still be `pending`.

> **🏦 In the bank — this step disappears, and becomes a ticket.** The bank already has a
> shared egress proxy; we never build one. Instead we raise **R-10**
> (`CLOUD_TEAM_FOLLOWUP_2026-09-09.md` §5), six lines: (1) the proxy `host:port`; (2) allow
> **source** = the runner's fixed IP (/32); (3) allow **destinations** `<instance>.octopus.app`
> and `polling.<instance>.octopus.app`, port 443, `CONNECT` only; (4) **no TLS decryption** on
> those two; (5) a route from the **ledger** route tables to the proxy; (6) whether it needs
> credentials. Their reply is typed by hand into `sbsa_besu/terraform/egress-handover.auto.tfvars`
> — the same file `emit-handover.sh` just wrote. Everything after this step is identical.
>
> **So yes — Octopus comes first, but only its *name*.** The ticket must name the two Octopus
> hostnames, so the bank's Octopus Cloud instance must exist (and its name be known) before
> R-10 is raised. The rest of the Octopus setup (space, worker pool, projects — RUNBOOK E.3
> steps 1–4) can happen any time before Step 5. Here that was all done on 2026-10-10 and
> persists, which is why today starts at the network: `octopus_instance` in
> `mimic_egress/.../primary.tfvars` is that name. Likewise the runner's IP (`10.60.0.250`)
> must be agreed with the network team and **reserved** in the subnet (B43) before the ticket,
> because the proxy allowlists exactly that address.

---

## Step 4 — Send the runner its config: `push-deploy-config.sh` (laptop · free)

**Why:** the runner gets its code from a git bundle, but the tfvars and the two hand-overs are
gitignored (they hold environment details). This puts them in a Secrets Manager secret that
Octopus and the runner read. It must run **after** Steps 2–3, or it ships yesterday's VPC.

```bash
cd $REPO/sbsa_besu
ENV=sit AWS_REGION=af-south-1 scripts/runner/push-deploy-config.sh sbsa-besu-sit-octopus-deploy-config
```

**Should see:** a line saying **4 file(s)** (common.tfvars, chain.tfvars, two hand-overs).

**Check what's actually inside the secret (read-only)** — unpack it to a temp folder, print only
the four lines that must be today's, delete the copy (the tfvars can hold sensitive values):

```bash
D=$(mktemp -d)
aws secretsmanager get-secret-value --region af-south-1 --secret-id sbsa-besu-sit-octopus-deploy-config \
  --query SecretString --output text | base64 -d | tar xzf - -C $D
grep -rhE '^(vpc_id|deletion_group|egress_proxy_host|egress_allowed_source) ' $D
rm -rf $D
#   → today's vpc-…, sbsa-sit-2026-10-17, proxy.egress.mimic.internal, 10.60.0.250/32
```

---

## Step 5 — Build the AWS layer from Octopus: release `besu-infra` (GitHub · 💰 billing starts · ~25 min)

**Why:** this is the real production path — GitHub Actions packages the code, Octopus deploys
it. Octopus runs four steps: `shared` (VPC endpoints, so private subnets can reach AWS
services) → `chain` (EKS cluster + 4 nodes, keys, buckets) → runner bundle → `runner` (the
EC2 box inside the VPC — the only machine that can reach the private cluster).

1. GitHub → **Actions** → **release** → **Run workflow**
2. Branch: `shared-eks-namespace` · project: **`besu-infra`** → Run
3. Watch it in GitHub (it waits for Octopus) and in Octopus → Tasks.

**Should see:** GitHub run green, Octopus task green with all four steps. Note the run number
and `ServerTasks-…`.

**Tell Claude:** the start time, the run number, the task ID — and the error text if anything is red.

**Reading the task from the terminal (read-only)** — the deployment URL ends in `Deployments-NN`:

```bash
K="$(aws secretsmanager get-secret-value --region af-south-1 --secret-id sbsa-besu-octopus-terraform-key --query SecretString --output text)"
U=https://avishkarabhishek786.octopus.app/api/Spaces-1
T=$(curl -s -H "X-Octopus-ApiKey: $K" $U/deployments/Deployments-81 | jq -r .TaskId); echo $T
curl -s -H "X-Octopus-ApiKey: $K" "$U/tasks/$T/details?verbose=false" \
  | jq -r '.ActivityLogs[0].Children[] | "\(.Name)\t\(.Status)\t\(.Started)\t\(.Ended)"'     # each step
curl -s -H "X-Octopus-ApiKey: $K" $U/tasks/$T/raw | grep -E 'Plan: [0-9]|Apply complete'     # the counts
unset K
```

> **🏦 In the bank — Step 5 shrinks a lot, but doesn't disappear.** Today's run builds the
> endpoints and an EKS cluster **because there's no bank to provide them** — it's the stand-in.
> In the bank (CT-5, and the shared-node-group trial from 2026-10-16):
>
> | Octopus step | Today (mock) | In the bank |
> |---|---|---|
> | `terraform: shared` | 15 interface endpoints × 3 AZ + DNS zone (27) | **~nothing.** Their VPC already has the endpoints (AWS allows only one private-DNS endpoint per service per VPC, so ours would be useless). Already a setting: `central_interface_endpoints = true`, `gateway_endpoints_exist = true` (CD-39). We **verify** theirs instead: `verify-endpoints.sh` from the runner |
> | `terraform: chain` | EKS cluster, node group, node/cluster IAM roles, EBS CSI add-on, our admin access entry **+** everything below | **Only the things that are ours, not the cluster's:** KMS key for validator keys (C12), Secrets Manager (validator/bootnode keys, TLS, JWT), our IRSA roles (bound to *their* cluster's OIDC provider), the IAM permissions boundary, the runner-artifacts bucket, alarms/SNS. The cluster, node group, add-ons (LBC, CSI driver, Prometheus, Fluent Bit) and our access entry are **theirs** (D-23, D-24, #32) — we **assert** them (`modules/cluster-contract`, `verify-cluster.sh`) instead of building them |
> | runner bundle + `runner` | as today | **as today** — the runner is ours in every model |
>
> **The honest status:** the `chain` root has **not been split yet** — it still builds its own
> cluster unconditionally. The pieces for the bank shape exist (`contract/eks-handover.tf` for
> the cluster's IDs as a hand-over file, `modules/cluster-contract`, the preflights, and
> `mimic_eks` to impersonate their cluster), but nothing wires them into `chain` yet. That
> split was waiting for the cloud team's answers (`CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md`
> §4); the trial is where it gets done. Today's run is still valid practice: the order,
> Octopus, the runner, the Tentacle and `besu-workloads` are all identical in the bank.
>
> **Which questions decide the split** — point numbers in `Discussion with Cloud team on
> resources.md` (the `#` / `R-` numbers are the requirements document's):
>
> | Root | What the answer changes | Point (req) | Question in point 22 |
> |---|---|---|---|
> | `shared` | Endpoints exist, with Private DNS on → we create none | **18** (R-6) | command **5**; **J** (`eks-auth`) |
> | `shared` | Endpoint/S3 policies let image pulls through | **17** (#20, #22, #23) | — |
> | `shared` | VPC DNS settings | **14** (#1–#3) | — |
> | `chain` | **The cluster itself**: name, private endpoint, CA → `eks-handover.auto.tfvars`; `modules/eks` removed | **6** (#32) | command **1**; **H** |
> | `chain` | Node group: taint + label our pods must carry; 4 nodes / 3 AZs | **3** (#28), **15** (#5) | command **1** (`describe-nodegroup`) |
> | `chain` | **Which of our 4 add-on Helm releases go** (LBC, Secrets Store CSI, Prometheus, Fluent Bit) and the StorageClass | **4** (#30) | command **2**; **I** |
> | `chain` | IRSA roles stay ours but trust **their** OIDC provider — or switch to Pod Identity | **5** (#31) | command **1** (OIDC issuer); **H**, **J** |
> | `chain` | Node SG rule for our NLBs, node role ARN | **7** (#33) | command **3**; **D** |
> | `chain` | ECR pulls as **their** node role | **12** (#38) | — |
> | `chain` | Version gate in `cluster-contract` | **10** (#36) | command **1**; **F** |
> | `chain` | Namespace, Pod Security, quota (what `besu-workloads` lands in) | **2** (#27) | command **2**; **A**, **K** |
> | `chain` | What we may still create beside the cluster: KMS keys, IAM roles (boundary? SCPs?) | **20** (R-3) | — |
> | `runner` | Cluster access entry, namespace-scoped (was our admin entry) | **6** (#32) | **H** |
> | `runner` | Egress (R-10), its pinned IP reserved, its subnet | **20** (R-10), **13** (#39) | command **4** |
> | `runner` | Runner → API server and → proxy flows | **8** (#34: F-7, F-8) | command **3**; **C** |
>
> **In short: point 22's commands 1, 2 and 5 decide the split** — they're the "command outputs"
> the RUNBOOK says decide which files are deleted versus made conditional. Point **6** is the
> one the `chain` rewrite can't start without (no cluster name/endpoint, no hand-over).

---

## Step 6 — Check the runner booted correctly (laptop · read-only)

**Why:** the runner has no internet, so everything it needs comes from S3 at boot. If that
failed, every later step fails confusingly. One check now saves that.

```bash
cd $REPO/sbsa_besu/terraform/runner
export RUNNER=$(terraform output -raw runner_instance_id); echo $RUNNER
CMD=$(aws ssm send-command --region af-south-1 --instance-ids $RUNNER --document-name AWS-RunShellScript \
  --parameters 'commands=["cloud-init status; cat /opt/besu-deploy/BOOTSTRAP_STATUS"]' \
  --query Command.CommandId --output text)
sleep 5; aws ssm get-command-invocation --region af-south-1 --command-id $CMD --instance-id $RUNNER \
  --query StandardOutputContent --output text
```

**Should see:** `status: done` and `OK: tools=5 source=… deploy-config: extracted`.

> **`terraform output` errors or prints nothing?** The laptop's `runner` folder must be
> initialised on the af-south-1 bucket (B49). Fallback — find the runner by its pinned IP:
> `export RUNNER=$(aws ec2 describe-instances --region af-south-1 --filters Name=private-ip-address,Values=10.60.0.250 Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text)`

---

## Step 7 — Measure Octopus's certificate fingerprint (laptop · free)

**Why:** the Tentacle install checks that the proxy does **not** decrypt and re-sign traffic
(the bank promised no TLS inspection). It compares the cert it sees *through* the proxy with
the one you see *directly*. So you need the real value — on 10-11 a placeholder was pasted
instead and the install refused (correctly).

```bash
H=polling.avishkarabhishek786.octopus.app
FP=$(openssl s_client -connect $H:443 -servername $H </dev/null 2>/dev/null \
     | openssl x509 -fingerprint -sha256 -noout | cut -d= -f2); echo $FP
# print the Step 8 command with the value already inside — copy THIS output into the runner session
cat <<EOF
sudo env OCTOPUS_INSTANCE=avishkarabhishek786 OCTOPUS_SPACE='Default' OCTOPUS_WORKER_POOL=besu-runner-sit \\
  OCTOPUS_API_KEY_SECRET=sbsa-besu-primary-octopus-register-key \\
  EXPECTED_POLLING_CERT_SHA256='$FP' \\
  TENTACLE_CERT_SECRET=sbsa-besu-primary-tentacle-cert \\
  bash /opt/besu-deploy/sbsa_besu/scripts/runner/install-tentacle.sh
EOF
```

**Should see:** a long `AA:BB:…` value (32 pairs), then the ready-made Step 8 command with that
value in it. If `$FP` came out **empty**, the printed command has `''` — don't use it; the
`openssl` call failed (network?), run it again.

**Why print the command instead of copying the value:** the runner session can't see your
laptop's `$FP`, so the value has to travel by copy-paste. A placeholder to fill in by hand
got pasted unfilled twice (10-11 and 10-17); a value written into the docs goes stale when
Octopus rotates its certificate. Printing the finished command removes both.

---

## Step 8 — Make the runner an Octopus worker: `install-tentacle.sh` (runner over SSM · free)

**Why:** `besu-workloads` runs *on the runner* (only it can reach the cluster). For that,
Octopus must be able to send it work. The Tentacle **polls out** through the proxy — nothing
connects in. The script first re-runs 7 network probes and refuses if any fail.

```bash
aws ssm start-session --target $RUNNER --region af-south-1
```

Then, **in that session**, paste **the command Step 7 printed**. For the record, on 2026-10-17
it was this — don't reuse it on another day without re-running Step 7, the certificate rotates:

```bash
sudo env OCTOPUS_INSTANCE=avishkarabhishek786 OCTOPUS_SPACE='Default' OCTOPUS_WORKER_POOL=besu-runner-sit \
  OCTOPUS_API_KEY_SECRET=sbsa-besu-primary-octopus-register-key \
  EXPECTED_POLLING_CERT_SHA256='9B:A5:3F:3C:2C:8D:59:0B:83:CD:C1:6E:5E:6B:BE:FF:5D:BB:51:A4:68:4C:7E:53:DD:A3:EB:B5:BC:54:F3:78' \
  TENTACLE_CERT_SECRET=sbsa-besu-primary-tentacle-cert \
  bash /opt/besu-deploy/sbsa_besu/scripts/runner/install-tentacle.sh
```

Then type `exit` on its own **after** reading the output.

> **If probe 7 FAILS:** compare the two values it prints. *Through the proxy* = what the runner
> sees; *baseline* = what you passed. If the baseline is a placeholder or a typo, nothing is
> wrong with the network — fix the value and re-run (the script is idempotent). Only if the
> through-proxy value differs from what your laptop measured directly is the proxy decrypting.

Then in Octopus: **Infrastructure → Workers →** the worker (`ip-10-60-0-250`) **→ Check health**.

**Should see:** 7/7 probes PASS, `Machine registered successfully`, and the worker **Healthy**
(a warning about an "old version of Tentacle" is expected — it's our pinned version).

---

## Step 9 — Install the chain: release `besu-workloads` (GitHub → runner · ~5–10 min)

**Why:** this installs everything *inside* the cluster — secrets driver, load-balancer
controller, monitoring, genesis, 4 validators, bootnodes, RPC nodes and Blockscout — all
pulled from our private ECR mirror (no internet). Two gates protect it: **CD-53** (this step
may only change in-cluster things) and **CD-5** (it may never update or delete a running
validator — that is the separate rolling procedure).

1. GitHub → **Actions** → **release** → **Run workflow** → `shared-eks-namespace`, project **`besu-workloads`**.

**Should see in the Octopus task log:**
- smoke step ✅ (nodes, canary pod, DNS)
- `Plan: 19 to add, 0 to change, 0 to destroy` → CD-53 ✅ → CD-5 ✅ → `Apply complete!`
- `verify-deployed.sh`: ✅ 4/4 validators Ready, ✅ 4 distinct nodes

> ⚠️ **Expected red:** `verify-deployed.sh` reports **#33 FAIL** (our mock cluster has no
> security-groups-for-pods; the bank's cluster answers that one). So the step shows **Failed
> even though the install succeeded**. Known since 10-11 — check the lines above it, and if
> those are as listed, carry on.

---

## Step 10 — Open a tunnel to the chain (laptop + runner · free)

**Why:** nothing in the cluster is public. Path: your laptop → SSM → runner →
`kubectl port-forward` → the service. The runner side is started with `send-command` (as
root, auto-restarting) because hand-typed forwards died twice on 10-11. Port **4000** is
required: Blockscout's frontend is built to call `localhost:4000`.

**10a — runner side (once):**

```bash
export RUNNER=i-0979df9c625927651            # today's runner (Step 5/6)
: "${RUNNER:?RUNNER is empty — export it first}"   # guard: stops here instead of sending to nobody
aws ssm send-command --region af-south-1 --instance-ids $RUNNER --document-name AWS-RunShellScript \
  --parameters 'commands=["export PATH=/usr/local/besu-tools/bin:$PATH KUBECONFIG=/root/kc-pf",
    "aws eks update-kubeconfig --name sbsa-besu-primary-eks --region af-south-1 --kubeconfig $KUBECONFIG",
    "setsid nohup bash -c \"while true; do kubectl -n besu port-forward svc/blockscout-proxy 4000:80; sleep 1; done\" >/tmp/pf-4000.log 2>&1 </dev/null &",
    "setsid nohup bash -c \"while true; do kubectl -n besu port-forward svc/besu-explorer-rpc-1-rpc 8545:8545; sleep 1; done\" >/tmp/pf-8545.log 2>&1 </dev/null &"]'
```

**10b — laptop side: two new terminals, leave both open** (re-export `RUNNER` in each):

```bash
aws ssm start-session --target $RUNNER --region af-south-1 --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["4000"],"localPortNumber":["4000"]}'
```
```bash
aws ssm start-session --target $RUNNER --region af-south-1 --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8545"],"localPortNumber":["8545"]}'
```

**Check 10a actually reached the runner** — the JSON it prints must show
`"InstanceIds": ["i-…"]` and `"TargetCount": 1`. **`[]` / `0` means `$RUNNER` was empty:** AWS
accepts a command with no target and reports no error. Then confirm the forwards are listening:

```bash
C=$(aws ssm send-command --region af-south-1 --instance-ids $RUNNER --document-name AWS-RunShellScript \
  --parameters 'commands=["ss -ltnp | grep -E \":(4000|8545) \" || echo NO_LISTENERS"]' \
  --query Command.CommandId --output text)
sleep 5; aws ssm get-command-invocation --region af-south-1 --command-id $C --instance-id $RUNNER \
  --query StandardOutputContent --output text      # → two kubectl lines on 127.0.0.1:4000 and :8545
```

**Should see:** `Waiting for connections...` in both; http://localhost:4000 opens Blockscout.

---

## Step 11 — Send a transaction and find it in Blockscout (laptop · free)

**Why:** the end-to-end proof — a signed transaction accepted by the RPC node, agreed by the
4 validators in a block, and indexed by the explorer. The sender `0x9f7e…b248` was funded in
genesis (the only way to get funds on this chain — there is no faucet).

```bash
cast chain-id --rpc-url http://localhost:8545          # → 990001
cast block-number --rpc-url http://localhost:8545      # run twice; it should grow (a block every ~5 s)
TO=$(cast wallet new | awk '/Address/{print $2}'); echo $TO    # a throwaway recipient
read -rs PK                                             # paste the funded account's private key, Enter
cast send --rpc-url http://localhost:8545 --private-key "$PK" \
  --gas-price 0 --priority-gas-price 0 $TO --value 1ether
unset PK
cast balance $TO --rpc-url http://localhost:8545 --ether   # → 1.000000000000000000
```

Then search the `transactionHash` at http://localhost:4000.

**Why both gas flags:** `cast` sends EIP-1559 transactions; `--gas-price` alone sets only the
max fee, and the node refuses a priority fee above it.
**Don't be fooled:** Blockscout shows the sender's balance as 0 until it first appears in a
block — it doesn't import genesis balances. `cast balance` is the truth.

**Tell Claude:** the tx hash and block number. 🎉 That's the deployment. Now delete it all.

---

## Teardown — everything, same day, reverse order (laptop · ~45 min)

**Why reverse order:** each layer sits on the one before it. Deleting the VPC first would fail
(things still inside it) or orphan resources that keep billing.
**Why `plan -destroy -out` then `apply`:** you read the list of what will be deleted before
anything is deleted.

First, **Ctrl-C** the two port-forward terminals from Step 10.

### T1 — Forget the in-cluster layer (don't destroy it)

**Why:** your laptop can't reach the private cluster, so a destroy of Helm/Kubernetes
resources would hang forever. They disappear with the cluster anyway; we just remove them
from Terraform's memory. (`-d '\n'` matters: without it, names with quotes are silently skipped.)

```bash
cd $REPO/sbsa_besu/terraform/chain
terraform state list | grep -E '(^|\.)(helm_release|kubernetes_[a-z_]+)\.' \
  | xargs -d '\n' -r -n1 terraform state rm
terraform state list | grep -cE '(^|\.)(helm_release|kubernetes_[a-z_]+)\.'   # → 0
```
**Should see:** 19 removed, then `0`.

### T2 — Runner (expect 13 destroyed)

**Why first:** it reads the chain's state and has an access entry on the cluster.

```bash
cd $REPO/sbsa_besu/terraform/runner
terraform plan -destroy -var region=af-south-1 -var chain_state_bucket=besu-tfstate-867728055761-afs1 \
  -var chain_state_key=besu/sit/chain.tfstate -var chain_state_region=af-south-1 -out=$SP/runner-d.plan
terraform apply $SP/runner-d.plan
```

### T3 — Chain AWS layer (expect 106 destroyed · ~15 min)

```bash
cd $REPO/sbsa_besu/terraform/chain
terraform plan -destroy -var-file=../environments/sit/common.tfvars \
  -var-file=../environments/sit/chain.tfvars -out=$SP/chain-d.plan
terraform apply $SP/chain-d.plan
```

### T4 — Sweep what EKS left behind (look first, then delete)

**Why:** EKS and the storage driver create things Terraform never owned — network interfaces,
a security group, and the disks for Besu data and Blockscout's database. They block the VPC
delete and the disks bill. Only delete what these filters list.

```bash
C=sbsa-besu-primary-eks; DG=sbsa-sit-2026-10-17
aws ec2 describe-network-interfaces --region af-south-1 \
  --filters Name=tag:cluster.k8s.amazonaws.com/name,Values=$C Name=status,Values=available \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,Description]' --output text
#   each → aws ec2 delete-network-interface --region af-south-1 --network-interface-id <id>
aws ec2 describe-security-groups --region af-south-1 --filters Name=tag:aws:eks:cluster-name,Values=$C \
  --query 'SecurityGroups[].[GroupId,GroupName]' --output text
#   each → aws ec2 delete-security-group --region af-south-1 --group-id <id>
aws ec2 describe-volumes --region af-south-1 --filters Name=tag:DeletionGroup,Values=$DG \
  --query 'Volumes[].[VolumeId,State,Size]' --output text
#   each "available" → aws ec2 delete-volume --region af-south-1 --volume-id <id>
```
On 10-11 all three came back empty — that's fine too. Tell Claude what they listed.

### T5 — Shared endpoints (expect 27)

```bash
cd $REPO/sbsa_besu/terraform/shared
terraform plan -destroy -var-file=../environments/sit/common.tfvars -out=$SP/shared-d.plan
terraform apply $SP/shared-d.plan
```

### T6 — Proxy (expect 29)

```bash
cd $REPO/mimic_egress/terraform
terraform plan -destroy -var-file=environments/sit/primary.tfvars -out=$SP/egress-d.plan
terraform apply $SP/egress-d.plan
```

### T7 — Network (expect ~347, incl. the runner IP reservation)

```bash
cd $REPO/mimic_vpc/terraform
terraform plan -destroy -var-file=environments/sit/primary.tfvars -out=$SP/mvpc-d.plan
terraform apply $SP/mvpc-d.plan
```

### T8 — Zero-check (Claude, read-only)

**Why:** "destroy complete" only covers what Terraform knew about. Claude checks both regions
directly (VPCs, instances, EKS, ENIs, endpoints, load balancers, volumes, log groups…) and
writes the result below.

**Kept on purpose — not leftovers:** the four `sbsa-besu-*` Octopus secrets, the ECR mirror,
the Octopus space and `ci-trust`, the two state buckets. The worker will show **Unavailable**
in Octopus until the next run — expected.

---

## Appendix — the one-time steps we skipped today

Not part of today's run. They set up things that **persist between runs** (configuration,
trust, a registry), so they're done once and repeated only when something specific changes.
Each says **when** to run it. In a brand-new account, do them in this order **before Step 0**.

| # | What | Who | Run it when… |
|---|---|---|---|
| A1 | ECR push grant for CI (`mimic_registry`) | AWS admin, laptop | new AWS account, or the GitHub repo/branch allowed to push changes |
| A2 | Fill the mirror (`supply-chain.yml`) | GitHub Actions | first time in an account; **any** image, chart or version change; a new image found missing (like B44 on 10-11) |
| A3 | Octopus → AWS trust (`octopus/aws-trust`) | AWS admin, laptop | new AWS account, new Octopus instance, or a new environment (UAT/PROD) |
| A4 | Octopus Space-manager key | Octopus admin, UI | new space, or the key expired/rotated |
| A5 | The Octopus space as code (`octopus/terraform`) | laptop, Space-manager key | **any commit that changes `sbsa_besu/octopus/terraform/`** (new step, variable, project) |
| A6 | GitHub → Octopus trust (`octopus/ci-trust`) + GitHub variables | Octopus **administrator**, laptop + GitHub UI | new Octopus instance, or a new branch/environment CI may deploy |
| A7 | Tentacle registration secrets | laptop | new account, or the register key rotated |

> **🏦 In the bank:** A1–A2 are largely the cloud team's (central shared-services ECR, CD-27;
> who runs the mirror is Q-4d). A3 is the bank's AWS admin. A4–A6 are the bank's Octopus
> admin — handed the same code. A7 is ours.

### A1 — ECR push grant for CI (`mimic_registry`) · free

**Why:** GitHub Actions has internet but no AWS keys. This creates one IAM role it can assume
through **OIDC** (a short-lived token, nothing to leak), allowed only to push into
`mirror/*` — never delete, never change expiry.

```bash
cd $REPO/mimic_registry/terraform
cp environments/sit/registry.tfvars.example environments/sit/registry.tfvars   # first time only; fill in
terraform init -backend-config="bucket=besu-tfstate-867728055761" -backend-config="key=besu/sit/registry.tfstate" \
  -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
terraform plan -var-file=environments/sit/registry.tfvars -out=$SP/registry.plan
terraform apply $SP/registry.plan
terraform output
```

Then GitHub → repo **Settings → Secrets and variables → Actions**:
secrets `AWS_ECR_PUSH_ROLE_ARN` (`terraform output -raw ecr_push_role_arn`), `ECR_REGISTRY`
(`… ecr_registry`); variables `ECR_PREFIX` (`… ecr_prefix`), `AWS_REGION` = `af-south-1`.

### A2 — Fill the mirror (`supply-chain.yml`) · cents

**Why:** the VPC has no internet, so every image and Helm chart must already be in our ECR
before anything is deployed. A missing one doesn't error — **the pull hangs**. The list of
what to copy, pinned by digest, is `sbsa_besu/scripts/supply-chain/mirror.manifest`.
It copies with `crane`, which keeps digests identical (D-18); `docker pull/push` would not.

1. GitHub → **Actions → supply-chain → Run workflow**, branch `shared-eks-namespace`:
   - **`dry_run` ON** first — resolves and reports, copies nothing. Read the list.
   - then again with `dry_run` OFF. `scope`: `all` (first time), or `images-only` / `charts-only`.
   - **`create_repos` ON** only when a *new* image appears (first time, or like B44).
2. It also runs by itself on a push to `main` that changes `mirror.manifest`.
3. Re-running is safe: tags are immutable, so existing ones report "already present".

Check afterwards (read-only):
```bash
aws ecr describe-repositories --region af-south-1 --query 'length(repositories)' --output text
```

### A3 — Octopus → AWS trust (`octopus/aws-trust`) · ~$0.40/month

**Why:** Octopus must create AWS resources without anyone storing AWS keys in it. This makes
an OIDC provider for the Octopus instance and a deploy role per environment that **only**
`space:<s>:project:besu-infra:environment:<e>` can assume. Plus the empty
`sbsa-besu-sit-octopus-deploy-config` secret that Step 4 fills. **A human applies this, never
Octopus** — a deploy tool must not be able to edit its own trust.

```bash
cd $REPO/sbsa_besu/octopus/aws-trust
terraform init -backend-config="bucket=besu-tfstate-867728055761" -backend-config="key=besu/octopus/aws-trust.tfstate" \
  -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
terraform plan -var-file=environments/sit/aws-trust.tfvars -out=$SP/aws-trust.plan    # 5 resources on 10-10
terraform apply $SP/aws-trust.plan
```

### A4 — Octopus Space-manager key (Octopus UI)

**Why:** A5 changes Octopus through its API, so it needs a key. A service account
`besu-terraform` in a team with **Space manager** on the space; its API key with access level
**read-write** (a ReadOnly key plans fine, then every create fails — 10-10). Store it without
it ever touching the command line or shell history:

```bash
read -rs K && aws secretsmanager create-secret --region af-south-1 \
  --name sbsa-besu-octopus-terraform-key --secret-string "$K"; unset K
```

### A5 — The Octopus space as code (`octopus/terraform`) · free

**Why:** environments, lifecycle, the runner's worker pool, the AWS OIDC account, the
`Besu platform` variables and the three projects with their steps — all in code, so the bank
gets the same Octopus we tested. **Re-apply after any commit that touches
`sbsa_besu/octopus/terraform/`**, before the next release — otherwise Octopus runs the old steps.

```bash
cd $REPO/sbsa_besu/octopus/terraform
terraform init      # first time: -backend-config bucket=besu-tfstate-867728055761 key=besu/octopus/space.tfstate region=us-east-1
export OCTOPUS_APIKEY="$(aws secretsmanager get-secret-value --region af-south-1 \
  --secret-id sbsa-besu-octopus-terraform-key --query SecretString --output text)"
terraform plan -var-file=environments/sit/space.tfvars -out=$SP/space.plan            # read it
terraform apply $SP/space.plan
terraform plan -var-file=environments/sit/space.tfvars -detailed-exitcode             # exit 0 = in sync
unset OCTOPUS_APIKEY
```

**Quick "do I need A5?" check before any run:** the last command alone. Exit code `0` = Octopus
matches the code, skip A5; `2` = something differs, read the plan.

### A6 — GitHub → Octopus trust (`octopus/ci-trust`) + GitHub variables · free

**Why:** lets GitHub Actions create releases in Octopus via OIDC — **no Octopus key in
GitHub**. Creates the `besu-ci` service account, its GitHub identities (one per allowed
branch) and two narrow roles (publish; deploy to **SIT only**). Needs an Octopus
**administrator's** key, not A4's: a pipeline must not be able to edit its own permissions.

```bash
cd $REPO/sbsa_besu/octopus/ci-trust
terraform init      # first time: key=besu/octopus/ci-trust.tfstate, same bucket/region as A5
read -rs OCTOPUS_APIKEY && export OCTOPUS_APIKEY            # the ADMIN key, typed, not stored
terraform plan -var-file=environments/sit/ci-trust.tfvars -out=$SP/ci-trust.plan      # 8 objects on 10-10
terraform apply $SP/ci-trust.plan
terraform output service_account
unset OCTOPUS_APIKEY
```

Then GitHub → **Settings → Secrets and variables → Actions → Variables** (repository level):
`OCTOPUS_URL`, `OCTOPUS_SPACE`, `OCTOPUS_SERVICE_ACCOUNT_ID` (the GUID from the output).
Test: **Actions → release → project `none`** — packages and signs in, deploys nothing.

### A7 — Tentacle registration secrets · free

**Why:** `install-tentacle.sh` (Step 8) reads the registration key from Secrets Manager, never
from a file or command line, and saves the Tentacle's certificate so a rebuilt runner keeps
the same identity (CD-61). The key belongs to a service account in a team holding a
**Space-scoped role, team saved** (Environment manager is enough — CD-65).

```bash
read -rs K && aws secretsmanager create-secret --region af-south-1 \
  --name sbsa-besu-primary-octopus-register-key --secret-string "$K"; unset K
aws secretsmanager create-secret --region af-south-1 --name sbsa-besu-primary-tentacle-cert
#   ↑ NO --secret-string: created EMPTY on purpose. install-tentacle.sh generates a certificate
#     only when the secret has no value; any placeholder (even '{}') is taken as a stored
#     certificate and the import fails.
```

Before creating either, check neither name is stuck in its deletion window — such a secret is
invisible to a plain `list-secrets` but still blocks the name:
```bash
aws secretsmanager list-secrets --region af-south-1 --include-planned-deletion \
  --query 'SecretList[].[Name,DeletedDate]' --output text
```

---

## Log (Claude fills this in from what you report · times UTC)

| Time | Step | Who | Result |
|---|---|---|---|
| ~07:35 | 0 — setup + empty account | operator | ✅ account `867728055761`; af-south-1: no non-default VPCs, no EKS clusters — clean start |
| ~07:38 | 1 — deletion groups bumped | operator | ✅ `sbsa-net-sit-2026-10-17`, `sbsa-egress-sit-2026-10-17`, `sbsa-sit-2026-10-17` |
| ~07:45 | 2 — `mimic_vpc` plan → `$SP/mvpc.plan` | operator / Claude | ✅ **347 to add, 0 change, 0 destroy** (same as 10-11): 273 NACL rules, 15 subnets/RTs/NACLs, 2 gateway endpoints, 1 subnet CIDR reservation (runner /32, B43), flow log. VPC tagged `DeletionGroup = sbsa-net-sit-2026-10-17`. *(A saved plan is a binary zip — read it with `terraform show <file>`, not an editor.)* |
| ~07:50 | 2 — `mimic_vpc` apply + `verify-contract.sh` + `emit-handover.sh` | operator | ✅ **`vpc-0574f5d1fd5c5766a`**; contract **27 passed, 0 failed** against live AWS; hand-over emitted and linked into the platform roots |
| ~07:58 | 3 — `mimic_egress` plan → `$SP/egress.plan` (after `cp` of today's hand-over) | operator | ✅ **29 to add, 0 change, 0 destroy**; `peer_vpc_id` and the PHZ association both **`vpc-0574f5d1fd5c5766a`** = today's VPC — the 10-11 stale-hand-over failure cannot recur |
| 08:02 | 3 — `mimic_egress` apply + `emit-handover.sh` | operator | ✅ **29 added**. Proxy `i-0b8edfea435d1f27d` (running), `proxy.egress.mimic.internal:3128`, egress VPC `10.61.0.0/24`; peering `pcx-00f0e3594a9bf88cc` **active** (Claude, read-only); allowlist = the 2 Octopus hostnames only, source `10.60.0.250/32`. Egress hand-over placed in `sbsa_besu/terraform/` + linked into `runner/` |
| 08:08 | 4 — `push-deploy-config.sh` | operator | ✅ **4 file(s)** → `sbsa-besu-sit-octopus-deploy-config` (changed 08:08:10). Claude unpacked it read-only and checked: `vpc_id = vpc-0574f5d1fd5c5766a`, `deletion_group = sbsa-sit-2026-10-17`, proxy `proxy.egress.mimic.internal`, source `10.60.0.250/32` — all today's |
| 08:43 | 5 — `besu-infra` in progress (progress read from AWS by Claude, read-only) | Octopus | `shared` ✅ done (17 endpoints in the VPC = 15 interface + 2 gateway); `chain` running: EKS `sbsa-besu-primary-eks` **ACTIVE** (created 08:34), node group `sbsa-besu-primary-ng` **CREATING** since 08:42 (4 nodes); runner not yet created |
| 08:29 → 08:54:21 | 5 — `besu-infra` **2026.10.17.16** (GitHub run 39017470723, `Deployments-81`, **`ServerTasks-1641`**) | Octopus (hosted worker) | ✅ **Success, 25 min, first time — no fix cycles** (10-11 needed two releases). `shared` 08:29:34–08:32:45 **27 added**; `chain` 08:32:45–08:49:29 **106 added**; runner bundle 08:49:29–08:52:40; `runner` 08:52:40–08:54:20 **13 added** — same counts as 10-11. Runner `i-0979df9c625927651` running. 💰 billing clock from ≈ 08:30 |
| 09:03 | 6 — runner bootstrap check (SSM `send-command`) | operator (Claude confirmed) | ✅ `i-0979df9c625927651`: `status: done`; `OK: tools=5 source=2c80519/2026.10.17.16 deploy-config: extracted` — the runner has today's code (HEAD `2c80519`, release .16) and today's config |
| ~09:06 | 7 — Octopus polling cert, measured direct from the laptop | operator | ✅ `9B:A5:3F:3C:…:BC:54:F3:78` — **identical to 10-10/10-11** (same Octopus Cloud cert, not yet rotated) |
| 09:07:21 | 8 — `install-tentacle.sh` (1st) | operator | ❌ **refused, correctly.** Probes 1–6 PASS (proxy resolves to 10.61.0.50; both Octopus hosts allowed; `example.com`, plain HTTP and port 10943 all refused 403). Probe 7: through-proxy cert `9B:A5:…:F3:78` ≠ baseline **`<FP>`** — the literal placeholder from this file's Step 8, pasted as written. **Cause: Claude's instructions** — the value was filled in only in the chat message, not in the file; same slip as 10-11. Through-proxy = laptop-direct, so **no interception**. Nothing registered. File fixed: Step 8 now carries today's value + how to read a probe-7 failure |
| ~09:12 | 8 — `install-tentacle.sh` (2nd, real baseline) | operator | ✅ **7/7 probes**, registered. Same hostname `ip-10-60-0-250`, cert imported from `…-tentacle-cert` → existing **`Workers-1`** updated in place (no duplicate worker), pool `besu-runner-sit` |
| 09:13:36 | 8c — Octopus health check | operator | ✅ **Healthy / Online**: `Workers-1` at `poll://fyvbs6xcrdulw6y4jtb4/`, Tentacle 11.0.4398 (the manifest pin) |
| — | 💡 follow-up | Claude | `install-tentacle.sh`: refuse a non-fingerprint `EXPECTED_POLLING_CERT_SHA256` up front ("looks like a placeholder") — twice now probe 7 has blamed the proxy for a pasted placeholder. After today's run. Also fold the "print the ready-made command" form of Step 7 into RUNBOOK E.1 step 6/8 |
| ~09:20 | instructions — Step 7/8 | Claude | Step 7 now **prints the finished Step 8 command** with the measured value inside; Step 8 says "paste what Step 7 printed" and keeps today's value only as a labelled record. Neither a placeholder (pasted unfilled ×2) nor a hard-coded value (goes stale on rotation) |
| 09:20:12 → | 9 — `besu-workloads` **2026.10.17.17** (GitHub run 39020666231, `Deployments-82`, **`ServerTasks-1644`**) | Octopus (runner Tentacle) | in progress — read by Claude via the API at 09:23. **Smoke ✅** 09:20:55–09:21:24: 4 nodes Ready (v1.35.8, 10.60.0.30 / 1.137 / 2.149 / 2.248), **#38 canary: the cluster pulled `mirror/alpine/k8s@sha256:3ac15bcb…`**, C-2 DNS ✅. In-cluster step from 09:21:24: deploy-config extracted; **F19** RPC keystore/truststore/JWT issued 09:22:00–:10 (first time today); **`Plan: 19 to add, 0 to change, 0 to destroy`** 09:22:30 — as predicted; **CD-53 ✅** 09:22:29; **CD-5 ✅** 09:22:34; apply running |
| 09:22:34 → 09:25:06 | 9 — `ServerTasks-1644` result | Octopus | ✅ install / ❌ step (**expected**). **`Apply complete! Resources: 19 added, 0 changed, 0 destroyed`** 09:25:02: StorageClass, Secrets Store CSI + AWS provider, LBC (19 s), genesis, bootnodes ×2, **validators ×4**, RPC ×2, explorer-rpc, rpc-edge, Fluent Bit, **Blockscout first time (B52 fix proven live)**, kube-prometheus-stack (1m35s), besu-monitoring. `verify-deployed.sh`: **PASS 4/4 validators Ready, PASS 4 distinct nodes**; **FAIL #33** (0/3 RPC pods with `pod-eni` — mock cluster has no SGP; same as 10-11); WARN ×4 not evaluated (#31 no AWS CLI in image; no `-g`; no `-r` → chain-level skipped; netpol opt-in). Exit 1 → task Failed. **Whole chain in one release — 10-11 needed five** |
| 09:28 | 10a — port-forward `send-command` (1st) | operator | ❌ **sent to no instance**: `"InstanceIds": []`, `TargetCount 0` — `$RUNNER` empty in that terminal. AWS accepts it silently (status `Success`, 0 targets). Claude checked the runner: `NO_LISTENERS`. Nothing ran, nothing to undo. File fixed: Step 10a sets `RUNNER` and guards it (`${RUNNER:?}`), plus a listener check |
| 09:30:53 | 10a — port-forward `send-command` (2nd) | operator | ✅ `InstanceIds: [i-0979df9c625927651]`, status Success. Claude (read-only `ss`): `kubectl` listening on runner **127.0.0.1:4000** (pid 5036 → `svc/blockscout-proxy`) and **:8545** (pid 5037 → `svc/besu-explorer-rpc-1-rpc`) |
| ~09:35 | 10b — laptop `AWS-StartPortForwardingSession` ×2 (4000, 8545) | operator | ✅ both sessions up; tunnel laptop → SSM → runner → cluster working |
| ~09:40 | 11a — chain alive | operator / Claude | ✅ `cast chain-id` = **990001**; block **150** (via the tunnel). Claude, read-only `eth_getBalance` through the same tunnel: `0x9f7e…b248` holds `0x2000…0` — **genesis funding (F20) applied** |
| ~09:45 | 11b — which key? | operator / Claude | ⏸ operator unsure which private key to use. The sender must be `0x9f7e…b248`, the only `genesis_funded_accounts` entry. **Gap in Claude's instructions:** the address travels through the pipeline (`chain.tfvars` → Step 4 → genesis in Step 9) but the key never does, and the file never said where it comes from or to have it ready. Not in a Foundry keystore on the laptop. File fixed: a "Before you start" section on the sender key |
| ~09:50 | rule for practice runs | operator | **"Assume it's the very first deployment unless stated — no step skipped."** Today's file skipped the one-time steps (mirror, Octopus setup, sender key) as already done. To do after teardown: rewrite the file in first-time order — appendix A1–A7 and the sender key become numbered steps before Step 0, each saying what "already done" looks like on a re-run |
| 09:45 | decision: **teardown**, Step 11 transaction **not done** (sender key not to hand; adding a new sender means rebuilding the chain) | operator | Proven before teardown: chain-id 990001, blocks producing, genesis funding applied, Blockscout up, full Octopus → proxy → runner → cluster path |
| 09:45 | pre-teardown look (Claude, read-only) | Claude | NLB `sbsa-besu-primary-rpc-nlb` + TG `sbsa-besu-primary-rpc-tg` = **Terraform-owned** (`module.rpc_access`), go in T3. 11 EBS volumes tagged `sbsa-sit-2026-10-17`, all in-use (10 PVCs + runner root) → T4 after the nodes are gone. `chain` state: 125 managed = 106 AWS + 19 in-cluster |
| ~09:52 | T1 — `state rm` the in-cluster layer (`xargs -d '\n'`, F30) | operator | ✅ 19 removed, **0** left; Claude: `chain` state now **106** managed (AWS layer only), `runner` **13** |
| ~09:56 | T2 — `runner` destroy | operator | ✅ **13 destroyed** (same 13 as 10-11). Tentacle `Workers-1` now Unavailable in Octopus — expected |
| ~10:08 | T3 — `chain` AWS-layer destroy | operator | ✅ **106 destroyed** (same 106 as 09-17 / 10-09 / 10-11). Claude, 10:09: no EKS clusters; no leftover cluster ENIs or SGs (B34 sweep empty); only ENIs left in the VPC = 45 `vpc_endpoint` (`shared`, T5). **10 EBS volumes now `available`** with `DeletionGroup = sbsa-sit-2026-10-17` (9 × 100 GiB + 1 × 50 GiB — the PVCs; the 11th, the runner's root, went with T2) |
| ~10:11 | T4 — B34 sweep + PVC volumes | operator | ✅ ENIs: none; SGs: none; **10 volumes deleted**. Claude verified: **0** volumes left with `DeletionGroup = sbsa-sit-2026-10-17` |
| ~10:15 | T5 — `shared` destroy | operator | ✅ **27 destroyed** (15 interface endpoints, SG, PHZ…) — the platform's last billable piece |
| ~10:19 | T6 — `mimic_egress` destroy | operator | ✅ **29 destroyed** — proxy VPC, Squid, NLB, peering, routes, PHZ record |
| ~10:23 | T7 — `mimic_vpc` destroy | operator | ✅ **347 destroyed** = Step 2's 347, incl. the runner IP reservation (B43) — no hand-made `scr-` to clean up |
| 10:25 | T8 — zero-check | Claude | ✅ **CLEAN** — see below |

## Zero-check (10:25 UTC, Claude, read-only)

| Check | Result |
|---|---|
| Terraform state: `shared`, `chain`, `runner` (af-south-1 bucket), `network`, `egress` (us-east-1 bucket) | **0 managed resources each**; no `.tflock` objects |
| af-south-1 **and** us-east-1: non-default VPCs, instances, EKS, ENIs, VPC endpoints, load balancers, target groups, peerings, EIPs, NAT, EBS volumes, non-default SGs, log groups | **none** in either region |
| Route 53 hosted zones | none |
| KMS | no enabled customer keys; 6 customer keys in `PendingDeletion` (7-day window — today's + earlier runs); AWS-managed keys only otherwise |
| Secrets (kept on purpose) | `sbsa-besu-primary-octopus-register-key`, `…-tentacle-cert`, `sbsa-besu-sit-octopus-deploy-config`, `sbsa-besu-octopus-terraform-key` |
| Buckets (kept on purpose) | the two state buckets; two unrelated `tf-octopus-demo-*` from 2026-09-06. CloudTrail and runner-artifacts buckets gone |
| Also kept | ECR mirror (29 repos), the Octopus space + `ci-trust`, worker `Workers-1` (Unavailable until next `install-tentacle.sh`) |

## Cost and what was learned

**Cost:** the platform billed from ≈ 08:29 (`shared` apply) to ≈ 10:15 (`shared` destroyed) —
≈ 1¾ h at ≈ $2/h — plus the proxy 08:02–10:19 at ≈ $0.03/h: **≈ $4**. Cheaper than 10-11's
$8–9 (no fix cycles) and 10-10's $4.5.

**Outcome:** deployment ✅ to a producing chain with Blockscout; **transaction ❌ not sent**
(sender key not to hand — see below). Teardown and zero-check ✅ clean.

**What went right, compared with 10-11:**
- `besu-infra` green on the **first** release (10-11: two); `besu-workloads` installed the whole
  chain in **one** release (10-11: five). B49–B52 fixes all held live, incl. Blockscout (B52).
- The mimic-egress hand-over `cp` and the deploy-config ordering (10-11's sequencing slip) were
  in the steps and didn't recur.
- Every count matched the prediction: 347 / 29 / 27 / 106 / 13 / 19 up, the same down.

**What went wrong — all in the instructions, none in the platform:**

| # | What | Cause | Fixed in this file |
|---|---|---|---|
| 1 | `grep '^Plan:'` on a saved plan printed nothing | colour codes before `Plan:`; needs `-no-color` | Step 2/3 |
| 2 | `install-tentacle.sh` refused (probe 7) | **`<FP>` placeholder pasted unfilled** — the second time (10-11 too). The script blamed the proxy ("DECRYPTING") | Step 7 now *prints* the finished Step 8 command |
| 3 | Port-forward `send-command` ran on **no** instance | `$RUNNER` empty in that terminal; AWS accepts 0 targets as `Success` | Step 10: set + guard `${RUNNER:?}`, check `TargetCount`, listener check |
| 4 | No sender key at Step 11 | the key was never a step: only the *address* travels (tfvars → genesis), the key never does | "Before you start" section; to become a numbered step |
| 5 | One-time steps skipped as "already done" | instructions assumed a warm account | **Rule: practice = first-time deployment** (below) |
| 6 | A7 draft created the Tentacle cert secret with `'{}'` | would have been imported as a certificate and failed | caught before use; created empty |

**Open after today:**
- ~~Rewrite this file in first-time order~~ **Done → [`PRACTICE_DEPLOYMENT.md`](PRACTICE_DEPLOYMENT.md)**
  (reusable, first-time order: Part A A0–A9 incl. state buckets and the sender key; Part B B0–B10;
  T1–T8). This file stays as the record of 2026-10-17, with its own step numbers.
- `install-tentacle.sh`: refuse a baseline that isn't a fingerprint ("looks like a placeholder")
  instead of reporting decryption; fold the print-the-command form into RUNBOOK E.1/E.3.
- Carried from 10-11, still open: `verify-deployed.sh` **#33** FAIL on the mock (no SGP) and its
  four WARNs (step passes too few arguments); operator access as a script in `scripts/access/`.
- **The `chain` root split for the bank** (Step 5 🏦 box) — the first piece of trial work.

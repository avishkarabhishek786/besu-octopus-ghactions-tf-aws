# CLAUDE.md — `mimic_eks`: the cloud team's shared EKS cluster, impersonated

> **Throwaway fixture.** Delete this project when the real shared cluster exists.
> Produced for CT-5 / **D-32**; the design record is
> `../sbsa_besu/docs/CLOUD_TEAM_REDESIGN_NOTES.md` **§12**, and the requirements it
> reproduces are **§9.3 #27–#39** of `NETWORK_REQUIREMENTS_CLOUD_TEAM.md`.

---

> ## ⚠️ THIS PROJECT'S RULE IS THE OPPOSITE OF THE PLATFORM'S. DO NOT BLUR THEM.
>
> `../sbsa_besu/CLAUDE.md` prime directive 1 says **never create a cluster, node group,
> addon, CRD, StorageClass, webhook or any cluster-scoped Kubernetes kind** (D-23). Here
> you create all of them, because here you *are* the other team.
>
> That asymmetry is the whole protection. In production, the platform attempting to create
> a cluster fails on permissions; in a deploy-test against this mimic it would **silently
> succeed** and corrupt the fidelity of the exercise. If you find yourself moving code
> between the two projects, stop and check which brief governs the file.
>
> **Withdrawing an ask does not withdraw the reality.** We stopped asking for a cluster;
> we did not stop depending on one being configured correctly.

---

## 1. Why this exists — and the second reason is the real one

1. Somewhere to deploy the platform against under **namespace tenancy**, so CT-5 can be
   rehearsed before the bank's cluster exists.

2. **A cluster that breaks the platform's checks on purpose.**

   This is the reason the project is worth its cost. The platform now carries eleven
   Terraform gates (`modules/cluster-contract`) and four runner-side preflights, and
   every one of them was written against a cluster that does not exist yet. The
   programme has already been bitten three times by checks that could not fail:

   - **B12** — a preflight bug found only by running it against a deliberately broken
     synthetic VPC.
   - `verify-endpoints.sh` read `.PrivateDnsEnabled // "absent"`, and **jq's `//` treats
     `false` as empty** — so the single value the check existed to catch reported as
     "absent" and was skipped in silence (CICD §11.3).
   - `verify-cluster.sh`'s quota loop was `jq … | while read`, which puts the body in a
     **subshell**: every failure incremented a copy of the counter and the script exited
     **0** with the failures printed above it (§12.13.5).

   > **A check that cannot fail is worse than no check, because it is trusted.**
   > **Test fixtures for preflight scripts are built broken, not healthy.**

   So the **default profile is `hostile`**. The first time you point the platform at this
   mimic, it should fail in a dozen places, each citing a requirement number. **Seeing
   that is the deliverable.** A mimic that defaults to compliant is a mimic nobody ever
   runs in the mode that has value.

---

## 2. The two profiles

`profile = "hostile"` (default) or `"strict"`. Every knob can be overridden individually
(`null` = follow the profile), so you can break **exactly one** thing and confirm
**exactly one** gate fires — which is how you tell a gate that works from a gate that
happens to be downstream of another failure.

| Knob | hostile | strict | Gate it should trip |
|---|---|---|---|
| `endpoint_public_access` | **true** | false | `cluster-contract` **CG-2** (#32) |
| `kubernetes_version` | **1.37** | 1.36 | **CG-3** — the *ceiling*, not the floor (#36, D-41) |
| `provide_lbc` | **false** | true | **CG-7** (#30). The one add-on with no fallback |
| `psa_level` | **restricted** | baseline | **CG-8** (#27, D-33), and `verify-admission.sh` |
| `psa_cluster_wide` | false | false | Question K — set it to reproduce a namespace with **no** label whose enforcement is still `restricted`. Only a bare-Pod dry-run finds it |
| `node_group_dedicated` + `enable_network_policy` | **both false** | both true | **CG-9 — THE ISOLATION FLOOR** (#28 + #35) |
| `node_count` | **3** | 4 | D-39: the fourth validator stays `Pending` |
| `quota_cpu` | **6** | 8 | **D-36** — the most important fixture here. See below |
| `storage_binding_mode` | **Immediate** | WaitForFirstConsumer | `verify-cluster.sh` (#30) |
| `storage_allow_expansion` | **false** | true | `verify-cluster.sh` (#30) |
| `access_entry_cluster_wide` | **true** | false | `verify-cluster.sh` **negative** probes (#32, D-37) |
| `grant_custom_resource_rbac` | **false** | true | `auth can-i` on the four CRD kinds (#32) |
| `node_sg_allows_rpc` | **false** | true | `verify-deployed.sh` target health (#33) |

### The quota fixture is the one to understand

`quota_cpu = 6` admits **three** validators and refuses the fourth. QBFT with N=3F+1
needs 2F+1 = 3 of 4, so **the chain starts, produces blocks, and every dashboard is
green** — while sitting one failure away from a halt. The refusal is an event on the
StatefulSet; there is no fourth pod for anyone to notice the absence of.

That is why `verify-deployed.sh` asserts a **count** and never the absence of errors, and
why this fixture exists: to prove the count gate fires on the one failure that looks
exactly like success.

---

## 3. Layout and the chain of hand-overs

```
mimic_vpc  → network-handover.auto.tfvars ─┐
                                           ├→ mimic_eks → eks-handover.auto.tfvars → sbsa_besu
mimic_egress → egress-handover.auto.tfvars ┘
```

`mimic_eks` consumes the network hand-over exactly as the platform does, which makes it a
fidelity check on that file too: if a cluster cannot be built from it, the platform could
not have been either.

```
terraform/
  handover.tf   the network hand-over, consumed (all 19 variables mimic_vpc emits)
  variables.tf  what the cloud team would decide — and the profile
  main.tf       the cluster, the #28 node group, the #33 SG rule, the #32 access entry
  tenancy.tf    the namespace/quota/StorageClass/Role, rendered as YAML
  outputs.tf    the facts the cloud team would report, plus `deliberate_defects`
scripts/
  emit-handover.sh   → eks-handover.auto.tfvars (with the defect list as a comment)
  apply-tenancy.sh   → applies manifests/tenancy.yaml FROM THE RUNNER
  verify-contract.sh → producer-side assertion against live AWS
manifests/      generated, gitignored
```

**The cluster module is NOT copied here.** It is sourced in place from
`../sbsa_besu/terraform/modules/eks`. §12.6 says that directory moves here and is deleted
from the platform — but it has not moved, because `sbsa_besu/terraform/chain/main.tf:101`
still sources it and the CT-5 banner is explicit that **nothing is removed until §9.4 is
answered**. A copy would be a second source of truth and would drift. At cutover the
directory moves and only the `source` line changes.

---

## 4. Hard rules

1. **COST — this root creates a billable EKS control plane.** ~USD 0.10/hr plus nodes, in
   `af-south-1` (~31% above us-east-1). **Same-day teardown is mandatory**, exactly as for
   the platform's deploy-tests. `terraform destroy` here, then `mimic_egress`, then
   `mimic_vpc`.

2. **ADVISE-ONLY.** Never run `terraform apply` or `destroy` without the human asking.
   Tell them what to run.

3. **Never commit a hand-over file.** `*.auto.tfvars` and `manifests/` are gitignored. In
   production they carry bank-specific values (**CD-10**).

4. **The tenancy manifest must parse before it touches a cluster.** `apply-tenancy.sh`
   runs `kubectl apply --dry-run=client` first and refuses otherwise. The first version of
   `tenancy.tf` rendered **mis-indented pod-security labels** — invalid YAML whose
   `kubectl` parser error would have read like a platform problem. Found by parsing the
   rendered output with a YAML loader instead of reading it.

5. **Indentation is load-bearing in `tenancy.tf`.** Every interpolated block is built with
   **no** leading indentation; the template supplies the first line's indent literally and
   `indent(n, …)` supplies the rest — which is exactly what `indent` does, since it skips
   the first line by design.

6. **A `FAIL` from `verify-contract.sh` is a mimic bug.** The platform's gates are what
   should fail against a hostile cluster. This script asserts the mimic is what it
   *claims* to be; if it reports the hostile profile with **zero** deliberate defects
   observed, it exits 1, because a fixture that is not doing its job is worse than none.

---

## 5. The sequence

```bash
# 0. the network must exist first
cd ../mimic_vpc  && terraform apply && scripts/emit-handover.sh

# 1. the cluster — HOSTILE by default, which is the point
cd ../mimic_eks/terraform
terraform init && terraform plan           # read the plan; it bills by the hour
terraform apply                            # human decision, not Claude's
cd .. && scripts/verify-contract.sh        # the mimic is what it claims

# 2. the namespace the cloud team would have allotted us — FROM THE RUNNER
scripts/apply-tenancy.sh

# 3. hand it over
scripts/emit-handover.sh                   # writes the defect list into the file

# 4. NOW PROVE THE PLATFORM'S GATES FIRE. This is the deliverable.
cd ../sbsa_besu
scripts/preflight/verify-cluster.sh   -n besu-ledger -s gp3-immediate
scripts/preflight/verify-admission.sh -n besu-ledger -f <rendered chart>
#   Expect failures citing #27, #30, #32, #35, #36. A PASS is a bug in the check.

# 5. then the compliant run
cd ../mimic_eks/terraform && terraform apply -var profile=strict

# 6. TEAR DOWN THE SAME DAY
terraform destroy
```

---

## 6. What this mimic cannot reproduce

Said plainly, so a pass is never read as proof of something it did not test.

- **Cluster-wide Pod Security** via the API server's `AdmissionConfiguration`. A managed
  control plane does not expose it. `psa_cluster_wide` removes the namespace *label*,
  which reproduces the **information gap** that `verify-admission.sh` exists to close —
  not the enforcement itself.
- **EKS Pod Identity.** This mimic always uses IRSA. Flip `pod_identity` in the hand-over
  by hand to exercise that branch of the platform, and remember it makes the `eks-auth`
  VPC endpoint required (`verify-endpoints.sh --pod-identity`).
- **The real #33 grant.** The cloud team's rule would reference *our* NLB security groups.
  Those do not exist until the platform is deployed, and a fixture that cannot be applied
  before the platform is useless, so the mimic admits the VPC CIDR instead.
- **The cloud team's node-rotation tooling (#29).** There is nothing to configure: #29 is
  an operating agreement between people. The platform's answer is three alarms (D-42), not
  a gate, and this project cannot test it.

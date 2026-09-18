# CLAUDE.md — Phase 1: Shared VPC & Subnets (CLOUD-TEAM MIMIC)

> **Rename this file to `CLAUDE.md` in the root of the new Phase-1 project.**
> Suggested project name: `besu-network-mimic`.

You (Claude Code) are building the **network layer that the bank's cloud team will
provide in production**. This project exists so the platform build (Phase 2/3) can be
developed and deploy-tested against a network that behaves *exactly* like the real
hand-over. **Read this file fully at the start of every session.**

The authoritative specification for everything in this project is
**`NETWORK_REQUIREMENTS_CLOUD_TEAM.md`** (carried over from the `besu-aws` repo).
Every requirement numbered there maps to a resource or attribute here. If the two
ever disagree, the requirements document wins — raise it with the human rather than
silently diverging.

---

## 0. Prime directives (read first)

1. **FIDELITY OVER CONVENIENCE. This project impersonates another team.** Its only
   value is that Phase 2/3 cannot tell it apart from the real hand-over. Any
   convenience shortcut that the real cloud team would not provide is a **defect**,
   because it lets Phase 2/3 depend on something that will not exist in production.

2. **NEVER create an Internet Gateway, NAT Gateway, public subnet, Elastic IP, or
   any route to `0.0.0.0/0`.** This is a HARD RULE with no toggle, no
   `enable_egress` variable, and no "just for testing" exception. The entire point
   of the exercise is that the platform must work without egress. If something in
   Phase 2/3 cannot be built without internet, that is a **finding to fix in Phase
   2/3**, not a reason to add egress here. (See §7 for how images and code get in.)

3. **This project OWNS the network and NOTHING else.** No EKS, no EC2, no Helm, no
   Kubernetes provider, no workloads. If you are about to create a compute or
   application resource, stop — it belongs in Phase 2/3.

4. **The hand-over contract IS the deliverable** (§4). It is consumed by Phase 2/3
   as plain input variables — **never** via `terraform_remote_state`. The real cloud
   team will not grant state access, so neither does this project.

5. **DOCUMENT AS YOU BUILD.** Update `docs/network-handover.md` in the same session
   as any change. It must be complete enough that the human can hand it to the real
   cloud team as a build sheet, and console/CLI equivalents must be included.

6. **Ask before `terraform apply` / `destroy`.** Deployment work is **advise-only**:
   tell the human exactly what to run; do not execute unless explicitly asked.

7. **Cost.** This layer is nearly free (VPC, subnets, route tables, NACLs, DHCP
   options all cost nothing). The only billable items are **VPC Flow Logs** and, if
   enabled, IPAM. Keep flow-log retention short in deploy-tests. Same-day teardown
   still applies when the whole stack comes down.

---

## 1. What is being built, and why

A single shared VPC that hosts **two EKS clusters** — one for the Besu ledger, one
for the application estate — with **private subnets only** and **no internet egress**.

Settled context (do not re-litigate):

- **One VPC** for ledger + applications. The cloud team creates it; we consume it.
- **No public subnets, no IGW, therefore no NAT.** Egress, where it exists at all,
  is via a Transit Gateway the cloud team owns — out of scope for this project.
- **`/20` primary CIDR**, contiguous, ideally from a reserved `/18`. Sizing rationale
  is in the requirements document, Appendix A.
- **`100.64.0.0/16` secondary CIDR, associated but UNUSED.** Held in reserve so that
  a future move to VPC CNI custom networking is a config change rather than a rolling
  replacement of every node on a live ledger.
- **Three AZs**, addressed by **AZ ID** (`afs1-az1/2/3`), never by AZ name.
- **Region `af-south-1`** (Africa, Cape Town) for production. Deploy-tests run in
  `us-east-1` to avoid the opt-in and the regional premium — the topology is
  identical, only `az_ids` and rates differ.

---

## 2. Repository structure

```
terraform/
  versions.tf, backend.tf, variables.tf, main.tf, outputs.tf
  modules/
    vpc/          VPC, CIDR associations, DHCP options, flow logs
    subnets/      the 15 subnets, tags, route tables, NACLs
  environments/
    prod/         primary.tfvars      (af-south-1)
    test/         primary.tfvars      (us-east-1, deploy-tests)
scripts/
  emit-handover.sh      writes the Phase-2/3 tfvars fragment (§4)
  verify-contract.sh    re-asserts every requirement post-apply (§5)
docs/
  network-handover.md   the build sheet + console/CLI equivalents
```

Conventions:
- **Backend key:** `besu/<env>/network.tfstate` (`<env>` = dev | prod). This state is touched by nothing else.
- **Tag everything** via provider `default_tags`: `Project`, `Environment`,
  `ManagedBy`, `DeletionGroup`, `Owner`, `CostCenter`.
- **Comment heavily, explain the WHY**, matching the style of the `besu-aws` modules.
- **Nothing hardcoded.** CIDRs, AZ IDs, cluster names and tag values are all
  variables. Parameterise once, reference everywhere.

---

## 3. What to build

### 3.1 VPC

| Attribute | Value | Requirement |
|---|---|---|
| `cidr_block` | `var.vpc_cidr` — a `/20` | #7 |
| `instance_tenancy` | **`"default"`** — set it EXPLICITLY, do not rely on the provider default | #1 |
| `enable_dns_support` | `true` | #2 |
| `enable_dns_hostnames` | `true` | #2 |
| Secondary CIDR association | `100.64.0.0/16`, **no subnets created in it** | #17 |
| DHCP option set | `AmazonProvidedDNS` | #3 |
| Flow logs | VPC-level → CloudWatch, short retention in test | #14 |

Set `instance_tenancy` explicitly even though `"default"` is the provider default.
The value is **immutable after creation** and forced dedicated tenancy costs roughly
USD 1,460/month — it is worth one line of explicit, commented code.

### 3.2 Subnets — 15 total, one set per AZ

| Role | Count | Size | Usable | Purpose |
|---|---|---|---|---|
| `ledger` | 3 | `/24` | 251 | Besu cluster nodes + pods |
| `app` | 3 | `/23` | 507 | application cluster nodes + pods |
| `lb` | 3 | `/26` | 59 | internal NLBs / ALBs |
| `endpoint` | 3 | `/26` | 59 | interface endpoint ENIs |
| `data` | 3 | `/26` | 59 | managed databases, caches |

Allocates 2,880 of 4,096 addresses; **1,216 held in reserve** for a fourth AZ or an
extra tier. Derive every CIDR with `cidrsubnet()` from `var.vpc_cidr` — never write a
literal subnet CIDR.

**All subnets:** `map_public_ip_on_launch = false`.

**Endpoint subnets must be distinct from LB subnets** (#16) — endpoint ENIs must not
share a subnet with the NLB nodes they front, or the same-VPC PrivateLink path
between the application cluster and the ledger becomes unreliable.

### 3.3 Tags

- `kubernetes.io/role/internal-elb = 1` on the **`lb`** subnets (#4). Without this the
  AWS Load Balancer Controller cannot discover them, and the failure appears only when
  a Kubernetes Service is created — long after apply.
- Cluster-ownership tags for **both** clusters where required.
- `Name` tags encoding role and AZ ID, e.g. `<prefix>-ledger-afs1-az1`.

### 3.4 Route tables (#12)

**One route table per role per AZ** — 15 in total. Ledger route tables must be
distinct from application route tables so that a routing change made for an
application cannot alter the ledger's reachability.

**No route table may contain a default route.** The only routes are the `local`
routes for the primary and secondary CIDRs (added automatically), plus — in
production — the cloud team's Transit Gateway routes to on-premises destinations.
In the mimic there is no TGW, so `local` is all there is. (The container registry
needs no route at all: it is ECR, reached through VPC endpoints — CT-3a.)

### 3.5 NACLs (#13)

Create NACLs on the **ledger** subnets. Ship them with a permissive baseline
(allow-all in and out) and a prominent comment that **Phase 2/3 owns the rules**.
The mimic's job is to prove the resource exists and is addressable by ID; it is not
to guess the ruleset.

Export the NACL IDs in the hand-over contract.

### 3.6 Gateway endpoints (#10) — DECISION REQUIRED

Creating an S3 or DynamoDB gateway endpoint **adds a route to every route table it
associates with**, so ownership matters. Provide a variable
`gateway_endpoints_created_here` (default **`true`** for the mimic):

- `true` — this project creates the `s3` and `dynamodb` gateway endpoints and
  associates them to the ledger, app, lb and endpoint route tables. This mimics
  the cloud team accepting requirement #10 by creating them.
- `false` — they are not created here; Phase 2/3 creates them, which mimics the
  cloud team granting association permission instead.

Both are free. Exercise **both paths at least once**, because the real answer to #10
is not yet known and Phase 2/3 must work either way.

### 3.7 What this project must NOT create

Internet Gateway · NAT Gateway · Elastic IP · public subnet · any `0.0.0.0/0` route ·
**interface** VPC endpoints (Phase 2/3 owns those, per D-11) · Transit Gateway ·
EKS · EC2 · security groups (Phase 2/3 owns those, per #6) · anything Kubernetes.

---

## 4. The hand-over contract (§ THE deliverable)

Phase 2/3 consumes these as **plain input variables**. It must never read this
project's state — the real cloud team will not grant state access, and allowing it
here would let Phase 2/3 develop a dependency that cannot exist in production.

Terraform **outputs** to expose:

| Output | Type | Notes |
|---|---|---|
| `vpc_id` | string | |
| `vpc_cidr_primary` | string | the `/20` |
| `vpc_cidr_secondary` | string | `100.64.0.0/16`, associated and unused |
| `az_ids` | list(string) | e.g. `["afs1-az1","afs1-az2","afs1-az3"]` |
| `ledger_subnet_ids` | map(string) | keyed by **AZ ID** |
| `app_subnet_ids` | map(string) | keyed by AZ ID |
| `lb_subnet_ids` | map(string) | keyed by AZ ID |
| `endpoint_subnet_ids` | map(string) | keyed by AZ ID |
| `data_subnet_ids` | map(string) | keyed by AZ ID |
| `ledger_route_table_ids` | map(string) | needed for gateway endpoint association |
| `app_route_table_ids` | map(string) | |
| `lb_route_table_ids` | map(string) | |
| `endpoint_route_table_ids` | map(string) | |
| `ledger_nacl_ids` | map(string) | Phase 2/3 manages the rules |
| `gateway_endpoints_created_here` | bool | tells Phase 2/3 whether to create them |
| `dhcp_options_id` | string | |

Key the subnet maps by **AZ ID**, not by index or AZ name. AZ names map to different
physical zones in different accounts, and Phase 2/3 needs deterministic AZ placement
for QBFT validator spread.

**`scripts/emit-handover.sh`** must render these outputs into a
`network-handover.auto.tfvars` file for Phase 2/3 to drop in. This deliberately
mimics the real process — the cloud team sends a list of IDs, and the human pastes
them into tfvars.

---

## 5. `scripts/verify-contract.sh`

A read-only script that re-asserts every requirement **after** apply, against the
live AWS API rather than against state. It must check at minimum:

- VPC `instance_tenancy == "default"`
- `enableDnsSupport` and `enableDnsHostnames` both true
- secondary CIDR associated, and **no subnets in it**
- 15 subnets across exactly 3 distinct AZs, matched by AZ ID
- `kubernetes.io/role/internal-elb=1` present on all 3 `lb` subnets
- **no IGW attached, no NAT gateway, no `0.0.0.0/0` route in any route table**
- every subnet has `map_public_ip_on_launch = false`
- free-IP count per subnet above the expected floor
- DHCP option set resolves via AmazonProvidedDNS

Run it after every apply. It is the same class of preflight the `besu-aws` repo uses
for permissioning seeds: fail in seconds with an actionable message rather than
twenty minutes into a downstream apply.

---

## 6. Fidelity: what the mimic cannot reproduce

Be explicit with the human about these, and never paper over them:

| Real production | Mimic | Consequence |
|---|---|---|
| VPC may be **RAM-shared** from a network account | same account | Participant-account restrictions are NOT exercised — notably whether a VPC **endpoint service** can be created. This is open question Q-6 and it affects decision D-1 (retaining PrivateLink). |
| Transit Gateway to on-premises | absent | No route to on-prem DNS or to any on-premises system. See §7. |
| Central interface endpoints possibly shared via Route 53 PHZ | absent | Phase 2/3 always creates its own. Exercise the alternative only if Q-2 comes back positive. |
| Corporate DNS forwarding rules | AmazonProvidedDNS only | Conditional forwarding to corporate resolvers is not exercised. **Note this no longer touches the image supply chain** — ECR resolves through endpoint Private DNS, which the mimic DOES exercise faithfully. |
| Landing-zone SCPs and tag policies | absent | Tag-stripping and permission-boundary failures will not reproduce here. |

Optional toggle `simulate_central_endpoints` (default **false**) may create the
interface endpoints here instead of in Phase 2/3, to exercise the Q-2 path.

---

## 7. How images and code get in without egress

This is the question the no-egress rule always raises. **The answer is never to add
an IGW.**

- **Container images. FIDELITY GAP CLOSED 2026-09-04 (CT-3a).** Production now uses
  **private ECR** — reachable purely through the `ecr.api`, `ecr.dkr` and `s3`
  endpoints that Phase 2/3 creates anyway. What was the mimic's zero-egress *stand-in*
  is now the *real* production design, so on this axis the mimic is exactly faithful:
  no external registry, no TGW route, no private CA, no pull secret. Images are
  mirrored into ECR from outside the VPC; **pull-through cache cannot be used**, since
  its first pull needs an internet route (D-17).
- **Terraform providers.** The Phase-1 and Phase-2 **AWS layers** are applied from the
  human's laptop, which has internet — provider mirroring is not needed for them. It
  is needed only for the in-VPC runner that applies Kubernetes resources.
- **Source code for the runner.** Delivered as an **S3 bundle** through the S3
  gateway endpoint. As of D-21 this **is** the production arrangement, not an
  approximation — and the runner carries no package-manager dependency either.

If any of the above cannot be made to work, that is a **Phase 2/3 finding to fix** —
record it, tell the human, and leave this project's network pure.

---

## 8. Teardown

Phase 1 is destroyed **last**, after Phase 2/3 in the order app → chain → shared.

Before destroying, confirm zero leaked ENIs in the subnets. Load-balancer and
interface-endpoint ENIs routinely outlive their parent resource and will block
subnet deletion — and in production they consume the cloud team's scarce addresses,
making a leak a cross-team incident rather than a cleanup nuisance.

`terraform destroy` is sufficient here; there is no tag-keyed backstop, because this
project must never be given permission to sweep by tag in a VPC it may one day share.

---

## 9. Definition of done

Code written and commented · `terraform fmt` and `validate` pass · `plan` shown to
the human · `docs/network-handover.md` current · **`verify-contract.sh` passes
against a live apply** · `emit-handover.sh` produces a tfvars fragment that Phase 2/3
consumes without hand-editing · applied and torn down within the cost guardrail.

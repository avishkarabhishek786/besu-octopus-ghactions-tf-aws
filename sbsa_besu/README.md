# SBSA Besu platform

A closed, permissioned **Hyperledger Besu (QBFT)** network for a bank on AWS EKS,
whose only external consumer is **SWIFT**, reaching JSON-RPC over SWIFT's private
network. Provisioned with Terraform, deployed into a **namespace of a shared EKS
cluster the bank's cloud team runs**, inside a **VPC that team owns and hands over**.

> **Start with [`docs/RUNBOOK.md`](docs/RUNBOOK.md).** It carries the build order,
> the current state, and the failure modes.

## The projects (one repository since 2026-09-18)

| Directory | Role |
|---|---|
| `besu-aws` (beside this repository, not in it) | **Frozen. Reference only.** The pre-redesign build. Not modified. |
| `../mimic_vpc` | A throwaway mimic of the VPC the cloud team will hand over, so the contract can be tested for free. |
| `../mimic_egress` | A throwaway mimic of the bank's shared egress proxy, so the Octopus polling-Tentacle path can be tested before the real egress is wired. |
| `../mimic_eks` | **Built 2026-10-09** — a throwaway mimic of the shared EKS cluster and the namespace allotted to us (CT-5, D-32). Two profiles; the default is **hostile**, which breaks every gate in `modules/cluster-contract` and every runner preflight on purpose. Watch them fail before trusting them. |
| **`sbsa_besu`** (this) | The platform: ~~everything from EKS upwards~~ **everything inside our namespace, plus the AWS resources beside the cluster** (KMS, Secrets Manager, NLBs, IAM, SNS/SQS, S3, the runner). |

Why one repository, and how the "never create network resources" rule is
protected now that the mimics sit beside the platform: [`docs/RUNBOOK.md` §1](docs/RUNBOOK.md).

## What makes this build different

The cloud team has mandated five changes (**CT-1..CT-5**, see
[`docs/CLOUD_TEAM_REDESIGN_NOTES.md`](docs/CLOUD_TEAM_REDESIGN_NOTES.md) — CT-5 is §12):

1. **One VPC**, created by them, shared by the ledger and applications. This
   project **cannot create a VPC** — `modules/network` is deleted. Since 2026-09-21
   their VPC also has **role-separated subnets carrying rules they define** (CT-1a),
   so our traffic must pass rules we did not write.
2. **Private subnets only. No Internet Gateway, and no egress at all.**
3. **All container images from a private ECR registry**, never a public one.
4. ~~A VPC CIDR possibly smaller than /16 — settled at a /20 from a reserved /18.~~
   **Withdrawn (D-30).** The /20 was never granted and is no longer needed; we take
   addresses from their subnets. What remains is a headroom question, not an ask.
5. **We do not build EKS** (CT-5, 2026-09-21). A **shared cluster** exists and we are
   allotted a **namespace**; the cloud team runs the cluster and its maintenance.
   Everything cluster-scoped — node groups, addons, CRDs, StorageClasses, cluster RBAC
   — is theirs. **This is recorded from a verbal update and is not yet confirmed in
   writing**, so the code still builds a cluster; see
   [`CLAUDE.md`](CLAUDE.md)'s CT-5 banner and `PORTING.md` before changing anything.

The consequence of CT-5 that outranks the rest: **node maintenance is on their
schedule now.** QBFT tolerates exactly one validator being down, so a forced drain
of two can halt the ledger — which is why requirement #29 asks for an operating
agreement rather than a setting.

The consequence that shapes nearly every design decision:

> **With no egress, a missing VPC endpoint or an unmirrored image does not error.
> It hangs until timeout** — a stuck pod naming neither the service nor the
> registry. Everything here is arranged to make that discoverable *before* an
> apply, not during one.

Instead of creating a network, the platform **asserts** the one it is given.
[`terraform/modules/network-contract`](terraform/modules/network-contract) creates
nothing and enforces eight gates — VPC attributes, AZ placement, the
load-balancer discovery tag, absence of egress, free-IP capacity, service-CIDR
overlap, region portability, region agreement. Each failure message cites the
numbered requirement so it can be quoted back to the cloud team.

Under CT-5 four of those gates fall away (AZ placement, the discovery tag, capacity
and the service CIDR all concern subnets and a cluster that are no longer ours), and a
**`modules/cluster-contract`** joins it to assert the cluster the same way — version,
private endpoint, pod-identity mechanism, the add-on CRDs we depend on, the
StorageClass, our namespaces and their Pod Security level. The Kubernetes-side gates
run **from the in-VPC runner**, because the API endpoint is private.

## Layout

```
terraform/
  contract/      handover.tf — the input contract + the 8 gates (symlinked into each root)
  modules/       shared by every root
  environments/  common.tfvars + chain.tfvars, per environment
  shared/        VPC endpoints + private hosted zone   (apply FIRST)
  runner/        in-VPC SSM runner
  chain/         ledger cluster, Besu, access, observability, Blockscout
                 (CT-5: the cluster/node/addon half leaves; KMS, PKI, NLBs, IAM stay)
  app/           application cluster                   (not built yet; CT-5: a namespace, not a cluster)
helm/            charts + values
scripts/         preflight/, pki/, permissioning/, access/, maintenance/, validation/
docs/            see docs/README.md
```

**Apply order:** `shared` → `runner` → `chain` → `app`.
**Teardown order:** the reverse.

Each root has its own state; none may ever touch another's resources, and none
may read the cloud team's network state.

## Documentation

| Document | What it is |
|---|---|
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | **Start here.** Build order, current state, gotchas. |
| [PORTING.md](PORTING.md) | What is ported and what remains. |
| [docs/build-findings.md](docs/build-findings.md) | Defects found while porting (B1–B24). |
| [docs/README.md](docs/README.md) | Index of every design record. |
| [CLAUDE.md](CLAUDE.md) | Operating brief for Claude Code sessions. |

## Cost

Deploy-tests run against the real configuration with a **per-run cap and
mandatory same-day teardown**. Every cycle gets a row in
[`docs/test-run-log.md`](docs/test-run-log.md). Interface endpoints alone are
~$11/day, so nothing is left running overnight.

**CT-5 moves most of production's cost off our bill** — the EKS control planes, the
worker nodes and the interface endpoints become the cloud team's. Deploy-tests are
unchanged in kind, because the mimics still bill a cluster and nodes.

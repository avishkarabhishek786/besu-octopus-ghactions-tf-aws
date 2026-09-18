# SBSA Besu platform

A closed, permissioned **Hyperledger Besu (QBFT)** network for a bank on AWS EKS,
whose only external consumer is **SWIFT**, reaching JSON-RPC over SWIFT's private
network. Provisioned with Terraform, deployed into a **VPC the bank's cloud team
owns and hands over**.

> **Start with [`docs/RUNBOOK.md`](docs/RUNBOOK.md).** It carries the build order,
> the current state, and the failure modes.

## The three repositories

| Repo | Role |
|---|---|
| `besu-aws` | **Frozen. Reference only.** The pre-redesign build. Not modified. |
| `mimic_vpc` | A throwaway mimic of the VPC the cloud team will hand over, so the contract can be tested for free. |
| **`sbsa_besu`** (this) | The platform: everything from EKS upwards. |

## What makes this build different

The cloud team mandated four changes (**CT-1..CT-4**, see
[`docs/CLOUD_TEAM_REDESIGN_NOTES.md`](docs/CLOUD_TEAM_REDESIGN_NOTES.md)):

1. **One VPC**, created by them, shared by the ledger and applications. This
   project **cannot create a VPC** — `modules/network` is deleted.
2. **Private subnets only. No Internet Gateway, and no egress at all.**
3. **All container images from a private ECR registry**, never a public one.
4. A VPC CIDR possibly smaller than /16 — settled at a /20 from a reserved /18.

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

## Layout

```
terraform/
  contract/      handover.tf — the input contract + the 8 gates (symlinked into each root)
  modules/       shared by every root
  environments/  common.tfvars + chain.tfvars, per environment
  shared/        VPC endpoints + private hosted zone   (apply FIRST)
  runner/        in-VPC SSM runner
  chain/         ledger cluster, Besu, access, observability, Blockscout
  app/           application cluster                   (not built yet)
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
| [docs/build-findings.md](docs/build-findings.md) | Defects found while porting (B1–B15). |
| [docs/README.md](docs/README.md) | Index of every design record. |
| [CLAUDE.md](CLAUDE.md) | Operating brief for Claude Code sessions. |

## Cost

Deploy-tests run against the real configuration with a **per-run cap and
mandatory same-day teardown**. Every cycle gets a row in
[`docs/test-run-log.md`](docs/test-run-log.md). Interface endpoints alone are
~$11/day, so nothing is left running overnight.

# besu-octopus-ghactions-tf-aws

A permissioned **Hyperledger Besu (QBFT)** ledger for a bank on AWS EKS, in a VPC
the bank's cloud team owns, with no internet egress; built by GitHub Actions and
Octopus Deploy. One repository, three projects, since 2026-09-18.

> **CT-5 — 2026-09-21: the EKS cluster is not ours either.** The cloud team runs a
> **shared cluster** and allots us a **namespace**; their VPC has **role-separated
> subnets with rules they define**. Recorded from a verbal update, **not yet confirmed
> in writing**, so the code still builds a cluster. Design record:
> [`sbsa_besu/docs/CLOUD_TEAM_REDESIGN_NOTES.md` §12](sbsa_besu/docs/CLOUD_TEAM_REDESIGN_NOTES.md);
> the asks to the cloud team are #27–#39 in
> [`CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md`](sbsa_besu/docs/CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md).
> A fourth project, [`mimic_eks/`](mimic_eks/), was **built 2026-10-09** — and it is
> **hostile by default**: a cluster that breaks every gate the platform has, because a
> check that has only ever been seen to pass is an assumption wearing a check's clothing.
> Work happens on branch `shared-eks-namespace`; the own-cluster design is frozen on
> `own-eks-cluster-design`.

| Directory | What it is | Ships to production? |
|---|---|---|
| [`sbsa_besu/`](sbsa_besu/) | **The platform.** Terraform roots (`shared` → `runner` → `chain` → `app`), Helm charts, scripts, and the full design record in `docs/`. | Yes |
| [`mimic_vpc/`](mimic_vpc/) | The cloud team's landing-zone VPC, **as a consumer sees it** — so the platform's input contract can be built and tested before the real hand-over. | No — throwaway |
| [`mimic_eks/`](mimic_eks/) | The cloud team's **shared EKS cluster** and the namespace allotted to us (CT-5, D-32). **Hostile by default**: it exists to make the platform's eleven Terraform gates and four runner preflights *fail*, each citing a requirement number. A pass against it is a bug in the check. Bills per hour — same-day teardown. | No — throwaway |
| [`mimic_egress/`](mimic_egress/) | The bank's shared egress proxy, **as a consumer sees it** — so the Octopus polling-Tentacle path can be tested before the real egress is wired. | No — throwaway |

The frozen reference build this platform was ported from, `besu-aws`, sits
**beside** this repository (`../besu-aws`), not inside it.

## Start here

**[`sbsa_besu/docs/RUNBOOK.md`](sbsa_besu/docs/RUNBOOK.md)** — build order, where
things stand, and the failure modes. Each project also has a `CLAUDE.md` that is its
operating brief for Claude Code sessions, and a `README.md` for humans.

## How the three fit together

The mimics stand in for two other teams, and they talk to the platform the way those
teams would — by **hand-over files of plain values**, never by reading each other's
Terraform state:

```
mimic_vpc  ──emit-handover.sh──▶  network-handover.auto.tfvars  ──▶  mimic_egress
                                                                 └─▶  sbsa_besu/terraform/{shared,chain}
mimic_egress ──emit-handover.sh──▶ egress-handover.auto.tfvars  ──▶  sbsa_besu/terraform/runner
```

In production the same two files are typed by hand from what the cloud team sends.
Both are gitignored; `emit-handover.sh` also recreates the symlinks into each root.

**Build order:** `mimic_vpc` → `mimic_egress` → `shared` → `runner` → `chain` → `app`.
**Teardown:** the reverse, same day. Every cycle gets a row in
[`sbsa_besu/docs/test-run-log.md`](sbsa_besu/docs/test-run-log.md).

## Why one repository

The three used to be separate repositories, deliberately: the mimics' brief says
*"create the VPC"* and the platform's says *"NEVER create network-layer resources"*,
and keeping them apart protected the second rule. They were merged because they move
together — a contract change was three commits in three histories with nothing tying
them together. The protection is now structural: each subtree keeps its own
`CLAUDE.md` and `.gitignore`, the root [`.gitignore`](.gitignore) is the floor beneath
all three, and only the platform is ever deployed by Octopus, under a role that can
still be denied `ec2:CreateVpc`. Full note: RUNBOOK §1. The pre-merge histories are
kept outside the repository at `../_sbsa-git-history-backup-2026-09-18/`.

## What is committed, and what never is

Real `*.tfvars`, the two hand-over files, Terraform state and `.terraform/`
directories are never committed. **Saved `.plan` files are** — deliberately, as the
evidence of what each tested run intended — except any plan that would carry a
private key; the rules and the check to run before adding one are in the root
[`.gitignore`](.gitignore). Plans embed the AWS account ID, which is why this
repository stays private.

Also at the root: [`.github/workflows/`](.github/workflows/) — GitHub Actions only
reads workflows from the repository root, so the platform's `supply-chain.yml` lives
here and runs with `working-directory: sbsa_besu`; and [`CHART_IMAGES.md`](CHART_IMAGES.md), the 15 images the five
upstream Helm charts pull on their own — the most likely cause of a failed first
deployment in an air-gapped VPC, and the one gap `verify-images.sh` does not cover.

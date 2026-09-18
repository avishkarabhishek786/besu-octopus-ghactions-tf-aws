# Docs index

Canonical home for every design record in this programme. The sibling project
`mimic_vpc` holds only a **point-in-time copy** of the requirements spec, on
purpose — see below.

## The cloud-team redesign (current work)

| Document | What it is |
|---|---|
| [RUNBOOK.md](RUNBOOK.md) | **Start here.** Step-by-step build guide, phases and gotchas. |
| [CLOUD_TEAM_FOLLOWUP_2026-09-09.md](CLOUD_TEAM_FOLLOWUP_2026-09-09.md) | **⇢ SEND THIS.** Records what the cloud team answered on the 2026-09-09 calls and carries the remaining questions **R-2b, R-3, R-5b..R-8** plus **R-10**. **R-9 is CLOSED (2026-09-14): a shared central egress behind a load balancer exists and we adopt it** — R-10 is the six-line proxy/firewall ticket that replaces it (proxy address, source /32, two Octopus hostnames on 443, no TLS decryption, a TGW route, credentials y/n). §2.2 carries a correction on TLS inspection. Also withdraws #13, #14 and #26 as requests. |
| [CIDR_ALLOCATION_REVIEW.md](CIDR_ALLOCATION_REVIEW.md) | **⇢ SEND THIS.** Requests a **/20 per environment** against the offered SIT /24, UAT /21, PROD /24, with the arithmetic, a fallback ladder (/21 is the floor) and the reason PROD must not be the smallest. Appendix A documents the /24-with-custom-networking path we are *not* proposing. |
| [CLOUD_TEAM_REQUEST_REGISTRY_AND_CICD.md](CLOUD_TEAM_REQUEST_REGISTRY_AND_CICD.md) | **SENT AND SUPERSEDED — do not re-send.** Carries a status banner mapping each item to its answer. Kept because the R- and CQ- numbers resolve from it. Still explains the two things most often mis-assumed: ECR push is public / pull is private, and ECR is a mirror, not a proxy. |
| [NETWORK_REQUIREMENTS_CLOUD_TEAM.md](NETWORK_REQUIREMENTS_CLOUD_TEAM.md) | The 26 numbered requirements to send the cloud team. **Canonical copy.** §8 is the 2026-09-04 **ECR registry addendum** (#20-#26 added; #8 and #19 withdrawn) — send it as a follow-up rather than resending the whole document. |
| [CLOUD_TEAM_REDESIGN_NOTES.md](CLOUD_TEAM_REDESIGN_NOTES.md) | Full discussion record: the four constraints, analysis, decisions D-1..D-22, open questions. **§11 = CT-3a, the ECR registry design** (2026-09-04). |
| [CICD_DESIGN_NOTES.md](CICD_DESIGN_NOTES.md) | **CI/CD: GitHub Actions + Octopus Deploy.** **§0 is the orientation — read it first:** the two execution classes, the two artefacts CI produces, who deploys what, the build sequence, how R-9 closed, and a comparison against the `besu-aws` model. Then decisions CD-1..CD-64, the three-project Octopus design, the H1 validator gate, **§7 = how Octopus reaches the private cluster as now decided** (polling Tentacle worker on the runner through the bank's shared egress; §7.3 = every egress question answered with its fallback, CD-55..CD-63), and Octopus API-key setup. |
| [diagrams/cicd-build-flow.drawio](diagrams/cicd-build-flow.drawio) | **The CI/CD flow as a picture**, three pages of one `.drawio` file: **1** ownership — what the cloud team owns versus what we own, and what we are still waiting on; **2** engineering detail — the two workflows, the three Octopus projects, and the SIT/UAT/PROD matrix; **3** a management view with no tool or file names. **Redrawn 2026-09-14:** the R-9 branch is now solid — Octopus drives the in-VPC host through the bank's egress (CD-55). Dashed edges now mean image/chart pull only. |
| [EVENT_LISTENER_DESIGN_NOTES.md](EVENT_LISTENER_DESIGN_NOTES.md) | The SWIFT event pipeline: chain-tailer → SNS FIFO → SQS FIFO, decisions E-1..E-20. |
| [mimic-vpc-brief.md](mimic-vpc-brief.md) | The **design-phase draft** of the `mimic_vpc` brief, from before that project existed (it still opens with "rename this file to `CLAUDE.md`"). Kept as the record of what was asked for; it is NOT kept in sync. **The live brief is [../../mimic_vpc/CLAUDE.md](../../mimic_vpc/CLAUDE.md)** — same repository since 2026-09-18. |
| [../../mimic_egress/CLAUDE.md](../../mimic_egress/CLAUDE.md) | **NEW 2026-09-14.** Operating brief for `mimic_egress` — the cloud team's **shared egress proxy**, mimicked (CD-63): explicit `CONNECT` Squid behind an internal NLB VIP, PHZ name, peering + one specific-prefix route into the ledger route tables, allowlist = runner /32 → the two Octopus hostnames on 443, no TLS interception. Built and **applied live on 2026-09-14 and 2026-09-17** (29 resources, 8/8 probes); same repository since 2026-09-18. |
| [build-findings.md](build-findings.md) | Defects found while porting (B1–B15). Four would have passed silently; the entries record how each was found. |
| [../../CHART_IMAGES.md](../../CHART_IMAGES.md) | The **15 images the five upstream charts carry**, on top of the 8 in `var.container_images` — enumerated by `helm template`, not from memory. Registry-independent. `verify-images.sh` does not cover the 15, so it can exit 0 with all of them missing (PORTING item 4). |
| [../PORTING.md](../PORTING.md) | What is ported from `besu-aws` and what remains. |

> **The requirements spec is duplicated deliberately.** `mimic_vpc` keeps
> `docs/spec/network-requirements-v1.md` as a dated copy, because the real cloud
> team works from a document sent to them on a particular date. Drift between the
> two must be *visible*, not silently resolved by a symlink. Re-copy and bump the
> version when the canonical document changes.

## Inherited from `besu-aws`

Kept here because they still govern live code:

| Document | What it is |
|---|---|
| [production-hardening-backlog.md](production-hardening-backlog.md) | H1–H39. The code carries H-numbered comments; this is what they mean. |
| [app-deployment-backlog.md](app-deployment-backlog.md) | C1–C12. Same, for the C-series. Item 5 of the port builds the app cluster. |
| [hardening-validation-plan.md](hardening-validation-plan.md) | How to validate the H-items in a deploy-test. Needed at Phase E. |
| [fips-140-l3-validator-key-management-analysis.md](fips-140-l3-validator-key-management-analysis.md) | Why validator keys are custodied under a KMS CMK (C12). `terraform/chain/kms.tf` is live. |
| [stage-9-blockscout-notes.md](stage-9-blockscout-notes.md) | Blockscout, which the chain root still deploys. |

Read them for **why a control exists**. Their network chapters are superseded by
the redesign documents above.

## What was deleted, and where it went

The rest of the inherited documentation — `manual-deployment-guide.md`,
`docs/explained/*`, `architecture-for-beginners.md`, `claude-code-setup.md`,
`cost-estimate.md`, `stage-8-design-notes.md`, `PRODUCTION-DEPLOYMENT.md`, and
every `prod-deploy-run-*` / `test-run-log` / pentest log — described a build that
**no longer exists**: one Terraform root, a VPC we created, NAT egress, a single
`primary.tfvars`. Left in place they would have been read and believed.

They are intact in the frozen reference repo `besu-aws`, which sits beside this
repository's root (`../../../besu-aws` from this directory), in both its
working tree and its history, and in this repository's own history before
`docs: prune inherited documentation`. Code comments citing `docs/explained/…` or
an F-number resolve **there**.

# Docs index

Canonical home for every design record in this programme. The sibling project
`mimic_vpc` holds only a **point-in-time copy** of the requirements spec, on
purpose — see below.

## The cloud-team redesign (current work)

| Document | What it is |
|---|---|
| [RUNBOOK.md](RUNBOOK.md) | **Start here.** Step-by-step build guide, phases and gotchas. |
| [../scripts/README.md](../scripts/README.md) | **The script index — what exists, where it has to run, and what it can break.** 31 scripts across `preflight/`, `validation/`, `maintenance/`, `permissioning/`, `pki/`, `access/`, `runner/` and `supply-chain/`. An index only: the real documentation is each script's own header, which `-h` prints. It carries the two facts a filename cannot — **laptop vs In-VPC EC2 Runner vs build host, and why that is not a preference** — plus the read-only / mutates / ⚠️ IRREVERSIBLE marker. |
| [CLOUD_TEAM_FOLLOWUP_2026-09-09.md](CLOUD_TEAM_FOLLOWUP_2026-09-09.md) | **⇢ SEND THIS.** Records what the cloud team answered on the 2026-09-09 calls and carries the remaining questions **R-2b, R-3, R-5b..R-8** plus **R-10**. **R-9 is CLOSED (2026-09-14): a shared central egress behind a load balancer exists and we adopt it** — R-10 is the six-line proxy/firewall ticket that replaces it (proxy address, source /32, two Octopus hostnames on 443, no TLS decryption, a TGW route, credentials y/n). §2.2 carries a correction on TLS inspection. Also withdraws #13, #14 and #26 as requests. |
| [CIDR_ALLOCATION_REVIEW.md](CIDR_ALLOCATION_REVIEW.md) | **WITHDRAWN 2026-09-21 (CT-5, D-30) — do not send.** We no longer lay out subnets. Kept as the record. Was: Requests a **/20 per environment** against the offered SIT /24, UAT /21, PROD /24, with the arithmetic, a fallback ladder (/21 is the floor) and the reason PROD must not be the smallest. Appendix A documents the /24-with-custom-networking path we are *not* proposing. |
| [CLOUD_TEAM_REQUEST_REGISTRY_AND_CICD.md](CLOUD_TEAM_REQUEST_REGISTRY_AND_CICD.md) | **SENT AND SUPERSEDED — do not re-send.** Carries a status banner mapping each item to its answer. Kept because the R- and CQ- numbers resolve from it. Still explains the two things most often mis-assumed: ECR push is public / pull is private, and ECR is a mirror, not a proxy. |
| [CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md](CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md) | **⇢ SEND THIS (2026-10-09).** Everything still to raise with or share with the cloud team, in one document: the shared-EKS / namespace-tenancy requirements **#27–#39** (§3 — **#29 is the node-maintenance agreement that protects QBFT quorum**; **#27** namespaces + quota and **#39** IP headroom replace the old network request), the five-command ask (§4), the silent-error audit (§6 — what fails silently, the check that names it, and the three things with no pre-check), the earlier requirements that still stand (#1, #2, #3, #5, #6, #20, #22, #23) plus the VPC endpoints and ECR repository creation (§7), the open items from the 2026-09-09 follow-up (§8), and the event-pipeline questions (§9). Was §9 of the requirements document; its §N is the old §9.N. |
| [NETWORK_REQUIREMENTS_CLOUD_TEAM.md](NETWORK_REQUIREMENTS_CLOUD_TEAM.md) | The original numbered requirements (#1–#26), kept as the record. §8 is the 2026-09-04 **ECR registry addendum** (#20-#26). Most of §§3–5 is withdrawn; what is still live is restated in the shared-cluster document above. **Do not send this file** — send the one above. |
| [CLOUD_TEAM_REDESIGN_NOTES.md](CLOUD_TEAM_REDESIGN_NOTES.md) | Full discussion record: the constraints, analysis, decisions D-1..D-43, open questions. §11 = CT-3a, the ECR registry design (2026-09-04). **§12 = CT-5, shared EKS / namespace tenancy (2026-09-21):** what a tenant cannot own, the three non-mechanical risks (node maintenance vs quorum, node isolation, two clusters → one), the nine-flow subnet-rules gate, the cluster hand-over, per-file repository changes, `mimic_eks`, D-23..D-34, Q-8..Q-16, and the supersessions. **§12.13 (2026-10-09) is the implementation side of the silent-error audit:** the gate assignment per requirement (plan-time / runner preflight / post-deploy / alarm), the files it produces, D-35..D-43, Q-17..Q-18 — and the two findings that are about our own code, **`verify-images.sh` proving the wrong principal (D-38)** and the validator spread being best-effort (D-39). |
| [CICD_DESIGN_NOTES.md](CICD_DESIGN_NOTES.md) | **CI/CD: GitHub Actions + Octopus Deploy.** **§0 is the orientation — read it first:** the two execution classes, the two artefacts CI produces, who deploys what, the build sequence, how R-9 closed, and a comparison against the `besu-aws` model. Then decisions CD-1..CD-64, the three-project Octopus design, the H1 validator gate, **§7 = how Octopus reaches the private cluster as now decided** (polling Tentacle worker on the runner through the bank's shared egress; §7.3 = every egress question answered with its fallback, CD-55..CD-63), and Octopus API-key setup. |
| [diagrams/cicd-build-flow.drawio](diagrams/cicd-build-flow.drawio) | **The CI/CD flow as a picture**, three pages of one `.drawio` file: **1** ownership — what the cloud team owns versus what we own, and what we are still waiting on; **2** engineering detail — the two workflows, the three Octopus projects, and the SIT/UAT/PROD matrix; **3** a management view with no tool or file names. **Redrawn 2026-09-14:** the R-9 branch is now solid — Octopus drives the in-VPC host through the bank's egress (CD-55). Dashed edges now mean image/chart pull only. |
| [EVENT_LISTENER_DESIGN_NOTES.md](EVENT_LISTENER_DESIGN_NOTES.md) | The SWIFT event pipeline: chain-tailer → SNS FIFO → SQS FIFO, decisions E-1..E-20. |
| [mimic-vpc-brief.md](mimic-vpc-brief.md) | The **design-phase draft** of the `mimic_vpc` brief, from before that project existed (it still opens with "rename this file to `CLAUDE.md`"). Kept as the record of what was asked for; it is NOT kept in sync. **The live brief is [../../mimic_vpc/CLAUDE.md](../../mimic_vpc/CLAUDE.md)** — same repository since 2026-09-18. |
| [../../mimic_eks/CLAUDE.md](../../mimic_eks/CLAUDE.md) | **NEW 2026-10-09.** Operating brief for `mimic_eks` — the cloud team's **shared EKS cluster**, mimicked (CT-5, D-32). Its rule is the **opposite** of the platform's: it creates clusters, node groups, addons and namespaces, and that asymmetry is what protects the bank's real cluster. **Hostile by default** — thirteen deliberate defects, each mapped to the platform gate it should trip, because a check that has only ever been seen to pass is an assumption wearing a check's clothing. §6 lists what it cannot reproduce. Bills per hour. |
| [../../mimic_egress/CLAUDE.md](../../mimic_egress/CLAUDE.md) | **NEW 2026-09-14.** Operating brief for `mimic_egress` — the cloud team's **shared egress proxy**, mimicked (CD-63): explicit `CONNECT` Squid behind an internal NLB VIP, PHZ name, peering + one specific-prefix route into the ledger route tables, allowlist = runner /32 → the two Octopus hostnames on 443, no TLS interception. Built and **applied live on 2026-09-14 and 2026-09-17** (29 resources, 8/8 probes); same repository since 2026-09-18. |
| [build-findings.md](build-findings.md) | Defects found while porting (**B1–B24** — this index said B1–B15 until 2026-10-09). Several would have passed silently; the entries record how each was found. **B12 is the one the preflight scripts are written against:** test fixtures are built broken, not healthy. |
| [../../CHART_IMAGES.md](../../CHART_IMAGES.md) | The **15 images the five upstream charts carry**, on top of the 8 in `var.container_images` — enumerated by `helm template`, not from memory. Registry-independent. `verify-images.sh` does not cover the 15, so it can exit 0 with all of them missing (PORTING item 4). |
| [../PORTING.md](../PORTING.md) | What is ported from `besu-aws` and what remains. |

> **The requirements spec is duplicated deliberately.** `mimic_vpc` keeps
> `docs/spec/network-requirements-v1.md` as a dated copy, because the real cloud
> team works from a document sent to them on a particular date. Drift between the
> two must be *visible*, not silently resolved by a symlink. Re-copy and bump the
> version when the canonical document changes.

## What is deliberately repeated, and what is a defect

Reviewed 2026-10-08, because the records read as repetitive and it is worth knowing
which repetition is load-bearing.

**Deliberate — leave it alone:**

| Repetition | Why |
|---|---|
| **Superseded decisions kept in place**, struck through with a pointer (D-5, D-6, CD-6, CD-17, CD-34, and all of D-1/D-4/D-7/D-8/D-12 under CT-5) | A decision log whose wrong turns are deleted cannot be audited, and the same question comes back. The rule throughout: **mark, never delete.** |
| **Sendable documents restate context** — `CLOUD_TEAM_FOLLOWUP`, `CIDR_ALLOCATION_REVIEW`, the requirements addenda | Each is written to be forwarded to someone with no access to this repository. Self-containment is the point; §9 of the requirements document says so in its first line. |
| **The dated spec copy in `mimic_vpc`** | Above. |
| **A control's *why* in the H/C/F backlogs and its *rule* in `CLAUDE.md`** | The backlogs explain; the brief instructs. Different jobs, different audiences. |
| **Internal and external views of the same table** — e.g. the cluster add-ons in `CLOUD_TEAM_REDESIGN_NOTES.md` §12.2 (with `file:line` and our fallback) versus requirements #30 (what we need from you) | Same subject, different columns and different reader. |

**A defect — fix on sight:**

| Repetition | Why it is different |
|---|---|
| **The same technical table in two places**, where both are meant to be current | Found 2026-10-08: the nine network flows existed in both §12.4 and requirement #34 and **had already drifted** — one copy had a DNS row the other did not, within a day of being written. #34 is now canonical; §12.4 cites it. Same rule as CD-12 for versions: one source of truth, because a second place to write it is a second place for it to be wrong. |
| **A live ask that has been withdrawn but still reads as live** | The CIDR material (three copies) now carries a withdrawal banner on each. A reader cannot tell a withdrawn ask from a current one by its tone. |
| **A spec for something that now exists** | §8 of the redesign notes specified `CLAUDE.md`; it is marked DELIVERED rather than read as a to-do list. |

**The test:** if two passages must *change together* to stay true, that is drift waiting
to happen — consolidate and cite. If one is a dated snapshot, a superseded record, or
written for a different reader, it stays.

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

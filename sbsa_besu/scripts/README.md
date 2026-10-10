# `scripts/` — what exists, where it runs, and what it can break

**Last updated 2026-10-09.** 31 scripts, 2 manifests.

## Where the documentation actually lives

**In each script's own header**, and that is deliberate. Every file opens with a
`# ====` block covering why it exists, what it does, what breaks without it, and its
usage — between 10 and 70 lines of it. `-h` prints that block on the preflight and
validation scripts. **Read the header before running anything here.**

This file is an **index, not a second copy**. One line per script, plus the two facts you
cannot get by reading a filename: *where it has to run*, and *what it changes*. The
reasoning is in the header; the decision behind it is in the record cited in the last
column. If you find yourself wanting to explain something here, it belongs in the header
instead — two passages that must change together to stay true are drift waiting to happen
(`docs/README.md`).

## Where a script has to run, and why

Not a preference. Three different hosts can each do things the others cannot:

| Host | Can reach | Cannot reach |
|---|---|---|
| **Laptop** | AWS APIs, the internet, public registries | the **private EKS API**, and the registry *as the cluster sees it* |
| **In-VPC EC2 Runner** | the private EKS API, AWS via VPC endpoints, ECR over the endpoints | the internet (no IGW, no NAT) |
| **Build host / CI** (outside the VPC) | public registries, ECR push | anything inside the VPC |

So: anything using `kubectl` or `helm` **must** run on the runner, because the API
endpoint is private. Anything proving a *pull* must run on the runner, because a laptop
passes while the cluster cannot pull. Anything fetching from a public registry must run
outside the VPC, because inside there is no route — and **a missing route here does not
error, it hangs until timeout** (`CLAUDE.md` prime directive 2).

## Effect column

| Marker | Meaning |
|---|---|
| **read-only** | creates nothing, changes nothing, costs nothing. Safe at any time, including in production |
| **probe** | creates one or two short-lived pods and deletes them. Free |
| **mutates** | changes live state (cluster, secrets, or AWS) |
| **⚠️ IRREVERSIBLE** | destroys data that cannot be recovered |

---

## `preflight/` — prove it before you spend anything

Run in this order. Each failure cites a requirement number from
`docs/NETWORK_REQUIREMENTS_CLOUD_TEAM.md`, so what goes back to the cloud team is a
citation rather than a symptom.

| Script | Run from | Effect | What it does | Record |
|---|---|---|---|---|
| `verify-region.sh` | laptop | read-only | Can the target region host the design: opt-in status, 3 AZs, the instance family offered in **all three**, every endpoint service, the EKS version. Prints the `az_ids` line for tfvars | `CLAUDE.md` §10a |
| `verify-endpoints.sh` | **runner** | read-only | All 15 interface endpoints + the S3 gateway, Private DNS where its absence is fatal, 443 ingress, gateway route-table association, and both ECR policy traps. `--pod-identity` adds `eks-auth` (#31) | #20, #22, #23 · D-14 |
| `verify-cluster.sh` | **runner** | read-only | The cluster-side contract: version floor **and ceiling**, the four CRDs *and* whether a controller is running, StorageClass binding mode and expansion, quota headroom, and the #32 access scope — including probes that **must fail** | §12.13 · D-37, D-41 |
| `verify-admission.sh` | **runner** | read-only | Will the namespace *accept* our pods: Pod Security, quota, LimitRange, RBAC and missing CRDs, in one server-side dry-run. Synthesises a bare `Pod` per pod template, because PSA only **warns** on a StatefulSet | D-40 |
| `verify-images.sh` | **runner** | read-only | Every image digest resolved from Terraform exists in the registry. **Its exit 0 does not mean the cluster can pull** — see its header and `verify-pull-canary.sh` | H38 · D-19, **D-38** |
| `verify-pull-canary.sh` | **runner** | probe | One pod, one image, our namespace: the only check that pulls as the **cloud team's node role**. Classifies the four causes, because they land on four different desks. `--check-policy <node-role-arn> -R <repo>` first reads the repository policies and names the likely cause — it lives here, not in Terraform, because **there is no `aws_ecr_repository_policy` data source** | **#38** · D-38 |
| `verify-subnet-rules.sh` | **runner** | read-only | #34's F-1..F-10 **and the cluster's own C-1..C-3** (with `--control-plane`) against the live NACLs and security groups, **evaluated in rule-number order** because a NACL's first match wins and a `deny` at 90 beats an `allow` at 100. Checks TCP and UDP separately (F-1 needs both), checks the stateless **return** path, and reports partial CIDR coverage, *incidental* permission and an unevaluated side as their own verdicts rather than rounding them to pass | **#34** · D-29 |
| `verify-egress-proxy.sh` | **runner** | read-only | Can this host reach Octopus Cloud through the bank's proxy, **only** Octopus Cloud, and without TLS interception. `install-tentacle.sh` refuses to register if this fails | CD-56..CD-60 |

## `validation/` — assert the deployed state

| Script | Run from | Effect | What it does | Record |
|---|---|---|---|---|
| `verify-deployed.sh` | **runner** | read-only (`--probe-netpol` = probe) | The assertions only observable after deploy, three of which **look like success**: four validators Ready on four **distinct** nodes, the pods' AWS identity, target registration, peer count, the QBFT set, and a NetworkPolicy deny-probe | **D-36**, D-37, D-39 |
| `hardening-validation.sh` | **runner** | read-only | H1..H27 plus runner, certs and pentest checks against an already-running deployment. Prod-safe; gated off your tfvars | H1–H27 |
| `simulate-runner-policy.sh` | laptop | read-only | Will the runner's IAM policy survive a deploy? `iam:SimulatePrincipalPolicy` answers for free what otherwise fails twenty minutes into an apply | CD-54 |

## `maintenance/` — the validator rolling rule, and the nuke

> **Never change a validator by any other path.** QBFT with N=3F+1 tolerates **exactly one**
> validator down; two is a chain **halt**. A blanket `terraform apply` is a no-op on
> validators by construction (H1: `ignore_changes=[values]` + `OnDelete`), and these
> scripts are the only supported way through.

| Script | Run from | Effect | What it does | Record |
|---|---|---|---|---|
| `rolling-besu-apply.sh` | **runner** | mutates | Apply **any** Helm value override across the validators **one at a time**, verifying quorum and catch-up between each. The single supported path for every validator-affecting change | **H1** · CD-5 |
| `rolling-besu-upgrade.sh` | **runner** | mutates | Back-compat wrapper over `rolling-besu-apply.sh` preserving the plain image-bump interface | H1 |
| `rolling-besu-rollback.sh` | **runner** | mutates | The same quorum-gated roll, pinned to the **previous** image. For a bad forward roll or a misbehaving image | H11 |
| `migrate-allowlist-ownership.sh` | **runner** | mutates (metadata only) | **One-time**, for chains created before the allowlist ownership split: annotates the live `besu-account-allowlist` `helm.sh/resource-policy=keep` and labels it Job-owned, so the next `besu-genesis` upgrade cannot delete and re-seed it. Data untouched. **Dry-run by default**; `--apply` to execute | C6 · H2 |
| `migrate-h1-validator-split.sh` | laptop or runner | mutates (state only) | **One-time** Terraform state move for the H1 validator split. On an already-applied chain, skipping it makes the next apply uninstall and reinstall **every** validator at once → halt | H1 |
| `full-delete.sh` | laptop | **⚠️ IRREVERSIBLE** | Tag-keyed teardown backstop for when the state is lost. Deletes keys and chain data. **Dry-run by default**; `--confirm` requires typing `DELETE <group>`. Prefer `terraform destroy` | §9 teardown |

## `permissioning/` — the file-based account allowlist (C6)

Has its own [README.md](permissioning/README.md) with the model and the propagation
semantics. All of these run **on the runner** (private EKS endpoint) and all **mutate**.

| Script | What it does | Record |
|---|---|---|
| `add-account.sh` | Add sender addresses to the allowlist ConfigMap without re-genesis, then propagate | C6 · **F20** |
| `remove-account.sh` | Revoke addresses. Refuses to empty the list — an empty allowlist denies every sender | C6 |
| `list-accounts.sh` | Show the ConfigMap, and with `--live` each enforcing pod's mounted view | C6 |
| `reload-permissions.sh` | Propagate the *current* ConfigMap when the pods were not: after a `PROPAGATE=none` patch, a part-failed propagation, or a re-genesis reset. A ConfigMap change alone does **not** restart a StatefulSet | C6 · H3 |
| `fund-account.sh` | Fund an account by transfer from the faucet. Genesis funding fires **only** at chain creation, and a zero-balance sender's transaction is never mined on a zero-gas chain | **F20** |
| `_perm-lib.sh` | Shared helpers and the propagation logic (validators go one at a time, quorum-gated) | C6 |

## `pki/` and `access/` — mTLS and the SWIFT join pack

| Script | Run from | Effect | What it does | Record |
|---|---|---|---|---|
| `pki/issue-server-cert.sh` | **runner** (or any host with the Secrets Manager grants) | mutates | The RPC server mTLS keystore, truststore and JWT keys into Secrets Manager. **Run before** deploying with `rpc_mtls_enabled=true`, or the pods crash-loop on an empty keystore. Needs `keytool` — an openssl-built PKCS12 truststore makes Besu throw a TLS internal error | **F19** · C12 |
| `pki/issue-app-rpc-cert.sh` | as above | mutates | The app-rpc **server-TLS** keystore, plus the app JWT keypair on first run (kept on re-runs; `APP_RPC_ROTATE_JWT=1` rotates). Server-TLS + JWT, no client certs, unlike the SWIFT pool | Stage 8 |
| `access/sign-client-csr.sh` | laptop | read-only (writes a cert locally) | Sign SWIFT's CSR with our CA. **The default flow:** SWIFT's private key never leaves SWIFT | §1 |
| `access/make-join-pack.sh` | laptop | read-only | Build the bundle handed to SWIFT: CA cert, client cert, endpoint, permitted methods, a method-scoped JWT, and a README | §2.5 |

## `runner/` — bootstrapping the In-VPC EC2 Runner

| Script | Run from | Effect | What it does | Record |
|---|---|---|---|---|
| `push-runner-bundle.sh` | laptop / CI | mutates (S3) | Deliver the runner's toolchain and source through S3, each sha256-verified against `runner-tools.manifest`. Replaces five internet dependencies that would each **hang** in the real VPC. **The GitHub PAT is gone with it** | **D-21** |
| `push-deploy-config.sh` | laptop | mutates (Secrets Manager) | Deliver the gitignored env config the `git archive` bundle excludes by construction: tfvars and the hand-over files | F16 · B18 |
| `fetch-deploy-config.sh` | **runner** | mutates (local files) | The other half: fetch and extract that bundle at boot. Idempotent, and exits 0 when the bundle is absent so user-data does not fail the boot | F16 |
| `install-tentacle.sh` | **runner**, as root | mutates | Turn the runner into an Octopus **polling** Tentacle worker through the bank's proxy. Runs `verify-egress-proxy.sh` first and **refuses to register if it fails** | CD-55, **CD-57** |

## `supply-chain/`

| Script | Run from | Effect | What it does | Record |
|---|---|---|---|---|
| `mirror.sh` | **outside the VPC** | mutates (ECR) | Copy every third-party image and chart into our private ECR, from `mirror.manifest`. **ECR is a registry, not a proxy** — pull-through cache is impossible here, so nothing arrives by accident. Copies by **digest** only; `docker pull/tag/push` re-manifests and silently invalidates every H38 pin. `--check-drift` enforces manifest-vs-Terraform agreement | **D-17, D-18** · CD-12 |

## `lib/`

| File | What it is |
|---|---|
| `common.sh` | Sourced by the access, PKI and permissioning scripts: timestamped logging, strict mode, Secrets Manager helpers, and `tool_version`/`tool_url`/`tool_sha` readers for the pinned toolchain |
| `../runner/runner-tools.manifest` | **The pin** for any tool more than one host depends on — read by `push-runner-bundle.sh` *and* the GitHub Actions workflows, so a version that must agree cannot drift by being restated. Its header states which tools belong here and which stay with their one host |
| `../supply-chain/mirror.manifest` | The single source of truth for what is mirrored (CD-12) |

---

## The rule these are written under

**A check that cannot fail is worse than no check, because it is trusted.** Test fixtures
for preflight scripts are built **broken, not healthy** — the B12 lesson, earned three
times now (`docs/CICD_DESIGN_NOTES.md` §11.3, `docs/CLOUD_TEAM_REDESIGN_NOTES.md` §12.13.5).

Two consequences you will see in the code and should preserve:

- **Anything a script could not evaluate is a WARN that is counted, never a PASS.** "We
  could not look" rendering as green is how a gate becomes decorative.
- **An endpoint policy, or any permission, is reported PASS only when it is provably
  permissive.** Anything unprovable prints the policy and warns.

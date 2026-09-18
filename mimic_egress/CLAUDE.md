# CLAUDE.md — Phase 1b: Shared Egress Proxy (CLOUD-TEAM MIMIC)

> Project: `mimic_egress`. This project impersonates the bank cloud team's **shared central
> egress service** — the thing R-9 confirmed exists (2026-09-14) and whose internals the
> cloud team will not describe. It exists so the platform (`sbsa_besu`) can build and
> deploy-test the **Octopus polling-Tentacle path** (`CICD_DESIGN_NOTES.md` §7, CD-55..CD-63)
> before the bank's egress is wired for us.

You (Claude Code) are building **another team's service**, as a sibling of `mimic_vpc`.
Read `mimic_vpc/CLAUDE.md` first — every convention there applies here, and its **rule #2
(no IGW / NAT / default route in the ledger VPC) is unchanged**. This project is the one
place in the mimic estate that *does* hold an Internet Gateway, because in production the
proxy lives in the **cloud team's** egress VPC, not in ours. **Read this file fully at the
start of every session.**

The authoritative statement of what is being mimicked is `sbsa_besu/docs/CICD_DESIGN_NOTES.md`
**§7.3** (the per-question decisions) and **CD-63** (this project). If the two ever disagree,
the design notes win — raise it with the human rather than silently diverging.

---

## 0. Prime directives (read first)

1. **FIDELITY OVER CONVENIENCE.** Phase 2/3 must not be able to tell this proxy from the
   bank's. Every shortcut the bank's egress would not offer is a **defect**, because it lets
   the platform depend on something production will not have. Concretely: the allowlist is
   real and deny-by-default; the proxy is **explicit** (`CONNECT`), never transparent; there
   is **no TLS interception**; the ledger VPC gets a **specific-prefix route**, never
   `0.0.0.0/0`.

2. **NEVER touch the ledger VPC except to add the one route the cloud team would add.** The
   ledger route tables gain `egress_vpc_cidr → peering` on the **ledger-role tables only**
   (not app/lb/endpoint/data). That is the cloud team's "TGW route" step in the hand-over,
   performed by the same actor (them). Nothing else in `mimic_vpc`'s resources is created,
   modified or read via state — the hand-over `network-handover.auto.tfvars` is consumed as
   **plain variables**, same rule as Phase 2/3.

3. **The allowlist is the product. Never widen it "to make a test pass."** Exactly two
   destination hostnames (`<instance>.octopus.app`, `polling.<instance>.octopus.app`),
   `CONNECT` to **443 only**, from the **runner's /32 only**. If something in Phase 2/3 needs a
   third destination, that is a **Phase 2/3 finding** (the allowlist in the bank is not ours to
   grow either) — record it, do not add it here.

4. **No `ssl-bump`, no CA, no interception — ever.** Octopus's protocol rejects an interrupted
   tunnel (CD-58). A mimic that inspected would either break the Tentacle (useless) or be
   made to "work" by disabling the pin (dangerous and unfaithful).

5. **Consume and emit contracts; never share state.** Input: `network-handover.auto.tfvars`
   (from `mimic_vpc`). Output: `egress-handover.auto.tfvars` for `sbsa_besu` — the values the
   bank would send us as *client configuration*: `egress_proxy_host`, `egress_proxy_port`,
   `egress_vpc_cidr`. Nothing about how the proxy is built leaks into that file.

6. **Ask before `terraform apply` / `destroy`.** Deployment work is **advise-only**: tell the
   human exactly what to run; do not execute unless explicitly asked.

7. **Cost ≈ USD 0.6/day** (internal NLB ~$0.0225/h · `t3.micro` ~$0.0104/h · one private hosted
   zone $0.50/mo · flow logs). **No NAT Gateway** — the proxy instance carries the public
   address in *this* VPC. Same-day teardown applies when the stack comes down.

---

## 1. What is being mimicked, and why this shape

What the cloud team said (2026-09-14): a **shared egress** exists, **not dedicated to us**,
fronted by **a load balancer for outbound traffic** and **another for internal traffic**.
What they will not say: anything else.

So the shape here is the **robust reading** of those words, decided in CD-56..CD-60:

| Bank (assumed) | This mimic | Client-visible difference |
|---|---|---|
| Proxy estate (Zscaler / BlueCoat / Squid class), explicit `CONNECT` | **One Squid** on AL2023, explicit `CONNECT` | none — `host:port`, `CONNECT` |
| "Traffic load balancer" VIP in front of it | **Internal NLB**, TCP listener on the proxy port, **client-IP preservation on** | none — a `host:port` that resolves privately |
| Corporate DNS name for the VIP | **Route 53 private hosted zone**, associated to the ledger VPC | none |
| Reached over the **Transit Gateway** | **VPC peering** (free) | none — both are "a route to a prefix" in the ledger route tables |
| Allowlist by **source** and **destination**, centrally owned | Squid ACLs: `src` = runner /32, `dstdomain` = the two Octopus hostnames, `CONNECT` 443 only | none |
| Their internet edge | IGW in *this* VPC | none — invisible to the client |
| Second LB "for internal traffic" | **not built** — nothing of ours uses it | — |

**Fidelity gaps, stated (never paper over them):** peering is not a TGW (irrelevant to the
client, relevant to who owns the attachment); Squid is not the bank's product (irrelevant to
the client unless the bank's proxy authenticates — CD-56 assumes not; ask via R-10); the
allowlist is ours, theirs is a ticket.

---

## 2. Repository structure

```
terraform/
  versions.tf, backend.tf, variables.tf, main.tf, outputs.tf
  modules/
    egress-vpc/     VPC (/24 is plenty), one public subnet, IGW, route table, flow logs
    proxy/          Squid EC2 (AL2023, user-data), SG, IAM role (SSM core only)
    vip/            internal NLB + target group + listener; PHZ + alias record
    peering/        peering to the ledger VPC + the two specific-prefix routes
  environments/
    sit/            primary.tfvars      (af-south-1, deploy-tests too)
    prod/           primary.tfvars.example  (af-south-1 — documents the ask, never applied)
scripts/
  emit-handover.sh      writes egress-handover.auto.tfvars for sbsa_besu (§4)
  verify-egress.sh      the allow / deny / no-interception probes, run from the runner (§5)
docs/
  egress-handover.md    build sheet + console/CLI equivalents + the R-10 ticket text
```

Conventions: backend key `besu/network/egress.tfstate` (touched by nothing else); provider
`default_tags` (`Project`, `Environment`, `ManagedBy`, `DeletionGroup`, `Owner`,
`CostCenter`); comment heavily, explain the WHY; **nothing hardcoded** — the Octopus
instance name, the runner IP, the proxy port, the zone name and every CIDR are variables.

---

## 3. What to build

### 3.1 Egress VPC (`modules/egress-vpc`)

| Attribute | Value | Why |
|---|---|---|
| CIDR | `var.egress_vpc_cidr` — a `/24`, **non-overlapping** with the ledger `/20` and with `100.64.0.0/16` | peering refuses overlapping CIDRs; the ledger's secondary CIDR counts |
| Subnets | **one public subnet** (NLB + proxy), by AZ ID (`var.az_id`). The bank's VIP is multi-AZ; a mimic's need not be | cost |
| IGW + default route | yes, **in this VPC only** | this is the internet edge of the "cloud team's" service |
| DNS attributes | both on | the NLB alias and Squid's own resolution need them |
| Flow logs | on, 1-day retention in deploy-tests | consistency with `mimic_vpc` |

### 3.2 Proxy (`modules/proxy`)

- **AL2023, `t3.micro` (or `t4g.micro` — pick one, parameterise the AMI lookup).** `dnf install
  squid` in user-data is **allowed here**: this VPC has internet; D-21 governs *our* runner,
  not the bank's proxy.
- **Squid config is rendered from a `templatefile`**, never inline strings, and is the
  allowlist in CD-59/CD-60 exactly:
  ```
  http_port ${proxy_port}
  acl runner   src       ${runner_private_ip}/32            # CD-60: source = the runner only
  acl octopus  dstdomain ${octopus_instance}.octopus.app     # CD-59: two hostnames, no wildcard
  acl octopus  dstdomain polling.${octopus_instance}.octopus.app
  acl SSL_ports port 443                                     # CD-59: 443 only, not 10943
  acl CONNECT  method CONNECT
  http_access deny  CONNECT !SSL_ports
  http_access deny  !CONNECT                                 # explicit proxy for tunnels only — no plain HTTP
  http_access allow runner octopus
  http_access deny  all
  via off  ·  forwarded_for delete                           # the bank's proxy leaks nothing about us either
  access_log stdio:/var/log/squid/access.log                 # read over SSM; ship to CloudWatch if useful
  ```
  **No `ssl_bump`, no `sslproxy_*`, no `cache_peer`.** The `!CONNECT` deny is deliberate: the
  Tentacle needs tunnels only (CD-57), so plain-HTTP proxying is a capability we do not
  grant even to the allowed source.
- **Security group:** inbound `proxy_port` **from the ledger VPC CIDR only** (via peering);
  outbound **443 to `0.0.0.0/0`** (the tunnels) plus what `dnf` needs at boot (80/443). No
  SSH, no public inbound. Reachable by **SSM only** (role = `AmazonSSMManagedInstanceCore`,
  nothing else).
- **Public IP:** auto-assign in the public subnet. This is the "cloud team's" edge, not ours.

### 3.3 VIP (`modules/vip`)

- **Internal NLB** in the public subnet(s), **TCP** listener on `proxy_port` → target group
  (instance target, `preserve_client_ip = true`, health check TCP on `proxy_port`).
  Client-IP preservation is what makes the **source ACL** work: Squid must see the runner's
  address, not the NLB's. Verify this in `verify-egress.sh` — it is the one setting whose
  failure looks like "the allowlist is broken" rather than "the LB is misconfigured".
- **Route 53 private hosted zone** `var.proxy_dns_zone` (e.g. `egress.mimic.internal`),
  **associated to the ledger VPC**, with an **alias A record** `var.proxy_hostname` → the
  NLB. The bank hands us a hostname, so we hand `sbsa_besu` a hostname.

### 3.4 Peering + routes (`modules/peering`)

- `aws_vpc_peering_connection` egress VPC ↔ `var.ledger_vpc_id` (same account, same region;
  `auto_accept = true`), with **DNS resolution over peering enabled both ways**.
- **Egress VPC route table:** `ledger_vpc_cidr_primary → pcx`. (Not the `100.64.0.0/16`
  secondary — nothing there talks to the proxy.)
- **Ledger route tables — `var.ledger_route_table_ids` (ledger role only):**
  `egress_vpc_cidr → pcx`. **One route, one prefix.** This is the cloud team's TGW-route
  step and the only thing this project ever does inside the ledger VPC.

### 3.5 What this project must NOT create

A NAT Gateway (unneeded) · any resource inside the ledger VPC other than the routes in §3.4 ·
a `0.0.0.0/0` route in **any** ledger route table · a wildcard `.octopus.app` ACL · an
`ssl_bump` line · a second allowed source · a listener on 10943 · anything Kubernetes or
anything of Phase 2/3's.

---

## 4. The hand-over contract (THE deliverable)

`sbsa_besu` consumes these as **plain input variables** — the shape of what the bank would
send in reply to R-10, and nothing more:

| Output | Type | Notes |
|---|---|---|
| `egress_proxy_host` | string | `<proxy_hostname>.<proxy_dns_zone>` — resolves only inside the ledger VPC |
| `egress_proxy_port` | number | `var.proxy_port` (default `3128`; the bank may use `8080` — it is a variable for that reason) |
| `egress_vpc_cidr` | string | the prefix the ledger route tables now route — for security-group authoring and the H6 NetworkPolicy *exclusion* check |
| `egress_allowed_source` | string | the `/32` that was allowlisted — so `sbsa_besu` can assert its runner actually has that IP (`runner_private_ip`) before registering the Tentacle |
| `egress_allowed_destinations` | list(string) | the two hostnames — informational, mirrors the ticket |

`scripts/emit-handover.sh` renders them to `egress-handover.auto.tfvars`, to be copied into
`sbsa_besu/terraform/` beside `network-handover.auto.tfvars`. In production the human types
this file from the cloud team's ticket reply.

---

## 5. `scripts/verify-egress.sh` — the probes

Read-only, **run on the runner over SSM** (it is the only allowed source), fails fast with
the requirement it violated. In order:

| # | Probe | Expect | Proves |
|---|---|---|---|
| 1 | `getent hosts <egress_proxy_host>` | resolves to a private address | PHZ association to the ledger VPC |
| 2 | `curl -sS -x http://<host:port> -o /dev/null -w '%{http_code}' https://<instance>.octopus.app/api` | `200` | allow path end-to-end, through the NLB, ACL, IGW |
| 3 | same, to `https://polling.<instance>.octopus.app/` | any HTTP status (not a proxy 403) | second hostname allowed |
| 4 | same, to `https://example.com/` | proxy `403` | destination deny |
| 5 | same, to `http://<instance>.octopus.app/` (plain HTTP) | proxy `403` | `!CONNECT` deny — tunnels only |
| 6 | `curl -x … https://<instance>.octopus.app:10943/` | proxy `403` | port deny — 443 only |
| 7 | `openssl s_client -proxy <host:port> -connect polling.<instance>.octopus.app:443 </dev/null 2>/dev/null \| openssl x509 -fingerprint -sha256 -noout` vs the same from the laptop (no proxy) | **identical** fingerprint | **no interception** (CD-58) — the probe that must also be run once against the bank's proxy |
| 8 | repeat #2 from **a non-allowed source** — the wrapper runs it from the proxy host itself, through the VIP | proxy `403` | source ACL refuses everyone else. (Client-IP preservation is already proven by #2 passing: had the NLB rewritten the source, Squid would have seen the NLB and refused the runner) |

Probes 1–7 live in the platform (`sbsa_besu/scripts/preflight/verify-egress-proxy.sh`)
because they are the platform's day-one check against the **bank's** proxy too;
`scripts/verify-egress.sh` here just runs them on the runner over SSM with the mimic's
values and a laptop-taken fingerprint baseline, then adds probe 8. Probe 7 is the one to
keep after the mimic is gone: it is the fail-fast test for the bank's egress on day one,
**before** any Tentacle registration is attempted — `install-tentacle.sh` refuses to
register if it fails.

---

## 6. Order of operations, and teardown

**Build:** `mimic_vpc` → **`mimic_egress`** → `sbsa_besu` (`shared` → `runner` — the runner
must have `runner_private_ip` = `egress_allowed_source` → Tentacle registers →
`besu-workloads` → `besu-validators`).

**Teardown:** reverse. `mimic_egress` is destroyed **after** `sbsa_besu` and **before**
`mimic_vpc` — its routes live in the ledger route tables and its PHZ is associated to the
ledger VPC; destroying `mimic_vpc` first leaves dangling references and a failed destroy.
Before destroying, confirm zero leaked ENIs in the egress subnet (the NLB's outlive it by
minutes).

---

## 7. Definition of done

Code written and commented · `terraform fmt` and `validate` pass · `plan` shown to the human
(resource count, the NLB and instance called out) · `docs/egress-handover.md` current,
including the **R-10 ticket text** the human can paste to the cloud team ·
**`verify-egress.sh` passes all eight probes against a live apply** — probe 7 against the
mimic *and* recorded as the day-one check for the bank's proxy · `emit-handover.sh` produces
a tfvars fragment `sbsa_besu` consumes without hand-editing · a free-tier Octopus Cloud
Tentacle on the runner registers and runs one worker step through it · applied and torn down
within the cost guardrail, logged in `sbsa_besu/docs/test-run-log.md`.

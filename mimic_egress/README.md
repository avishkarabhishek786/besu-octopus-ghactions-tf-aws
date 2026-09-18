# mimic_egress — simulated cloud-team shared egress proxy

Creates the **shared egress service** that, **in production, the bank's cloud team
provides** and will not describe: an explicit `CONNECT` proxy behind a load-balancer
VIP, reachable from the ledger VPC over a routed prefix, allowlisting one source and
two destinations. It exists so the platform (`sbsa_besu`) can build and deploy-test
the **Octopus polling-Tentacle path** (R-9 → option 1, `CICD_DESIGN_NOTES.md` §7,
CD-55..CD-63) before the bank's egress is wired for us.

**This project never ships to production.** Delete it once the real egress ticket
(R-10) is answered. Sibling of `mimic_vpc`, whose no-IGW rule for the *ledger* VPC is
unchanged — the IGW here is in *their* VPC.

## What it creates

1 egress VPC (/24, one public subnet, IGW) · 1 Squid proxy (`t3.micro`, AL2023,
SSM-only) · 1 internal NLB VIP (TCP, client-IP preserved) · 1 Route 53 private zone
associated to the ledger VPC · 1 VPC peering · **exactly one route per LEDGER route
table** (`egress /24 → peering`; never `0.0.0.0/0`, never app/lb/endpoint/data) ·
flow logs.

**The allowlist** (`modules/proxy/squid.conf.tftpl`): `src` = the runner's /32 ·
`dstdomain` = `<instance>.octopus.app`, `polling.<instance>.octopus.app` · `CONNECT`
to **443 only** · no plain HTTP · **no `ssl_bump`** (Octopus's protocol rejects an
interrupted tunnel).

## Run

```bash
cp ../mimic_vpc/network-handover.auto.tfvars terraform/        # the ledger VPC, as plain variables
cd terraform
cp environments/sit/primary.tfvars.example environments/sit/primary.tfvars   # then edit:
#   octopus_instance   = your free-tier Octopus Cloud instance label
#   runner_private_ip  = an address inside a LEDGER subnet (this becomes the allowlisted /32)
#   egress_vpc_cidr    = disjoint from the ledger /20 and from 100.64.0.0/16
terraform init -backend-config="bucket=<state-bucket>" \
               -backend-config="key=besu/<env>/egress.tfstate" \
               -backend-config="region=<state-region>" -backend-config="use_lockfile=true"
terraform plan  -var-file=environments/sit/primary.tfvars
terraform apply -var-file=environments/sit/primary.tfvars

cd .. && ./scripts/emit-handover.sh          # -> egress-handover.auto.tfvars, wired into sbsa_besu/terraform/runner
# then, in sbsa_besu: push-deploy-config.sh (ships both hand-over files to the runner),
# apply terraform/runner (it pins runner_private_ip from the hand-over), and
./scripts/verify-egress.sh                   # 8 probes: allow ×2, deny ×4, no-interception, other-source refused
```

**Order:** `mimic_vpc` → **`mimic_egress`** → `sbsa_besu` (shared → runner → Tentacle
registers via `install-tentacle.sh` → workloads). **Teardown in reverse** — this
project's routes and zone association live in the ledger VPC, so destroy it *before*
`mimic_vpc`.

## Cost

≈ **USD 0.6/day**: NLB ~$0.0225/h · `t3.micro` ~$0.0104/h · private zone $0.50/mo ·
flow logs. No NAT gateway. Same-day teardown applies.

## Fidelity limits

| Bank | Here | Client-visible? |
|---|---|---|
| Transit Gateway attachment | VPC peering | no — both are a route to a prefix |
| Zscaler / BlueCoat / Palo Alto-class estate | one Squid | no — `host:port`, `CONNECT`, 403 on refusal |
| Multi-AZ VIP | single AZ | no |
| Their allowlist, their process | ours, in a template | the ticket (R-10) is what makes theirs match |
| Possibly proxy authentication | none (CD-56 assumption) | yes, if they require it — `polling-proxy --proxyUsername` covers it |

Full brief: `CLAUDE.md`. Build sheet + the R-10 ticket text: `docs/egress-handover.md`.

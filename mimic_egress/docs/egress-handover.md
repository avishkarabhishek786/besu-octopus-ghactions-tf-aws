# Egress hand-over — build sheet, and the ticket we send

What this project builds, resource by resource, with console/CLI equivalents; then
the **R-10 ticket text** for the real cloud team, whose reply is typed into
`egress-handover.auto.tfvars`. Decision references (CD-N) are in
`sbsa_besu/docs/CICD_DESIGN_NOTES.md` §3 / §7.3.

## 1. Order of operations (what the mimic does; what the bank already has)

1. **Egress VPC** — a `/24`, DNS attributes on, one public subnet by AZ ID, IGW,
   default route **in this VPC only**.
   `aws ec2 create-vpc --cidr-block 10.61.0.0/24` · `create-internet-gateway` ·
   `attach-internet-gateway` · `create-subnet --availability-zone-id afs1-az1 --cidr-block 10.61.0.0/26` ·
   `create-route --destination-cidr-block 0.0.0.0/0 --gateway-id igw-…`
2. **Proxy instance** — AL2023 `t3.micro`, public IP, IMDSv2, SSM role only, SG:
   in `proxy_port` from the ledger /20 and from this VPC; out 443 only.
   User data: `dnf install squid`, write the rendered `squid.conf`, `squid -k parse`,
   `systemctl enable --now squid`. A parse failure fails the bootstrap loudly.
3. **VIP** — internal NLB, TCP listener on `proxy_port` → instance target group with
   `preserve_client_ip=true` (the allowlist is by source; if the NLB rewrote the
   source, Squid would see the NLB). `aws elbv2 create-load-balancer --scheme internal --type network …`
4. **Name** — Route 53 private zone `egress.mimic.internal`, **associated to the
   ledger VPC**, alias `proxy.` → the NLB.
   `aws route53 create-hosted-zone --vpc VPCRegion=…,VPCId=<egress-vpc>` ·
   `associate-vpc-with-hosted-zone --vpc VPCId=<ledger-vpc>` · `change-resource-record-sets` (alias A).
5. **Peering** — egress VPC ↔ ledger VPC, auto-accepted, DNS resolution both ways.
   `aws ec2 create-vpc-peering-connection --vpc-id <egress> --peer-vpc-id <ledger>` ·
   `accept-vpc-peering-connection` · `modify-vpc-peering-connection-options --…-allow-dns-resolution-from-remote-vpc`
6. **Routes** — egress table: `ledger /20 → pcx`. **Each LEDGER route table:**
   `egress /24 → pcx`. **Nothing** in the app/lb/endpoint/data tables; **never** `0.0.0.0/0`.
   `aws ec2 create-route --route-table-id rtb-<ledger-az1> --destination-cidr-block 10.61.0.0/24 --vpc-peering-connection-id pcx-…` ×3.
   In production this step is the cloud team adding a **TGW route** — identical from the client's side.
7. **Hand-over** — `scripts/emit-handover.sh` → `egress-handover.auto.tfvars`; in
   production, typed from the ticket reply (§4).

## 2. Failure modes

| Symptom | Cause | Check |
|---|---|---|
| `terraform apply` refuses at plan | egress CIDR overlaps the ledger primary **or secondary** (100.64.0.0/16); runner IP outside every ledger subnet; region ≠ `network_region` | the gate's message names which |
| Probe 1 fails: proxy name does not resolve on the runner | private zone not associated to the ledger VPC | `aws route53 list-hosted-zones-by-vpc --vpc-id <ledger>` |
| Probe 2 gets `000` | no route from the ledger table to the egress prefix; SG on the proxy missing the ledger /20; Squid down | `describe-route-tables`, `describe-security-groups`, `systemctl status squid` over SSM |
| Probe 2 gets `403` but probe 4 too | the **source** is refused — runner IP ≠ `runner_private_ip`, or the NLB is not preserving client IP | `terraform output runner_private_ip` in sbsa_besu; target group `preserve_client_ip` |
| Probe 3 `403` while probe 2 passes | only one hostname allowlisted | the ticket (and `squid.conf.tftpl`) must name **both** |
| Probe 7 mismatch | the proxy decrypts TLS | in the mimic: someone added `ssl_bump` — remove it. At the bank: ask for the no-decrypt exception (R-10 item 4) |
| `register-worker` hangs | it ignores the polling proxy on Linux; `https_proxy` not set for that one call | `install-tentacle.sh` does this; if run by hand, prefix the command |
| Worker registers, then never goes healthy | the Tentacle's **web-request** proxy was enabled and is exported to steps; or the service runs with `HTTPS_PROXY` set | `Tentacle proxy --proxyEnable=false`; check `systemctl show tentacle -p Environment` |
| Destroying `mimic_vpc` fails on route tables / zone association | `mimic_egress` still up | destroy this project first |

## 3. Verification

`scripts/verify-egress.sh` runs the platform's `verify-egress-proxy.sh` on the runner
(probes 1–7) and a refusal probe from the proxy host (probe 8). All eight must pass
before any Tentacle is registered. **Probe 7 is the one to keep after the mimic is
gone**: run it against the bank's proxy on day one, with the baseline fingerprint
taken from a network without the proxy.

## 4. The R-10 ticket — send this (fill the brackets)

> **Subject:** Egress allowlist for the ledger platform's Octopus deployment agent
>
> We need one internal host to reach our Octopus Cloud instance through the shared
> egress service. Everything is outbound; nothing dials in.
>
> 1. **Proxy address** — please give us the VIP hostname and port to configure
>    (as seen from the ledger VPC).
> 2. **Source** — `[runner private IP]/32` in ledger subnet `[subnet-id, AZ afs1-az1]`.
>    (If you allowlist by subnet: `[ledger subnet /24]`.)
> 3. **Destinations** — `[instance].octopus.app` and `polling.[instance].octopus.app`,
>    **TCP 443, `CONNECT` only**. Octopus publishes static IPs for the instance if
>    your rules are IP-based; tell us and we will supply them.
> 4. **No TLS decryption** on those two destinations. The agent uses mutual
>    certificate authentication with pinned thumbprints and cannot operate through
>    an inspecting proxy ("requires an uninterrupted TLS tunnel" — Octopus docs).
> 5. **Route** — from the ledger route tables `[rtb-…, rtb-…, rtb-…]` to the egress
>    VIP's prefix over the Transit Gateway. Ledger tables only.
> 6. **Credentials** — does the proxy require authentication? If so, a service
>    credential for this host.
>
> **Not requested:** general internet access, an Internet Gateway, a default route,
> a public cluster endpoint, any inbound rule, or any detail of how the egress
> service is built.

Their reply becomes:

```hcl
# sbsa_besu/terraform/egress-handover.auto.tfvars  (typed by hand)
egress_proxy_host           = "<VIP hostname>"
egress_proxy_port           = <port>
egress_vpc_cidr             = "<VIP prefix they routed>"
egress_allowed_source       = "<runner IP>/32"
egress_allowed_destinations = ["<instance>.octopus.app", "polling.<instance>.octopus.app"]
```

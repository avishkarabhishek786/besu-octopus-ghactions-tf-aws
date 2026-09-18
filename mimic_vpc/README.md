# mimic_vpc — simulated cloud-team network hand-over

Creates the shared VPC and subnets that, **in production, the bank's cloud team
provides**. It exists so the platform project (`sbsa_besu`) can be built and
deploy-tested against a network that behaves exactly like the real hand-over.

**This project never ships to production.** Delete it once the real VPC exists.

## What it creates

1 VPC (/20, `default` tenancy, both DNS attributes on, CG-NAT secondary CIDR
associated but unused) · 15 subnets across 3 AZs · 15 route tables with **no
default route** · 3 NACLs on the ledger subnets (permissive baseline; the
platform owns the rules) · a DHCP option set · VPC flow logs · optionally the
two free gateway endpoints.

**It never creates:** an Internet Gateway, NAT Gateway, Elastic IP, public
subnet, or any `0.0.0.0/0` route. There is no toggle for this.

## Subnet plan (/20 → 2,880 of 4,096 allocated, 1,216 in reserve)

| Role | Count | Size | Usable | Purpose |
|---|---|---|---|---|
| ledger | 3 | /24 | 753 | Besu cluster nodes + pods |
| app | 3 | /23 | 1,521 | application cluster nodes + pods |
| lb | 3 | /26 | 177 | internal NLB / ALB — carries the `internal-elb` tag |
| endpoint | 3 | /26 | 177 | interface endpoint ENIs — separate from `lb` by requirement |
| data | 3 | /26 | 177 | managed databases, caches |

## Run

```bash
cd terraform
cp environments/sit/primary.tfvars.example environments/sit/primary.tfvars     # then edit
terraform init -backend-config="bucket=<state-bucket>" \
               -backend-config="key=besu/<env>/network.tfstate" \   # <env> = sit | uat | prod
               -backend-config="region=<state-region>"
terraform plan  -var-file=environments/sit/primary.tfvars
terraform apply -var-file=environments/sit/primary.tfvars

cd .. && ./scripts/verify-contract.sh          # assert the contract against live AWS
./scripts/emit-handover.sh                     # render the tfvars for sbsa_besu
cp network-handover.auto.tfvars ../sbsa_besu/terraform/
```

## Cost

Everything here is free except **VPC flow logs**. Keep
`flow_log_retention_days = 1` in deploy-tests.

## Fidelity limits

Cannot reproduce: RAM-share participant restrictions (Q-1), Transit Gateway,
corporate DNS forwarding, landing-zone SCPs and tag policies. See `CLAUDE.md` §6.

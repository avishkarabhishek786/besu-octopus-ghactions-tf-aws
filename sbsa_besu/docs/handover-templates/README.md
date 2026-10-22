# Hand-over files: what we need back from the cloud team

Once the VPC and EKS cluster are built, the ledger platform team needs three facts files from you. Our Terraform reads them as plain values. It never reads your Terraform state.

| File | Describes | Built in |
| :---- | :---- | :---- |
| `network-handover.auto.tfvars.template` | The VPC, its 15 subnets, route tables, NACLs and endpoints | Checklist Part 1, Steps 0–5 |
| `egress-handover.auto.tfvars.template` | The proxy path the deployment agent uses | Checklist Step 6 |
| `eks-handover.auto.tfvars.template` | The cluster, the ledger's namespaces, nodes and add-ons | Checklist Part 2, Steps 7–11 |

## How to fill them in

1. Replace every value marked `<...>`, including the angle brackets. Keep the variable names and the format exactly as they are.
2. Per-AZ values are keyed by **AZ ID** (`afs1-az1`, `afs1-az2`, `afs1-az3`), never by AZ name.
3. `true`/`false` and port values are written without quotes, for example `pod_identity = false` and `egress_proxy_port = 3128`.
4. Remove the `.template` suffix when you return them, so they are named `network-handover.auto.tfvars`, `egress-handover.auto.tfvars` and `eks-handover.auto.tfvars`.
5. Send one set per environment (SIT, UAT, PROD) and say which environment each set is for.

Any `<...>` left in a file makes our plan fail straight away, so nothing missed goes through unnoticed. Every value is also checked against live AWS before anything is built; if one is wrong, the check names the requirement it breaks.

## What we send you first

Some of your values depend on ours:

| We send | You need it for |
| :---- | :---- |
| The proposed runner IP | The subnet CIDR reservation, the proxy allowlist and `egress_allowed_source` |
| The Octopus instance name | The proxy's two allowed destinations |
| The runner's IAM role ARN | The EKS access entry (`runner_access_entry_created`) |
| The NLB security group IDs (after our first deployment) | The node security group rule for TCP 8545–8546 |

## Questions

Contact the ledger platform team. The full design is in `VPC_EKS_ARCHITECTURE.md`, and the build steps are in `VPC and EKS Build Checklist.docx`.

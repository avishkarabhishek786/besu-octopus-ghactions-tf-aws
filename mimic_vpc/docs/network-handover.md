# Network hand-over — build sheet

What this project builds, resource by resource, with console/CLI equivalents so
the real cloud team can reproduce it by hand. Requirement numbers (#N) refer to
`docs/spec/network-requirements-v1.md`.

## Order of operations

1. **VPC** — `/20`, `instance_tenancy=default` (#1), `enableDnsSupport` +
   `enableDnsHostnames` (#2).
   `aws ec2 create-vpc --cidr-block 10.60.0.0/20 --instance-tenancy default`
   then `modify-vpc-attribute --enable-dns-support` and `--enable-dns-hostnames`.
2. **Secondary CIDR** (#17) — associate `100.64.0.0/16`; create **no** subnets in it.
   `aws ec2 associate-vpc-cidr-block --vpc-id <id> --cidr-block 100.64.0.0/16`
3. **DHCP option set** (#3) — `AmazonProvidedDNS`, associated to the VPC.
4. **15 subnets** — by **AZ ID** (#5), `map-public-ip-on-launch` disabled.
   `aws ec2 create-subnet --availability-zone-id afs1-az1 --cidr-block ...`
5. **Tags** (#4) — `kubernetes.io/role/internal-elb=1` plus both
   `kubernetes.io/cluster/<name>=shared` tags, on the **lb** subnets only.
6. **15 route tables** (#12) — one per subnet, associated, **no routes added**.
   In production the cloud team adds Transit Gateway routes here for on-premises
   destinations. The container registry (ECR) needs none — it is reached by endpoint.
7. **3 NACLs** (#13) on the ledger subnets, each with an explicit allow-all
   baseline. **An empty NACL denies everything** — omitting the rules
   black-holes the ledger subnets.
8. **Flow logs** — VPC-level to CloudWatch.
9. **Gateway endpoints** (#10) — S3 and DynamoDB, free, associated to the
   ledger/app/lb/endpoint route tables. Skipped when the platform owns them.

## Failure modes

| Symptom | Cause | Requirement |
|---|---|---|
| Every AWS SDK call hangs; nodes never bootstrap | a DNS attribute is false, or the DHCP option set points only at on-prem DNS | #2, #3 |
| Nodes launch but EC2 bill triples | VPC created with `dedicated` tenancy — **irreversible** | #1 |
| Cluster builds; NLB never provisions | `internal-elb` tag missing — fails at Service-creation, not at apply | #4 |
| Ledger subnets black-hole all traffic | NACL created without explicit allow rules | #13 |
| `terraform apply` fails authorizing the S3 endpoint | no permission to associate a gateway endpoint to the route tables | #10 |
| Application cannot reach the ledger over PrivateLink | endpoint ENIs share a subnet with the NLB nodes | #16 |
| Validator pods unschedulable after an app team scales | ledger and applications share a subnet | #11 |

## Verification

`scripts/verify-contract.sh` re-asserts all of the above against the live AWS
API. Run it after every apply; it is the gate before emitting the hand-over.

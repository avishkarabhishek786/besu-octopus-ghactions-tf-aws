# Manual build — 2026-10-23 — the whole stack by hand, no Terraform

**Goal:** build the platform end to end with **no Terraform** — the AWS layer by hand with the AWS CLI;
the in-cluster layer deployed **by Octopus**, through hand-written script steps on the runner — send a
transaction, delete everything the same day. **This file is also the guide to redo
it:** run the phases top to bottom; fixes found during the run are already folded into the commands.
The timestamped record is at the bottom. Times UTC.

**Design:** air-gapped, as the repo intends — no internet gateway or NAT; AWS reached through VPC
endpoints; images from our private ECR, filled by the `supply-chain.yml` workflow; the private EKS API
reached only from the runner (EC2 at `10.60.0.250`, SSM only), which is also the Octopus worker: its
Tentacle polls Octopus Cloud through a mimic of the bank's egress proxy (two hostnames allowed, nothing else).

**Simplified vs the Terraform build (on purpose):** 9 subnets, not 15 (no `app`/`data` tiers, unused
by the chain); the VPC's main route table for all of them; no custom NACLs, flow logs, secondary CIDR,
DHCP options set or IAM permissions boundary (H5). Octopus has no OIDC trust to AWS (`aws-trust`) and no
GitHub trust (`ci-trust`): it never touches the AWS layer, and releases are created in the Octopus UI.
Resource **names** match the Terraform build, so the repo's scripts work unchanged.

**Branch `manual-setup`** holds only what this build uses: `helm/`, the kept `scripts/`,
`.github/workflows/supply-chain.yml`, and `manual/` — the hand-written files the steps below load
(`proxy-user-data.sh`, `runner-user-data.sh`, `iam-policy-lb-controller.json`, …). Terraform and the
design records stay on branch `testing` (`git show testing:<path>`).

**Cost:** ≈ $2/hour from P2 (endpoints) until teardown finishes.

```
by hand (laptop)                                                         by Octopus (on the runner)
P0 prep ─► P1 ECR mirror ─► P2 network ─► P3 egress proxy ─► P4 KMS, IAM,  P8 project + release:
   secrets, CA ─► P5 EKS ─► P6 runner ─► P7 Octopus setup + Tentacle ─────►  add-ons, chain, Blockscout,
                                                                             NLB binding, observability
P9 tunnel + transaction ─► T teardown + zero-check
```

---

## C0 — Clean-environment check (read-only, both regions)

**Why:** anything found at the end must have been made today.

```bash
export SP=~/besu-run-2026-10-23-manual; mkdir -p $SP
export ACCT=$(aws sts get-caller-identity --query Account --output text)
{
echo "== identity"; aws sts get-caller-identity --query '[Account,Arn]' --output text
for r in af-south-1 us-east-1; do echo; echo "################ $r"
  echo "-- vpcs (non-default)";  aws ec2 describe-vpcs --region $r --filters Name=is-default,Values=false --query 'Vpcs[].VpcId' --output text
  echo "-- instances";           aws ec2 describe-instances --region $r --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text
  echo "-- eks clusters";        aws eks list-clusters --region $r --query clusters --output text
  echo "-- enis";                aws ec2 describe-network-interfaces --region $r --query 'NetworkInterfaces[].[NetworkInterfaceId,InterfaceType,Description]' --output text
  echo "-- vpc endpoints";       aws ec2 describe-vpc-endpoints --region $r --query 'VpcEndpoints[].VpcEndpointId' --output text
  echo "-- endpoint services";   aws ec2 describe-vpc-endpoint-service-configurations --region $r --query 'ServiceConfigurations[].ServiceId' --output text
  echo "-- nat gateways";        aws ec2 describe-nat-gateways --region $r --filter Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId' --output text
  echo "-- elastic ips";         aws ec2 describe-addresses --region $r --query 'Addresses[].PublicIp' --output text
  echo "-- peerings";            aws ec2 describe-vpc-peering-connections --region $r --filters Name=status-code,Values=active,pending-acceptance,provisioning --query 'VpcPeeringConnections[].VpcPeeringConnectionId' --output text
  echo "-- non-default SGs";     aws ec2 describe-security-groups --region $r --query "SecurityGroups[?GroupName!='default'].[GroupId,GroupName]" --output text
  echo "-- flow logs";           aws ec2 describe-flow-logs --region $r --query 'FlowLogs[].FlowLogId' --output text
  echo "-- volumes";             aws ec2 describe-volumes --region $r --query 'Volumes[].[VolumeId,State,Size]' --output text
  echo "-- snapshots (mine)";    aws ec2 describe-snapshots --region $r --owner-ids self --query 'Snapshots[].SnapshotId' --output text
  echo "-- launch templates";    aws ec2 describe-launch-templates --region $r --query 'LaunchTemplates[].LaunchTemplateName' --output text
  echo "-- load balancers";      aws elbv2 describe-load-balancers --region $r --query 'LoadBalancers[].LoadBalancerName' --output text
  echo "-- target groups";       aws elbv2 describe-target-groups --region $r --query 'TargetGroups[].TargetGroupName' --output text
  echo "-- classic ELBs";        aws elb describe-load-balancers --region $r --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text
  echo "-- log groups";          aws logs describe-log-groups --region $r --query 'logGroups[].logGroupName' --output text
  echo "-- alarms";              aws cloudwatch describe-alarms --region $r --query 'MetricAlarms[].AlarmName' --output text
  echo "-- secrets (incl. planned deletion)"; aws secretsmanager list-secrets --region $r --include-planned-deletion --query 'SecretList[].[Name,DeletedDate]' --output text
  echo "-- ecr repos";           aws ecr describe-repositories --region $r --query 'repositories[].repositoryName' --output text
  echo "-- kms customer keys (state)"
  for k in $(aws kms list-keys --region $r --query 'Keys[].KeyId' --output text); do
    aws kms describe-key --region $r --key-id $k --query 'KeyMetadata.[KeyManager,KeyState,KeyId]' --output text; done | grep '^CUSTOMER'
  echo "-- sns topics";          aws sns list-topics --region $r --query 'Topics[].TopicArn' --output text
  echo "-- sqs queues";          aws sqs list-queues --region $r --query 'QueueUrls' --output text
  echo "-- cloudformation";      aws cloudformation describe-stacks --region $r --query 'Stacks[].[StackName,StackStatus]' --output text
  echo "-- cloudtrail trails";   aws cloudtrail describe-trails --region $r --query 'trailList[].Name' --output text
  echo "-- private CAs";         aws acm-pca list-certificate-authorities --region $r --query 'CertificateAuthorities[?Status!=`DELETED`].[Arn,Status]' --output text
  echo "-- resource groups";     aws resource-groups list-groups --region $r --query 'GroupIdentifiers[].GroupName' --output text
done
echo; echo "################ global"
echo "-- route53 zones";         aws route53 list-hosted-zones --query 'HostedZones[].[Name,Id]' --output text
echo "-- iam roles (not service-linked)"; aws iam list-roles --query 'Roles[?!starts_with(Path,`/aws-service-role/`)].[RoleName,CreateDate]' --output text
echo "-- iam customer policies"; aws iam list-policies --scope Local --query 'Policies[].[PolicyName,AttachmentCount]' --output text
echo "-- iam instance profiles"; aws iam list-instance-profiles --query 'InstanceProfiles[].InstanceProfileName' --output text
echo "-- iam oidc providers";    aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text
echo "-- s3 buckets";            aws s3 ls
echo "-- terraform states (managed resources) and locks"
for b in besu-tfstate-$ACCT besu-tfstate-$ACCT-afs1; do
  for k in $(aws s3 ls s3://$b --recursive | awk '/\.tfstate$/{print $4}'); do
    printf "%-55s %s\n" "$b/$k" "$(aws s3 cp s3://$b/$k - 2>/dev/null | jq '[.resources[]?|select(.mode=="managed")]|length')"; done
  aws s3 ls s3://$b --recursive | grep tflock; done
echo "-- local kube contexts";   kubectl config get-contexts 2>/dev/null
} 2>&1 | tee ~/besu-run-2026-10-23-manual/c0-clean-check.txt
ls -l ~/besu-run-2026-10-23-manual/c0-clean-check.txt     # must exist and be non-empty
```

Run the whole block, from `export SP=` to the `ls`, **in one terminal**. The output path is absolute: on
the first try `$SP` was empty in the shell running the block, so the output only went to the screen.

**Expect:** every regional list empty. Global: only the two state buckets, the GitHub OIDC provider
`token.actions.githubusercontent.com` (kept; shared by the account), AWS-created roles; every
`.tfstate` **0**; no `.tflock`.

---

## P0 — Laptop prep (free)

**Why:** one file holds every variable and helper, so a new terminal is one `source` away. IDs created
later are appended to `ids.env` by `keep`, so nothing lives only in one terminal's memory.

```bash
cat > ~/besu-run-2026-10-23-manual/env.sh <<'EOF'
export REPO=~/Documents/Blockchain/Besu/besu-octopus-ghactions-tf-aws
export D=2026-10-23 SP=~/besu-run-2026-10-23-manual
export R=af-south-1 P=sbsa-besu DG=sbsa-manual-2026-10-23 CLUSTER=sbsa-besu-primary-eks
export GH=avishkarabhishek786/besu-octopus-ghactions-tf-aws
export OCTO=avishkarabhishek786 RUNNER_IP=10.60.0.250          # https://$OCTO.octopus.app ; the runner's pinned IP
export ACCT=$(aws sts get-caller-identity --query Account --output text)
export T="{Key=Project,Value=$P},{Key=DeletionGroup,Value=$DG}"          # tags for --tag-specifications
ts()   { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},$T]"; }            # ts <type> <name>
keep() { echo "export $1=$2" >> $SP/ids.env; export $1=$2; echo "$1=$2"; } # keep <VAR> <id>
touch $SP/ids.env; source $SP/ids.env
EOF
source ~/besu-run-2026-10-23-manual/env.sh; echo $ACCT

aws --version; jq --version; kubectl version --client; helm version --short
gh --version; gh auth status; session-manager-plugin --version; openssl version; cast --version
cd $REPO && sbsa_besu/scripts/preflight/verify-region.sh af-south-1 m6i.xlarge 1.35
```

**Expect:** the account ID; every tool prints a version; `gh` logged in; **7 passed / 0 failed**.
*Redo on another day:* change the date in the first 3 lines of `env.sh`.

**The test sender key** — the chain's only funds come from genesis (F20), so this address goes into
genesis in P8. Kept in an encrypted keystore; the raw key is never in a variable or history.

```bash
cast wallet list | grep -q besu-sit-sender || {
  cast wallet new                                    # prints Address + Private key ONCE
  cast wallet import besu-sit-sender --interactive   # paste that key, choose a password
}
keep SENDER $(cast wallet address --account besu-sit-sender)
```

---

## P1 — Fill the ECR mirror with `supply-chain.yml` (free / cents)

**Why:** the VPC has no internet, so every image and chart must already be in our ECR — a missing one
**hangs**, it doesn't error. GitHub Actions copies them (`crane`, digests preserved, D-18) using an IAM
role it assumes with a short-lived OIDC token: no AWS keys in GitHub.

### P1.1 — The push role (replaces `mimic_registry`)

```bash
source ~/besu-run-2026-10-23-manual/env.sh
OIDC=arn:aws:iam::$ACCT:oidc-provider/token.actions.githubusercontent.com
aws iam get-open-id-connect-provider --open-id-connect-provider-arn $OIDC --query ClientIDList --output text  # → sts.amazonaws.com

# The token's "sub" for this repo (created after 2026-07-15) carries owner/repo IDs; the old form is kept too.
GHID='avishkarabhishek786@27818433/besu-octopus-ghactions-tf-aws@1375347034'
cat > $SP/ecr-push-trust.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Federated":"$OIDC"},
 "Action":"sts:AssumeRoleWithWebIdentity",
 "Condition":{"StringEquals":{"token.actions.githubusercontent.com:aud":"sts.amazonaws.com",
  "token.actions.githubusercontent.com:sub":["repo:$GHID:ref:refs/heads/manual-setup","repo:$GHID:ref:refs/heads/main",
   "repo:$GH:ref:refs/heads/manual-setup","repo:$GH:ref:refs/heads/main"]}}}]}
EOF
cat > $SP/ecr-push-policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"Login","Effect":"Allow","Action":["ecr:GetAuthorizationToken","ecr:DescribeRepositories"],"Resource":"*"},
 {"Sid":"PushAndCreateUnderPrefix","Effect":"Allow","Resource":"arn:aws:ecr:$R:$ACCT:repository/mirror/*",
  "Action":["ecr:BatchCheckLayerAvailability","ecr:BatchGetImage","ecr:CompleteLayerUpload","ecr:DescribeImages",
   "ecr:GetDownloadUrlForLayer","ecr:InitiateLayerUpload","ecr:ListImages","ecr:PutImage","ecr:UploadLayerPart",
   "ecr:CreateRepository"]}]}
EOF
aws iam create-role --role-name $P-sit-ecr-push --assume-role-policy-document file://$SP/ecr-push-trust.json \
  --max-session-duration 3600 --tags Key=Project,Value=$P Key=DeletionGroup,Value=$DG --query Role.Arn --output text
aws iam put-role-policy --role-name $P-sit-ecr-push --policy-name ecr-push-under-prefix \
  --policy-document file://$SP/ecr-push-policy.json
```

**Expect:** the role ARN `arn:aws:iam::<acct>:role/sbsa-besu-sit-ecr-push`; `put-role-policy` prints nothing.
Never delete the OIDC provider — it is the account's, shared by other roles.

### P1.2 — GitHub secrets and variables

```bash
gh secret   set AWS_ECR_PUSH_ROLE_ARN -R $GH --body "arn:aws:iam::$ACCT:role/$P-sit-ecr-push"
gh secret   set ECR_REGISTRY          -R $GH --body "$ACCT.dkr.ecr.$R.amazonaws.com"
gh variable set ECR_PREFIX            -R $GH --body mirror
gh variable set AWS_REGION            -R $GH --body $R
gh variable set CI_RUNNER_LABELS      -R $GH --body '["ubuntu-latest"]'
gh secret list -R $GH; gh variable list -R $GH
git push -u origin manual-setup          # the workflow runs from this branch, so it must be on GitHub
git ls-remote --heads origin manual-setup
```

**Expect:** 2 secrets, 3 variables, and a commit hash for `manual-setup`. (Optional: a read-only Docker Hub
token as `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN`, both or neither, avoids the anonymous pull limit.)

### P1.3 — Run the workflow: dry run, then for real

```bash
gh workflow run supply-chain.yml -R $GH --ref manual-setup -f dry_run=true  -f scope=all -f create_repos=true
sleep 5; gh run watch -R $GH $(gh run list -R $GH --workflow supply-chain.yml --limit 1 --json databaseId -q '.[0].databaseId')
#   green → run it for real:
gh workflow run supply-chain.yml -R $GH --ref manual-setup -f dry_run=false -f scope=all -f create_repos=true
sleep 5; gh run watch -R $GH $(gh run list -R $GH --workflow supply-chain.yml --limit 1 --json databaseId -q '.[0].databaseId')
aws ecr describe-repositories --region $R --query 'length(repositories)' --output text
```

**Expect:** both runs green; **29** repositories (23 images + 5 charts under `mirror/`, as of 2026-10).
**If "Not authorized to perform sts:AssumeRoleWithWebIdentity":** copy the `OIDC sub:` line the
workflow printed and compare it with the trust policy in P1.1.

---

## P2 — Network: VPC, subnets, endpoints (💰 billing starts at the endpoints · ~10 min)

**Why:** this impersonates the bank's VPC: private subnets only, no route out. Every AWS API the
nodes, pods and runner call goes through an interface endpoint; S3 (image layers, the runner bundle)
through the free gateway endpoint. A missing endpoint hangs rather than errors.

| Role | afs1-az1 | afs1-az2 | afs1-az3 | Used by |
|---|---|---|---|---|
| ledger | 10.60.0.0/24 | 10.60.1.0/24 | 10.60.2.0/24 | EKS nodes, runner |
| lb | 10.60.10.0/26 | 10.60.10.64/26 | 10.60.10.128/26 | internal NLB (P10) |
| endpoint | 10.60.11.0/26 | 10.60.11.64/26 | 10.60.11.128/26 | interface endpoint ENIs |

### P2.1 — VPC and subnets

```bash
source ~/besu-run-2026-10-23-manual/env.sh
keep VPC $(aws ec2 create-vpc --region $R --cidr-block 10.60.0.0/20 --tag-specifications "$(ts vpc $P-sit-vpc)" \
  --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --region $R --vpc-id $VPC --enable-dns-hostnames '{"Value":true}'   # DNS support is on by default

sn() { aws ec2 create-subnet --region $R --vpc-id $VPC --availability-zone-id $2 --cidr-block $3 \
         --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$P-sit-$1-$2},{Key=Role,Value=$1},$T]" \
         --query Subnet.SubnetId --output text; }
keep LEDGER1 $(sn ledger   afs1-az1 10.60.0.0/24);    keep LEDGER2 $(sn ledger   afs1-az2 10.60.1.0/24);    keep LEDGER3 $(sn ledger   afs1-az3 10.60.2.0/24)
keep LB1     $(sn lb       afs1-az1 10.60.10.0/26);   keep LB2     $(sn lb       afs1-az2 10.60.10.64/26);  keep LB3     $(sn lb       afs1-az3 10.60.10.128/26)
keep EP1     $(sn endpoint afs1-az1 10.60.11.0/26);   keep EP2     $(sn endpoint afs1-az2 10.60.11.64/26);  keep EP3     $(sn endpoint afs1-az3 10.60.11.128/26)

# the load balancer controller finds the NLB subnets by these tags (#4)
aws ec2 create-tags --region $R --resources $LB1 $LB2 $LB3 \
  --tags Key=kubernetes.io/role/internal-elb,Value=1 Key=kubernetes.io/cluster/$CLUSTER,Value=shared
# reserve the runner's IP so EKS pods can't take it first (B43); the proxy allows only this address
aws ec2 create-subnet-cidr-reservation --region $R --subnet-id $LEDGER1 --cidr $RUNNER_IP/32 --reservation-type explicit \
  --description "runner pinned IP (egress proxy allowlist)" --query 'SubnetCidrReservation.Cidr' --output text
keep RTB $(aws ec2 describe-route-tables --region $R --filters Name=vpc-id,Values=$VPC Name=association.main,Values=true \
  --query 'RouteTables[0].RouteTableId' --output text)
aws ec2 describe-subnets --region $R --filters Name=vpc-id,Values=$VPC \
  --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,CidrBlock,AvailabilityZoneId]' --output table
```

**Expect:** a `vpc-…`, nine `subnet-…` IDs, `10.60.0.250/32`, an `rtb-…`; the table shows 9 subnets over 3 AZ IDs.
The main route table holds only the `local` route — **no internet route**, by design.

### P2.2 — Endpoints: 15 interface + S3 gateway

```bash
keep VPCE_SG $(aws ec2 create-security-group --region $R --vpc-id $VPC --group-name $P-sit-vpce \
  --description "HTTPS from inside the VPC to the AWS interface endpoints" \
  --tag-specifications "$(ts security-group $P-sit-vpce)" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --region $R --group-id $VPCE_SG --protocol tcp --port 443 --cidr 10.60.0.0/20 \
  --query 'Return' --output text

for s in ssm ssmmessages ec2messages ec2 ecr.api ecr.dkr sts eks elasticloadbalancing secretsmanager kms logs monitoring sns sqs; do
  aws ec2 create-vpc-endpoint --region $R --vpc-id $VPC --vpc-endpoint-type Interface \
    --service-name com.amazonaws.$R.$s --subnet-ids $EP1 $EP2 $EP3 --security-group-ids $VPCE_SG --private-dns-enabled \
    --tag-specifications "$(ts vpc-endpoint $P-sit-vpce-${s//./-})" --query 'VpcEndpoint.[VpcEndpointId,ServiceName]' --output text
done
keep VPCE_S3 $(aws ec2 create-vpc-endpoint --region $R --vpc-id $VPC --vpc-endpoint-type Gateway \
  --service-name com.amazonaws.$R.s3 --route-table-ids $RTB --tag-specifications "$(ts vpc-endpoint $P-sit-vpce-s3)" \
  --query VpcEndpoint.VpcEndpointId --output text)

sleep 120; aws ec2 describe-vpc-endpoints --region $R --filters Name=vpc-id,Values=$VPC \
  --query 'VpcEndpoints[].[State,VpcEndpointType]' --output text | sort | uniq -c   # → 15 available Interface, 1 available Gateway
cd $REPO/sbsa_besu && scripts/preflight/verify-endpoints.sh $VPC $R --route-tables $RTB
```

**Expect:** 15 interface lines + 1 gateway; after ~2 min all **available**; `verify-endpoints.sh` passes.

---

## P3 – P9 — written as we reach them

P3 egress proxy (proxy VPC, proxy EC2, internal NLB + DNS name, peering, route) · P4 KMS keys, IAM/IRSA
roles, Secrets Manager entries, CA, SWIFT NLB + target group, SNS · P5 EKS cluster, OIDC provider, node
group, addons · P6 runner (bundle in S3, EC2 at `10.60.0.250`, cluster access) · P7 Octopus by hand
(service account + key, environment SIT, worker pool `besu-runner-sit`, secrets) + `install-tentacle.sh`
through the proxy · P8 Octopus project with script steps → release → in-cluster layer · P9 tunnel +
transaction · T teardown in reverse + zero-check.

---

## Log

| Time | Step | Who | Result |
|---|---|---|---|
| — | prep | Claude | Local only: `mimic_eks/terraform/terraform.tfstate` holds **0** resources (serial 247, 2026-10-10) |
| — | scope | operator | Air-gapped design · mirror via `supply-chain.yml` · all components (required + optional) |
| — | scope | operator | **Egress proxy and Octopus included** — we still deploy through Octopus. Decision: no Terraform anywhere; AWS layer by hand, Octopus runs hand-written script steps for the in-cluster layer (the repo's Octopus steps all run Terraform, so they aren't used) |
| — | C0 (1st) | operator / Claude | ❌ no output file: `$SP` was empty in the shell that ran the block, so `tee` had nowhere to write. C0 now writes to an absolute path and ends with an `ls`. Re-run |
| 12:47 | C0 (2nd) | operator / Claude | ✅ **clean**. af-south-1 + us-east-1: no VPC, instance, EKS, ENI, endpoint, LB, volume, log group, secret, ECR repo. Only leftovers, all expected: 2 KMS keys `PendingDeletion` (earlier runs); state buckets + the 2026-09-06 `tf-octopus-demo-*` buckets (not ours); GitHub OIDC provider; `AWSLoadBalancerControllerIAMPolicy` (0 attachments, decision still open); every live `.tfstate` **0**, no `.tflock` — the three non-zero ones are the old copies under `MOVED-2026-10-11/` (B49), whose resources are long gone. **Gap:** the IAM-roles line printed nothing, not even its header — `!starts_with` inside double quotes triggered bash history expansion. Fixed above (single quotes); re-check that one line |
| 12:49 | P0 | operator / Claude | `env.sh` written. `ids.env` empty and no `~/.foundry/keystores`: the **sender-key** step hasn't run (or `cast` is missing) — must be done before P8 |
| — | old policy `AWSLoadBalancerControllerIAMPolicy` | operator / Claude | Decision: **delete** — not this repo's (2026-08-08, 0 attachments); the LB controller uses the repo's pinned `iam_policy_alb.json` as `sbsa-besu-primary-alb-controller-policy`. Commands given; awaiting result |
| — | IAM roles re-check | operator | ✅ 4 roles, none ours: `amplifyconsole-backend-role` (2022), `cfarers-app-dev-…` (2025-09), `clanity_dev_iam_role_lambdafn` (2025-09), `github-actions-terraform` (2026-09-06, the Octopus demo's). C0 **complete: clean** |
| — | branch `manual-setup` | Claude | Committed the 10-22 docs on `testing` (`1df6e0a`), branched `manual-setup`. Added `manual/` (proxy + runner boot scripts, LB-controller policy, copied from the Terraform before removal). Edited: `supply-chain.yml` (dropped the manifest-vs-Terraform drift step), `push-runner-bundle.sh` + `runner-tools.manifest` (no terraform, no provider mirror), `CLAUDE.md` + root `README.md` banners. P1 trust policy and `--ref` now name `manual-setup`. Bulk `git rm` was refused by Claude's safety check → operator runs it |

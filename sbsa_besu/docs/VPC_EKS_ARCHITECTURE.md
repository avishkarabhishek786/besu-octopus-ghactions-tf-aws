# Ledger platform on AWS: VPC and EKS architecture

| Field | Details |
| :---- | :---- |
| **Status** | Draft, 16 Oct 2026 |
| **Owner** | Ledger platform team |
| **Scope** | Network (VPC) and Kubernetes (EKS) architecture of the Besu ledger platform |
| **Diagram** | `docs/diagrams/architecture-prod.drawio` |
| **Related** | `CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md` (requirements #1–#39); `CLOUD_TEAM_REDESIGN_NOTES.md` (decision record D-1–D-43); `CICD_DESIGN_NOTES.md` (CD-1–CD-68); `build-findings.md` (B-numbers) |

**How to read this.** This document describes the VPC and EKS architecture the ledger runs on, and gives the reason for each choice. Where a choice is recorded in more detail elsewhere, its ID appears in brackets — (D-29), (#34), (CD-57) — so it can be traced to the full reasoning.

**Roles used in this document:**

| Role | Responsible for |
| :---- | :---- |
| **Network owner** | AWS account, VPC, subnets, route tables, NACLs, DHCP options, Transit Gateway, VPC endpoints, shared egress proxy |
| **Cluster operator** | EKS cluster, node groups, add-ons, StorageClasses, CRDs, Kubernetes upgrades, node rotation, namespaces and their quotas |
| **Platform team** | The ledger workloads inside their namespaces, and the AWS resources beside the cluster: NLBs, security groups, KMS keys, secrets, workload IAM roles, SNS/SQS, S3, alarms and the In-VPC EC2 Runner |

Section 3 explains how these roles map to teams under each deployment model.

---

## 1. Summary

The platform is a private, permissioned Hyperledger Besu ledger for payment events. Its only external client is SWIFT, which reaches it over the SIPN private network. It runs in `af-south-1` across three Availability Zones, with no internet access.

The architecture rests on ten decisions:

1. **No internet path for workloads.** No Internet Gateway, no NAT, no default route. Every AWS call goes through a VPC endpoint, and every image comes from ECR. The one exception is a single outbound path for the deployment agent (point 10). (D-3)
2. **Private only.** Private EKS API endpoint, internal load balancers only, no public IP anywhere. Operators connect through SSM Session Manager.
3. **Four validators, one per node, spread across three AZs.** The ledger keeps running with one validator down and **stops with two down**. Most of this document follows from that fact.
4. **Node maintenance is the biggest operational risk.** Validators are protected by a PodDisruptionBudget, required anti-affinity and a defined node-rotation procedure. (#29, D-27, D-39)
5. **A dedicated, tainted node group for the ledger**, ideally in dedicated ledger subnets. (#28, D-26)
6. **Kubernetes NetworkPolicy default-deny is the main boundary between tenants.** The CNI must enforce it. (D-9, #35)
7. **Security groups are the network service boundary.** NACLs separate subnet roles but cannot protect the ledger's service ports. (§4.6)
8. **Images are mirrored, not proxied.** CI copies them into ECR by digest. Pull-through cache cannot work without internet. (D-16, D-17, D-18)
9. **Network and cluster facts reach the platform as plain values**, and the platform checks them against live AWS before building anything. Most failures in this environment hang rather than error, so they are caught before any cost is incurred. (D-2, D-25, D-29)
10. **Deployments reach the private cluster through a polling agent on one EC2 instance inside the VPC.** It connects outbound only, to two hostnames, through the shared egress proxy. (CD-55, CD-57)

---

## 2. What runs, and why it is sensitive

### 2.1 Workloads

| Component | Count | Purpose | Reached by |
| :---- | :---- | :---- | :---- |
| Validators | 4 | Produce blocks (QBFT consensus) | Each other only (P2P) |
| Bootnodes | 2 | Peer discovery | Validators and RPC nodes (P2P) |
| SWIFT RPC pool | 2 | JSON-RPC for SWIFT: mTLS, method-scoped | SWIFT, through an internal NLB |
| Application RPC pool | 0 or more (set per environment) | JSON-RPC for internal applications, JWT-authenticated | Applications, through a second internal NLB |
| Explorer RPC pool | 1 | DEBUG/TRACE methods for Blockscout | Blockscout only (in-cluster) |
| Blockscout | 6 pods, including its Postgres | Internal block explorer | Operators, through SSM port forwarding |
| Monitoring | Prometheus, Alertmanager, Fluent Bit | Metrics, alerts, logs | The cluster's shared monitoring stack, or a dedicated instance in the ledger namespace |
| Event pipeline (planned) | Chain tailer + consumers | Ledger events → SNS FIFO → SQS FIFO → bank systems; S3 archive | In-cluster pods, no Lambda (E-15) |

Sizing for the ledger namespace (from the chart settings): about 20 pods, 4.5 vCPU and 17 GiB requested, a 36 GiB memory limit, 10 volumes and about 200 GiB of disk. The namespace quota in §5.7 adds about 30% headroom.

### 2.2 The one fact everything else follows from

QBFT with 4 validators needs 3 of them online to produce blocks.

* **One validator down:** the ledger keeps running, but has no remaining fault tolerance.
* **Two validators down:** block production stops, and stays stopped until someone fixes it by hand.

So the platform must never let two validators go down together. Four events can cause that, and the architecture addresses each one:

| Event | Where it is addressed |
| :---- | :---- |
| A node rotation or drain takes two validators | One validator per node (§5.8), PodDisruptionBudget, the node-maintenance procedure (§5.9) |
| A Helm upgrade restarts all four together | Validators use `OnDelete` updates and are changed only by a script that restarts one at a time (H1, CD-5) |
| An AZ outage | Validators spread across three AZs (§4.1). Losing one AZ costs at most two validators… |
| …and two validators share the failed AZ | Accepted. 4 validators across 3 AZs cannot be spread evenly. A 2/1/1 split keeps quorum only if the AZ that fails holds one. Disaster recovery is out of scope by decision. |

---

## 3. Responsibility model and deployment options

### 3.1 Responsibilities

| Layer | Role |
| :---- | :---- |
| AWS account, VPC, subnets, route tables, NACLs, DHCP, Transit Gateway, VPC endpoints, egress proxy | Network owner |
| EKS cluster, node groups, add-ons, StorageClasses, CRDs, Kubernetes upgrades, node rotation | Cluster operator |
| Namespaces, quotas, Pod Security labels, access entries | Cluster operator, sized to the platform's needs |
| Everything inside the ledger and application namespaces | Platform team |
| AWS resources beside the cluster: NLBs and their security groups, KMS keys, Secrets Manager secrets, workload IAM roles, SNS/SQS, S3 buckets, CloudWatch alarms, the In-VPC EC2 Runner | Platform team |
| ECR registry (shared-services account) | Registry owner; the platform's CI pushes to it |

The platform's code may not create any network resource (VPC, subnet, route, gateway) or any cluster-wide Kubernetes resource (cluster, node group, add-on, CRD, StorageClass, webhook, cluster RBAC). An attempt to create one is treated as a bug: in production it fails on permissions, and in the test environment it is checked for explicitly. (D-23)

### 3.2 Deployment models

| Model | Network owner | Cluster operator | Notes |
| :---- | :---- | :---- | :---- |
| **C: shared cluster, dedicated node group** (current) | Central infrastructure team | Central infrastructure team | The ledger gets a namespace and a dedicated node group in a shared cluster. Node maintenance depends on the procedure in §5.9 being agreed and followed. |
| **B: dedicated EKS cluster in a shared VPC** | Central infrastructure team | Platform team | The platform team runs the cluster, its upgrades and its add-ons. Most cluster-level dependencies, including the node-maintenance agreement, disappear. |
| **A: dedicated AWS account**, joined to the bank network over the Transit Gateway | Platform team, with the network team providing the Transit Gateway attachment, IP range, DNS forwarding and egress | Platform team | Everything in §4 and §5 is built and run by the platform team |

The design in §4 and §5 is the same under every model; only the owner of each part changes. The test environment already builds the full stack (VPC, egress and cluster) from this design (§10).

---

## 4. VPC architecture

### 4.1 Region and Availability Zones

* **Region `af-south-1`** for all three environments (SIT, UAT, PROD). It is an opt-in region. It has been confirmed as enabled, `m6i.xlarge` is offered in all three AZs, and every endpoint service in §4.8 exists there.
* **All three AZs**, identified by **AZ ID** (`afs1-az1`, `afs1-az2`, `afs1-az3`), never by AZ name. AZ names map to different physical zones in different accounts. When the workload account and the VPC owner's account differ, using names can put two validators in one physical zone without anyone noticing. (#5)
* `af-south-1` has only three AZs. There is no fourth zone to grow into.

### 4.2 VPC attributes

| Attribute | Required value | Why | If wrong |
| :---- | :---- | :---- | :---- |
| `instance_tenancy` | `default` | `dedicated` forces every instance onto dedicated hardware (about USD 1,460 a month extra), and it cannot be changed on an existing VPC (#1, D-15) | Cost; unfixable without a new VPC |
| `enableDnsSupport`, `enableDnsHostnames` | both `true` | Interface endpoint Private DNS needs both (#2) | Every AWS call hangs |
| DHCP option set | Amazon-provided DNS, or on-premises DNS that forwards AWS service names to the VPC resolver (base + 2) | Endpoint Private DNS resolves only through the Amazon resolver (#3) | ECR, STS and KMS names resolve to public addresses, then time out. This is the most common failure in air-gapped VPCs. |
| `map_public_ip_on_launch` | `false` on every subnet | Nothing is public | — |

### 4.3 Address space: why EKS needs more than the pod count suggests

With the AWS VPC CNI, **every pod gets a real VPC address**, and each node also holds spare addresses so that new pods start quickly. On an `m6i.xlarge` (4 network interfaces × 15 addresses):

| CNI mode | Addresses held per node | Max pods per node |
| :---- | :---- | :---- |
| Default (`WARM_ENI_TARGET=1`) | about 45–60 | 58 |
| Tuned (`WARM_IP_TARGET` + `MINIMUM_IP_TARGET`) | about 25–30 | 58 |
| Prefix delegation | about 32–48, in blocks of 16 | 110 |

So it is **the number of nodes**, not the ledger's ~20 pods, that decides how many addresses the ledger uses. For planning, use **50 addresses per node** with default settings and **30 per node** when tuned. **Prefix delegation makes small subnets worse**, because it reserves addresses 16 at a time.

**Recommendation for the ledger subnets:** tune `WARM_IP_TARGET` and `MINIMUM_IP_TARGET`, and alarm on free addresses per subnet. AWS has no built-in metric for this, so the alarm only exists if someone builds it. (#39, D-43)

### 4.4 Subnets by role

The VPC is divided into subnets by role. The recommended layout for a VPC that hosts the ledger and an application estate (the test VPC is built exactly like this):

| Role | Per AZ | Usable per subnet | Holds |
| :---- | :---- | :---- | :---- |
| **ledger** | /24 | 251 | Ledger node group: nodes and their pods |
| **app** | /23 | 507 | Application node groups |
| **lb** | /26 | 59 | Internal NLB and ALB interfaces |
| **endpoint** | /26 | 59 | Interface endpoint ENIs |
| **data** | /26 | 59 | RDS, caches |

A `/20` holds all fifteen subnets: 2,880 addresses allocated and 1,216 kept in reserve. The exact CIDR of every subnet, and the layout for a smaller range, are in §11.2.

Five points about this layout:

* **Dedicated ledger subnets matter more than their size.** They give the validators a fixed pool of addresses that other workloads' autoscaling cannot use up. They also allow subnet-level flow logs and a separate set of NACL rules. A /24 holds about 15 nodes when tuned; the ledger needs 4–6. (#28)
* **Endpoint subnets are kept separate from LB subnets.** NLB nodes and the endpoint ENIs behind them should not share a subnet. (#16)
* **The ledger's needs outside its own subnets are small:** 6 NLB interfaces (2 NLBs × 3 AZs) in the lb subnets, and 1 address for the In-VPC EC2 Runner.
* **The runner's address is reserved** with an *explicit subnet CIDR reservation* when the runner shares a subnet with EKS nodes. In testing, the CNI's spare-address pool took the runner's pinned address and EC2 refused to start the runner. With a reservation, AWS hands out that address only when it is requested by name. (B43)
* **If address space is short,** the fallback is a `100.64.0.0/16` secondary CIDR (RFC 6598, outside the bank's IPAM) with CNI custom networking, so that pod addresses come from it. Custom networking is preferred over Enhanced Subnet Discovery, because only custom networking guarantees that no pod addresses come from the scarce RFC 1918 range. (§5.6 of the redesign notes)

### 4.5 Routing

* **No route table has a default route.** No Internet Gateway, NAT gateway or Elastic IP.
* Routes are `local` (primary and any secondary CIDR) plus the S3 and DynamoDB **gateway endpoint** routes.
* **One extra route,** in the route table of the runner's subnet only: a **specific prefix** for the egress proxy, sent over the Transit Gateway. It is never a default route, and it is never added to the ledger node or app route tables. (CD-60)
* Each role and AZ has its own route table, so that a routing change made for applications cannot affect the ledger. (#12)

### 4.6 Subnet rules: NACLs and security groups

Every validator-to-validator connection crosses AZs, so it crosses the subnet rules. Testing a deny-by-default NACL set built from the flow table in §4.7 produced three findings:

1. **The flows do not fit in a default NACL.** AWS allows 20 rules per NACL in each direction. The ledger's flows plus the cluster's own traffic need about **26 inbound and 30 outbound** rules on the workload subnets. A dedicated ledger node group goes over 20 on its own. The options are to merge address ranges, raise the quota to 40, or use security groups.
2. **A NACL cannot protect a service port above 1024.** NACLs need return rules over 1024–65535, and every port the ledger listens on (30303, 8545, 8546, 9545, 5432) is inside that range. Allowing return traffic from a subnet also allows new connections to all of those services. NACLs separate subnet roles; they are not a service boundary.
3. **Discovery is easy to break without anyone noticing.** Besu's peer discovery is UDP from port 30303 to port 30303. If it is blocked, the chain keeps running on its existing connections, but discovery is dead and nobody notices until it is needed. **UDP 30303 must be checked separately from TCP 30303.**

**Recommendation:** use NACLs, where used at all, for coarse separation between roles, and **security groups for the service boundary**. Kubernetes NetworkPolicy sits on top of both (§5.3). The platform's subnet-rule checker reads the live NACLs and security groups and names any blocked flow by its number. (D-29)

### 4.7 Network flows

The tables below are a copy for reading convenience. **The canonical version is requirement #34** in `CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md`, which the checker implements. If the two ever differ, #34 is correct.

**Flows the ledger needs:**

| # | Flow | Port / protocol | From → To |
| :---- | :---- | :---- | :---- |
| F-1 | Validator and bootnode P2P | **30303 TCP and UDP** | ledger ↔ ledger, all AZs |
| F-2 | RPC through the ledger's NLBs, plus health checks | 8545, 8546 TCP | lb → ledger |
| F-3 | Return traffic for F-2 (NACLs only) | 1024–65535 TCP | ledger → lb |
| F-4 | Metrics scrape | 9545 TCP | Prometheus → ledger |
| F-5 | AWS APIs through interface endpoints | 443 TCP | ledger and runner subnets → endpoint subnets |
| F-6 | S3 gateway: image layers, Terraform state, tool bundle | 443 TCP | ledger and runner subnets → S3 prefix list (a NACL must list S3's regional ranges) |
| F-7 | Runner → cluster API | 443 TCP | runner subnet → control-plane ENI subnets |
| F-8 | Runner → egress proxy, plus return traffic | proxy port | runner subnet ↔ proxy range |
| F-9 | Explorer database | 5432 TCP | in-namespace, or ledger → data |
| F-10 | DNS | 53 UDP/TCP | to the VPC resolver |

**Flows the cluster itself needs** (listed because rules written for one tenant can remove them):

| # | Flow | Port / protocol | Between |
| :---- | :---- | :---- | :---- |
| C-1 | Nodes → cluster API | 443 TCP | every node subnet → every control-plane ENI subnet, **across AZs** |
| C-2 | Pods → CoreDNS | 53 UDP and TCP | node subnet ↔ node subnet, across AZs |
| C-3 | Control plane → kubelet and webhooks | 10250 + webhook ports TCP | control-plane subnets → node subnets |
| C-4 | Pod ↔ pod, node ↔ node | as the CNI needs | node subnet ↔ node subnet |

In testing, with only F-1 to F-10 allowed, the node in the one AZ without a control-plane ENI **never joined the cluster**. Adding C-1 fixed it. (B27)

### 4.8 VPC endpoints

**Interface endpoints, with Private DNS on, in every AZ:**

| Endpoint | Used by |
| :---- | :---- |
| `ssm`, `ssmmessages`, `ec2messages` | Session Manager: the **only** way to reach the runner. Without them, nothing can be deployed. |
| `ecr.api`, `ecr.dkr` | Image pulls (nodes) and image checks (runner) |
| `sts` | IRSA token exchange |
| `eks` | Runner → EKS API calls |
| `ec2`, `elasticloadbalancing` | CNI, load-balancer controller, target registration |
| `kms`, `secretsmanager` | Validator key custody, which is on the validator start-up path |
| `logs`, `monitoring` | Fluent Bit, CloudWatch alarms |
| `sns`, `sqs` | Alertmanager, event pipeline |
| `eks-auth` | **Only if** the cluster uses EKS Pod Identity rather than IRSA |
| `autoscaling` | Only if Cluster Autoscaler or Karpenter is used |

**Gateway endpoints (free):** `s3`, which every image pull needs, and `dynamodb` for the event pipeline.

**Three endpoint policy traps.** Each one shows up as a stalled or failed image pull, with no message naming the cause:

1. **The S3 gateway policy must allow the ECR layer bucket** (`arn:aws:s3:::prod-af-south-1-starport-layer-bucket/*`). ECR serves image manifests, but the layers come from S3. (#20)
2. **Private DNS must be on for `ecr.api` and `ecr.dkr`.** (#22)
3. **The ECR endpoint policy must not be limited to one account.** EKS add-on images come from AWS's own registry account, which in `af-south-1` is **`877085696533`**, not the commonly quoted `602401143452`. The ledger's images come from the shared-services account. (#23)

A missing endpoint does not return an error: the call hangs until it times out. The runner checks the endpoint list before every deployment.

### 4.9 Egress: one path, for one host

The only component in the ledger's VPC that talks to the internet is the **Octopus polling agent (Tentacle) on the In-VPC EC2 Runner**. It connects to Octopus Cloud through the shared egress proxy:

| Setting | Value | Why |
| :---- | :---- | :---- |
| Proxy type | Explicit `CONNECT` proxy at a load-balancer address | Nothing leaves unless it is configured to (CD-56) |
| Source | The runner's fixed private IP (/32) | Pods in the same subnet cannot use the proxy, even by mistake (CD-60) |
| Destinations | `<instance>.octopus.app` and `polling.<instance>.octopus.app`, port 443 only | The agent installer ships in the runner's own bundle, so no download host is needed (CD-59) |
| TLS inspection | **None** on those two names | Octopus authenticates with client certificates and pins the server's certificate. An inspected connection is refused. (CD-58) |
| Direction | Outbound only | No inbound rule, no public cluster endpoint |
| Route | Specific prefix over the Transit Gateway, runner subnet only | Never a default route |

The agent sends only its own polling connection through the proxy. Terraform, `kubectl` and the AWS CLI on the same host use the VPC endpoints and the private EKS endpoint directly, never the proxy. (CD-57)

### 4.10 Flow logs

VPC-level flow logs, plus subnet-level logs on the ledger subnets when they are dedicated. The platform team needs read access to the ledger subnets' logs to investigate peer-connection and NLB health issues.

---

## 5. EKS architecture

### 5.1 Cluster

| Setting | Value | Why |
| :---- | :---- | :---- |
| API endpoint | **Private only** (`endpointPublicAccess = false`) | A public endpoint is control-plane attack surface. From inside the VPC a public endpoint behaves the same, so the setting is checked directly. (CG-2) |
| Kubernetes version | Inside the tested range, currently **1.33 to 1.36** | Besu and the charts are tested before each upgrade. Deployment stops if the cluster is newer than the tested range, so an unannounced upgrade shows up as a clear message instead of a failed apply weeks later. (#36, D-41) |
| Support tier | Standard support | Extended support raises the control plane from USD 0.10 to 0.60 an hour |
| Control-plane logs | `api`, `audit`, `authenticator`, `controllerManager`, `scheduler` | Audit trail for a payment ledger |
| Secrets encryption | Envelope encryption of Kubernetes Secrets with a customer-managed KMS key | etcd is encrypted at rest under a controlled key (H7) |
| Authentication mode | EKS access entries (`API` or `API_AND_CONFIG_MAP`) | Access is granted per IAM principal and can be limited to namespaces (§5.7) |
| Service CIDR | `172.20.0.0/16` in testing. Must not overlap the VPC or anything reachable over the Transit Gateway | Cannot be changed after the cluster is created |

### 5.2 The ledger node group

| Setting | Value | Why |
| :---- | :---- | :---- |
| Type | Managed node group | AWS-managed rolling updates that respect PodDisruptionBudgets |
| Instance type | `m6i.xlarge` class (4 vCPU, 16 GiB) | Load tests showed it is the right size for a validator. It is offered in all three `af-south-1` AZs. |
| Size | **At least 4 nodes, across all 3 AZs** | One validator per node. With fewer than 4 schedulable nodes, the 4th validator stays `Pending`, by design. |
| Subnets | Dedicated ledger subnets if possible, otherwise the application subnets | §4.4 |
| Taint and label | e.g. `dedicated=besu-ledger:NoSchedule`, with a matching label | Only ledger pods tolerate the taint, so no other workload lands on these nodes (#28) |
| AMI | Amazon Linux 2023 (EKS-optimised) | Any custom user data must be MIME multipart on AL2023, or the node never finishes joining |
| Instance metadata | IMDSv2 required, **hop limit 1** | With hop limit 1, a pod cannot reach the node's metadata service and use the node role. Ledger pods use their own IAM roles (§5.6). (H21) |
| Root volume | gp3, encrypted | — |
| Update setting | `max_unavailable = 1` | One node at a time during managed updates |
| Node IAM role | `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonSSMManagedInstanceCore`. **No** Secrets Manager or KMS access | Only the validator pods' own roles can read keys. `ContainerRegistryReadOnly` includes `ecr:GetAuthorizationToken`, which a repository policy cannot grant. (#38) |
| Access | SSM only, no SSH key | — |

**Without a dedicated node group,** the ledger runs on shared nodes with NetworkPolicy (§5.3) as the main boundary, and the weaker security is recorded in the design. One combination is not acceptable: **shared nodes and NetworkPolicy that nothing enforces**. The deployment refuses to proceed in that case. (CG-9)

### 5.3 Pod networking

* **AWS VPC CNI**, the managed add-on.
* **NetworkPolicy enforcement on.** On current VPC CNI versions this appears as `--enable-network-policy=true` on the `aws-eks-nodeagent` container of the `aws-node` DaemonSet. Calico or Cilium also work. Without enforcement, default-deny policies are accepted by the API server and do nothing, and any pod in the cluster could reach the validators' admin RPC. Enforcement is proven with a connection that must be refused, not by reading the setting. (#35, D-37)
* **Warm-pool tuning** on the ledger nodes, as in §4.3.
* **How the NLBs reach RPC pods.** The NLBs send traffic straight to pod IPs, so it arrives at the node security group. One of:
  * a rule on the node security group allowing TCP 8545–8546 **from the ledger NLBs' security groups**, or
  * **Security Groups for Pods** (`ENABLE_POD_ENI=true`), so that a dedicated security group is attached to the RPC pods. (#33)

What the ledger namespaces contain:

* **Default-deny NetworkPolicy** for both ingress and egress.
* **Explicit allows** for P2P between ledger pods, RPC from the NLB ranges, metrics from Prometheus, DNS, and Blockscout to the explorer RPC pool.
* **The admin RPC listener** (QBFT, ADMIN and permissioning methods) is a ClusterIP service with no NLB. It is reachable only through `kubectl port-forward` from the runner.

### 5.4 Required add-ons

| Add-on | What the ledger uses from it | If missing |
| :---- | :---- | :---- |
| `vpc-cni`, `coredns`, `kube-proxy` (EKS-managed) | — | — |
| EBS CSI driver | Persistent volumes | **No workaround.** The chain needs disks |
| AWS Load Balancer Controller | `TargetGroupBinding`: ledger pods registered into NLB target groups created in Terraform | **No workaround.** No SWIFT endpoint. The controller's IAM policy must allow `RegisterTargets` on target groups **without** the `elbv2.k8s.aws/cluster` tag; otherwise registration fails in the controller's log and the target group simply stays empty. |
| Secrets Store CSI driver + AWS provider | `SecretProviderClass`: validator keys mounted from Secrets Manager into memory | Keys fetched at pod start instead. Acceptable |
| Prometheus Operator | `PodMonitor`, `PrometheusRule` | A plain Prometheus in the ledger namespace. Acceptable |
| Log shipping (Fluent Bit or similar) | Container logs in a CloudWatch log group the platform team can read and alarm on | Sidecar per pod. Acceptable |

### 5.5 Storage

The ledger uses one StorageClass:

| Setting | Value | Why |
| :---- | :---- | :---- |
| `type` | `gp3`, `encrypted: "true"` | — |
| `volumeBindingMode` | **`WaitForFirstConsumer`** | With `Immediate`, a volume can be created in a different AZ from the pod that needs it, and that validator never starts |
| `allowVolumeExpansion` | **`true`** | The chain grows forever. Without expansion, the first sign of trouble is a full disk. |
| `reclaimPolicy` | `Delete` (test) / `Retain` (production) | — |
| KMS key | Owner recorded in the design | If the key belongs to another team, a change to its policy can stop the ledger, so the dependency must be recorded |

### 5.6 Pod identity

Every pod that calls AWS has **its own IAM role**. The node role grants no access to ledger data.

* **IRSA** (current), or **EKS Pod Identity**. Either works. Pod Identity also needs the `eks-auth` endpoint. (#31)
* **Every workload trust policy checks both `sub = system:serviceaccount:<namespace>:<sa>` and `aud = sts.amazonaws.com`.** On a shared cluster, a trust policy that checks only the OIDC provider can be assumed by **any pod in any namespace**. The deployment refuses a trust policy that lacks these conditions. (CG-5)
* **Silent fallback.** If a pod's identity is not set up, the AWS SDK falls back to the node role, and may well work with wider access than intended. Hop limit 1 (§5.2) blocks that path, and the post-deploy check asks each pod which role it is running as. (#31)

### 5.7 Tenancy: namespaces, quota, admission and access

| Item | Value | Why |
| :---- | :---- | :---- |
| Namespaces | Two: `ledger` and `app` | RBAC, quotas and Pod Security are set per namespace. Application pods, including the SWIFT event listener, must not share them with validators. (#27) |
| Pod Security level | **`baseline`** | One validator init step runs as root to set file ownership on the permissions file. `restricted` refuses it. (D-33) |
| ResourceQuota keys | `requests.cpu`, `requests.memory`, `limits.memory`, `pods`, `persistentvolumeclaims`, `requests.storage` | — |
| ResourceQuota values (ledger) | 8 vCPU / 24 GiB requests, 48 GiB memory limits, 40 pods, 12 PVCs / 300 GiB | Measured needs plus about 30% |
| **No `limits.cpu`** in the quota | — | A quota that names a resource refuses any pod without that resource set, including init containers. The charts set CPU requests but no CPU limits. |
| Runner access | EKS access entry for the runner's role with `AmazonEKSEditPolicy` **limited to the two ledger namespaces**, plus a Role covering `TargetGroupBinding`, `SecretProviderClass`, `PodMonitor` and `PrometheusRule` | Least privilege. Access that is too broad works just as well as correct access, so the deployment tests that it **cannot** reach outside the ledger namespaces. (#32, D-37) |

**A quota that is slightly too small looks like success.** Three validators start, the chain produces blocks, and every dashboard is green, while the fourth validator is refused and the ledger is one failure away from stopping. The post-deploy check therefore counts validators in the block-producing set, rather than just looking for errors. (D-36)

### 5.8 Validator placement

| Control | Setting | Effect |
| :---- | :---- | :---- |
| Pod anti-affinity | **Required**, by `kubernetes.io/hostname`, validators only | Two validators can never share a node. A spread constraint cannot guarantee this: `maxSkew: 1` still allows 2/1/1 across three nodes. (D-39) |
| Topology spread | By `topology.kubernetes.io/zone`, **`ScheduleAnyway`** | Spread across AZs as evenly as possible. It cannot be strict, because 4 validators across 3 AZs can never be even. |
| PodDisruptionBudget | `maxUnavailable: 0` on validators | A normal drain waits instead of evicting a validator |
| StatefulSet update strategy | `OnDelete`, changed only by the rolling script | A Helm upgrade never restarts all four validators at once (H1) |
| Tolerations / node selector | Match the ledger node group's taint and label | — |

### 5.9 Node maintenance and Kubernetes upgrades

**This is where the platform is most exposed.** A managed node group update run with `--force` ignores PodDisruptionBudgets. If it removes two validators, the ledger stops. No configuration can prevent this; only the maintenance procedure can:

1. **Never force-drain a ledger node.**
2. **One ledger node at a time.** After each node, wait until its validator is back and producing blocks. A one-line health check is provided for automation to wait on.
3. **Five working days' notice** of node rotation and Kubernetes upgrades, with a window the platform team can join. Besu is tested against the new Kubernetes version within those five days.
4. **If the rotation tooling cannot do 1 and 2,** the ledger node group is excluded from automated rotation and rotated manually under change control.

If something goes wrong anyway, it is detected quickly. Alarms fire when any validator leaves the block-producing set for more than five minutes (one down is survivable; this is the warning), and again when blocks stop. (D-42)

---

## 6. Traffic into the ledger

| Client | Path | Controls |
| :---- | :---- | :---- |
| **SWIFT** | SIPN → internal NLB (TCP pass-through, IP targets, cross-zone) → SWIFT RPC pods | NLB security group admits only the SIPN ranges on the RPC port. mTLS ends **at Besu**, not at the NLB. Methods are scoped to what SWIFT needs (`eth_call`, `eth_sendRawTransaction`, `eth_getLogs`). Account allowlist. |
| **Applications** | Second internal NLB → application RPC pods | Separate NLB and security group; JWT authentication; no admin methods |
| **Blockscout** | In-cluster → explorer RPC pod | NetworkPolicy; DEBUG/TRACE methods only on this pool |
| **Operators** | Laptop → SSM Session Manager → runner → `kubectl port-forward` | No public endpoint, no SSH, no bastion with a public IP |

**Why TCP pass-through:** mTLS client authentication has to be checked by the process that applies the method-level rules. Ending TLS at the load balancer would put the trust decision one step away from where it is enforced.

**Why Terraform creates the NLBs, not the controller:** the target groups and listeners are reviewed in Terraform. The controller only registers pod IPs through `TargetGroupBinding`. As a result, the controller never creates load balancers, and the ledger's NLBs do not need the `internal-elb` subnet tag.

---

## 7. Security layers

| Layer | Control | Role |
| :---- | :---- | :---- |
| Network edge | No IGW/NAT, no default route, private API endpoint, internal NLBs only | Network owner, cluster operator |
| Subnet | Separate subnets per role, NACLs, flow logs | Network owner |
| Instance / ENI | Security groups per tier: SWIFT NLB, application NLB, runner, and RPC pods when Security Groups for Pods is on | Platform team; the node security group belongs to the cluster operator |
| Node | Dedicated tainted node group; IMDSv2 hop limit 1; SSM only | Cluster operator |
| Kubernetes | Separate namespaces, Pod Security `baseline`, quotas, default-deny NetworkPolicy, RBAC limited to the ledger namespaces | Cluster operator and platform team |
| Identity | One IAM role per workload, trust limited by `sub` + `aud`; node role with no data access; permissions boundary on workload roles | Platform team |
| Keys | Validator keys in Secrets Manager under the platform's customer-managed KMS key; every decrypt recorded in CloudTrail | Platform team |
| Application | mTLS + method scoping (SWIFT); JWT (applications); file-based node and account allowlists (deny by default) | Platform team |
| Supply chain | Images pinned by digest, copied into ECR without being rebuilt, tag immutability on, no expiry | Platform team (pipeline), registry owner (registry) |

---

## 8. How code and images get in, and how deployments run

```
GitHub (outside the bank network)
  ├─ supply-chain.yml ── crane copy by digest ──▶ ECR (shared-services account)
  └─ release.yml ────── versioned package ─────▶ Octopus Cloud feed
                                                    │
Octopus Cloud ── besu-infra (AWS-API Terraform) ── hosted worker ─▶ AWS APIs
              └─ besu-workloads, besu-validators ── polling Tentacle on the In-VPC EC2 Runner
                                                    (via the shared egress proxy, outbound only)
                                                    │
In-VPC EC2 Runner ── VPC endpoints + private EKS endpoint ─▶ ledger namespaces
```

* **GitHub Actions never deploys.** It copies images, validates, packages and publishes. Octopus deploys. (CD-2)
* **Images are copied with `crane copy`, by digest.** `docker pull`/`tag`/`push` rebuilds the manifest, which changes the digest and breaks every pin. (D-18)
* **No pull-through cache.** ECR's pull-through cache needs an internet route the first time an image is pulled through an interface endpoint. (D-17)
* **The runner** is one EC2 instance in a private subnet. It has no public IP and no SSH, and is reached only through Session Manager. Its tools and the platform source arrive as a **digest-checked bundle in S3**, over the S3 gateway endpoint. It needs no package repositories. Terraform providers come from a local file mirror in that bundle. (D-20, D-21)
* **Validators are never deployed by a normal Helm step.** The `besu-validators` project runs the one-at-a-time script behind a manual approval in every environment. (CD-5)
* **Terraform state lives in an S3 bucket in the deploy region.** The runner's S3 gateway endpoint serves only buckets in its own region. A bucket elsewhere hangs, and would also put ledger state outside the region. (B49)

---

## 9. Observability

* **Metrics:** Besu metrics on 9545, collected by the cluster's shared Prometheus (`PodMonitor`) or by a dedicated instance in the ledger namespace.
* **Logs:** container logs go to a CloudWatch log group the platform team can read. EKS control-plane logs belong to the cluster operator.
* **Alarms → SNS → operators:**
  * a validator out of the block-producing set for more than 5 minutes;
  * block height not advancing;
  * pod sandbox creation failures in the ledger namespace, which is how address exhaustion shows up;
  * NLB targets unhealthy.
* **Audit:** CloudTrail records every KMS decrypt of a validator key. The platform team needs read access to CloudTrail for its resources.

---

## 10. Test evidence

The test environment reproduces the target setup in three parts:

* **A VPC** built as in §4: 15 subnets, deny-by-default NACLs from the §4.7 flows, no IGW or NAT.
* **An egress proxy** reached over a peering connection standing in for the Transit Gateway, with an allowlist for one source and two destinations.
* **An EKS cluster** with a namespace-limited access entry.

The test cluster is **misconfigured by default**: a `restricted` namespace, a quota that is too small, a missing controller, a public endpoint. That proves each check actually fires, rather than only ever being seen to pass.

| Date | Result |
| :---- | :---- |
| 9 Oct 2026 | Every cluster check refused the misconfigured cluster with the right requirement number |
| 10 Oct 2026 | Cluster traffic (C-1 to C-4) proven under deny-by-default NACLs. First deployments from Octopus over the egress path. Runner address reservation proven. Node-role image pull proven with a test pod. |
| 11 Oct 2026 | Full chain deployed from Octopus with no internet access (19 releases, all from the ECR mirror). **4 validators on 4 distinct nodes** producing 5-second blocks. A transaction confirmed on-chain and in Blockscout. Teardown left nothing behind. |

One known gap: the post-deploy check reported #33 as failing, because the test cluster has no Security Groups for Pods. In the target environment, the choice made for #33 (§5.3) resolves it.

---

## 11. Rebuilding the VPC and EKS layer

This section is the build sheet for anyone who has to reproduce the network and cluster the ledger runs on: the network owner and cluster operator under model C or B, or the platform team under model A. Every value below is the one used in the test environment, which was built from this design and deployed the full chain (§10). The working Terraform for each part is listed in §11.9.

### 11.1 Decide these first

Several of these cannot be changed once the resource exists.

| Input | Test value | Notes |
| :---- | :---- | :---- |
| Region | `af-south-1` | Opt-in region; enable it on the account first |
| AZ IDs | `afs1-az1`, `afs1-az2`, `afs1-az3` | IDs, never names (§4.1). All three are needed |
| Primary VPC CIDR | `10.60.0.0/20` | **Cannot be changed after creation.** A `/20` per environment is the design size; `/21` is the lowest that keeps the same layout (§11.2) |
| Secondary CIDR | `100.64.0.0/16` | RFC 6598. Attached, **no subnets in it**. It is held for CNI custom networking if addresses run short (§4.4) |
| EKS service CIDR | `172.20.0.0/16` | **Cannot be changed after the cluster is created.** Must not overlap the VPC or anything reachable over the Transit Gateway |
| Egress proxy prefix and port | `10.61.0.0/24`, port `3128` | The bank's shared proxy in production (§4.9) |
| In-VPC EC2 Runner address | `10.60.0.250` (ledger subnet, `afs1-az1`) | A fixed /32: the proxy allows only this source |
| SIPN source ranges | VPC CIDR (no SIPN in testing) | The ranges SWIFT connects from; used in the lb NACL and the SWIFT NLB security group |
| Kubernetes version | `1.36` | Inside the tested range, 1.33 to 1.36 (§5.1) |
| Dedicated ledger subnets and node group | Yes | §4.4, §5.2 (#28). If no, the ledger nodes go in the app subnets and the ledger subnets hold only the runner |
| Pod identity | IRSA | Pod Identity also needs the `eks-auth` endpoint (§5.6) |
| Same size in every environment | SIT, UAT and PROD identical | SIT and UAT only rehearse PROD properly if they have the same layout |

### 11.2 Address plan: the 15 subnets

Each role gets one subnet per AZ. For `10.60.0.0/20`:

| Role | `afs1-az1` | `afs1-az2` | `afs1-az3` | Size | Usable each |
| :---- | :---- | :---- | :---- | :---- | :---- |
| ledger | `10.60.0.0/24` | `10.60.1.0/24` | `10.60.2.0/24` | /24 | 251 |
| app | `10.60.4.0/23` | `10.60.6.0/23` | `10.60.8.0/23` | /23 | 507 |
| lb | `10.60.10.0/26` | `10.60.10.64/26` | `10.60.10.128/26` | /26 | 59 |
| endpoint | `10.60.11.0/26` | `10.60.11.64/26` | `10.60.11.128/26` | /26 | 59 |
| data | `10.60.12.0/26` | `10.60.12.64/26` | `10.60.12.128/26` | /26 | 59 |

**Reserve, not allocated (1,216 addresses):** `10.60.3.0/24`, `10.60.10.192/26`, `10.60.11.192/26`, `10.60.12.192/26`, `10.60.13.0/24` and `10.60.14.0/23`. AWS keeps 5 addresses in every subnet, which is why a /24 has 251 usable addresses, not 256.

**For any other `/20`,** keep the same offsets from the base address. In Terraform: `cidrsubnet(vpc_cidr, newbits, base + az_index)` with ledger `(4, 0)`, app `(3, 2)`, lb `(6, 40)`, endpoint `(6, 44)` and data `(6, 48)`. AZ index 0, 1 and 2 follow the sorted AZ IDs.

**If only a `/21` is available,** the ledger subnets keep their size and the rest shrink. This uses 1,440 addresses and leaves 608:

| Role | Size per AZ | Usable each | Cost |
| :---- | :---- | :---- | :---- |
| ledger | /24 | 251 | None |
| app | /25 | 123 | Less room for application node groups and for running old and new node groups side by side during an upgrade |
| lb, endpoint, data | /27 | 27 | The endpoint subnet must not be smaller than /27: each AZ holds one ENI per interface endpoint (15 today) |

**Below a `/21` the layout does not fit** with default CNI settings. A `/22` needs a tuned CNI and /25 ledger subnets (about 2 nodes per AZ before tuning). A `/24` needs pod addresses moved to the secondary CIDR with CNI custom networking. The `/24` allocations first offered for SIT and PROD fall into the last case (`CIDR_ALLOCATION_REVIEW.md`, which has the full arithmetic).

### 11.3 Subnet and route table settings

| Item | Setting |
| :---- | :---- |
| Placement | `availability_zone_id`, never `availability_zone` |
| Public IPs | `map_public_ip_on_launch = false` on all 15 |
| Tags on every subnet | `Name`, `Role` (`ledger`/`app`/`lb`/`endpoint`/`data`), `AzId` |
| Extra tags on **lb subnets only** | `kubernetes.io/role/internal-elb = 1`, `kubernetes.io/cluster/<cluster-name> = shared`. Tagging other subnets would let the load-balancer controller place a load balancer in ledger or endpoint subnets |
| Route tables | **15, one per subnet** (§4.5, #12). Only the automatic `local` routes for both CIDRs |
| Gateway endpoint routes | S3 and DynamoDB associated with the **ledger, app, lb and endpoint** tables (12 tables). Not data |
| Runner subnet's table only | One route: the egress proxy prefix → Transit Gateway. Never `0.0.0.0/0` |
| Runner address | An **explicit subnet CIDR reservation** for its /32 in its ledger subnet (`aws_ec2_subnet_cidr_reservation`, `reservation_type = explicit`) (B43) |
| DHCP option set | `domain-name-servers = AmazonProvidedDNS`, `domain-name = af-south-1.compute.internal` |
| Flow logs | VPC level, all traffic, to CloudWatch Logs; plus ledger-subnet logs the platform team can read (§4.10) |

### 11.4 NACL rules

If NACLs are used, each subnet gets its own NACL, denying all traffic except the rules below. This is the rule set that was applied and tested, written for the 20-rule default quota: service ports use per-subnet sources, while return traffic uses the VPC CIDR, because narrowing return rules protects little (§4.6). "app ×3" means one rule per app subnet CIDR. Security groups (§11.6) remain the service boundary; these rules only separate subnet roles.

**Workload subnets** (the subnets the ledger nodes run in, and the runner's subnet):

| In # | Proto | Ports | Source | Flow |
| :---- | :---- | :---- | :---- | :---- |
| 100–102 | TCP | 30303 | app ×3 | F-1 P2P |
| 105–107 | UDP | 30303 | app ×3 | F-1 discovery |
| 110–112, 115–117 | TCP, UDP | 30303 | ledger ×3 | F-1, only when nodes run in the ledger subnets |
| 120–122 | TCP | 8545–8546 | lb ×3 | F-2 RPC and health checks |
| 130 | TCP | 9545 | VPC | F-4 metrics |
| 140 | TCP | 1024–65535 | VPC | Returns from endpoints (F-5) and database (F-9); C-3 control plane → kubelet; C-4 pod ↔ pod |
| 150 | TCP | 1024–65535 | S3 ranges | F-6 return |
| 170 | UDP | 1024–65535 | VPC | F-10 and C-2 DNS replies |
| 190 | TCP | 1024–65535 | Proxy prefix | F-8 return |
| 200 | TCP | 443 | VPC | C-1 nodes → API; F-7 runner → API |
| 210, 220 | UDP, TCP | 53 | VPC | C-2 pods → CoreDNS |

| Out # | Proto | Ports | Destination | Flow |
| :---- | :---- | :---- | :---- | :---- |
| 100–102 | TCP | 30303 | app ×3 | F-1 P2P |
| 105–107 | UDP | 30303 | app ×3 | F-1 discovery |
| 110–112, 115–117 | TCP, UDP | 30303 | ledger ×3 | F-1, only when nodes run in the ledger subnets |
| 120 | TCP | 1024–65535 | VPC | F-3 return to the NLBs; F-4 reply; C-3, C-4 |
| 140–142 | TCP | 443 | endpoint ×3 | F-5 AWS APIs |
| 150 | TCP | 443 | S3 ranges | F-6 S3 |
| 160–162 | TCP | 5432 | data ×3 | F-9 database |
| 170, 175 | UDP, TCP | 53 | VPC | F-10 DNS, C-2 |
| 180 | TCP | 443 | VPC | F-7 runner → API; C-1 |
| 190 | TCP | proxy port | Proxy prefix | F-8 runner → proxy |
| 200 | UDP | 1024–65535 | VPC | C-2 CoreDNS replies |

That is 17 rules in and 19 out. **With the ledger-subnet P2P rules added it exceeds 20**: either raise the quota to 40, merge the app and ledger ranges into one source, or use security groups only (§4.6).

**lb subnets:** in TCP 8545–8546 from the SIPN ranges, and TCP 1024–65535 from the node subnets (F-3). Out TCP 8545–8546 to the node subnets (F-2), and TCP 1024–65535 to the SIPN ranges.
**endpoint subnets:** in TCP 443 from the VPC; out TCP 1024–65535 to the VPC.
**data subnets:** in TCP 5432 from the node subnets; out TCP 1024–65535 to the node subnets.

**S3 ranges:** a NACL cannot reference a prefix list, so list the entries of `com.amazonaws.af-south-1.s3` (`aws ec2 get-managed-prefix-list-entries`). The test used `0.0.0.0/0`, which has no internet route behind it but is wider than needed.

**Rule numbers are identities.** Leave gaps, and add new flows at new numbers rather than renumbering, or every later rule is replaced and briefly stops allowing its traffic.

### 11.5 VPC endpoints

| Item | Setting |
| :---- | :---- |
| Interface endpoints | The 15 in §4.8 (`eks-auth` and `autoscaling` only if needed), each with **one ENI in each endpoint subnet** (45 ENIs) |
| Private DNS | On, for every interface endpoint |
| Endpoint security group | Inbound TCP 443 from the primary and secondary VPC CIDRs. Nothing else |
| Gateway endpoints | S3 and DynamoDB, on the 12 route tables in §11.3 |
| Policies | The three traps in §4.8: the S3 policy allows the ECR layer bucket, Private DNS is on for ECR, and the ECR policy is not limited to one account |

### 11.6 EKS cluster

| Item | Setting |
| :---- | :---- |
| Cluster subnets | The **node subnets** (ledger, or app if the ledger subnets are not used). EKS places control-plane ENIs in some of them, so C-1 must cross AZs (B27) |
| API endpoint | Private access on, public access off |
| Service CIDR | Set explicitly: `kubernetes_network_config.service_ipv4_cidr = 172.20.0.0/16` (§11.1) |
| Cluster IAM role | `AmazonEKSClusterPolicy` |
| Authentication | `API_AND_CONFIG_MAP`, creator gets admin at creation |
| Secrets encryption | Customer-managed KMS key, rotation on, resource `secrets` |
| Control-plane logs | `api`, `audit`, `authenticator`, `controllerManager`, `scheduler`, to `/aws/eks/<cluster>/cluster` (90 days) |
| OIDC provider | Created from the cluster issuer, client ID `sts.amazonaws.com` (IRSA) |
| Additional cluster security group | Outbound all. The EKS-created cluster security group is the node security group referred to below |

**Ledger node group** (the settings in §5.2):

| Item | Setting |
| :---- | :---- |
| Instances | `m6i.xlarge`, Amazon Linux 2023, managed node group |
| Size | desired = min = max = **4** (one validator per node; add more only for spare capacity) |
| Subnets | The three ledger subnets |
| Launch template | gp3 root volume, 50 GiB, encrypted; IMDSv2 required, hop limit 1 |
| Updates | `max_unavailable = 1` |
| Taint, label | `dedicated=besu-ledger:NoSchedule`, label `workload=besu-ledger` |
| Node role | The four policies in §5.2, nothing else |
| Node security group rule | Inbound TCP 8545–8546 from the ledger NLBs' security groups (#33). The NLB security groups are created by the platform; in testing the VPC CIDR was used until they existed |

**Add-ons**, with versions pinned:

| Add-on | Setting |
| :---- | :---- |
| `vpc-cni` | `enableNetworkPolicy = "true"`. Warm-pool tuning (§4.3) is recommended, but the test ran with defaults, so no values have been tested yet |
| `coredns`, `kube-proxy` | Defaults |
| `aws-ebs-csi-driver` | With its own IRSA role |
| AWS Load Balancer Controller, Secrets Store CSI driver + AWS provider, Prometheus Operator, Fluent Bit | As §5.4. Their images come from ECR like everything else. In testing the platform installed these (and the EBS driver) itself; on a shared cluster they are the cluster operator's |

**Ledger tenancy:**

| Item | Setting |
| :---- | :---- |
| Namespaces | `besu-ledger`, `besu-app` |
| Pod Security labels | `enforce`, `audit` and `warn` all `baseline` |
| ResourceQuota (`besu-ledger`) | `requests.cpu: 8`, `requests.memory: 24Gi`, `limits.memory: 48Gi`, `pods: 40`, `persistentvolumeclaims: 12`, `requests.storage: 300Gi`. **No `limits.cpu`** (§5.7) |
| StorageClass | `ebs.csi.aws.com`, `gp3`, encrypted, `WaitForFirstConsumer`, `allowVolumeExpansion: true` |
| Runner access entry | `STANDARD` type for the runner's IAM role; `AmazonEKSEditPolicy` scoped to the two namespaces |
| Role in `besu-ledger` | Full verbs on `targetgroupbindings` (`elbv2.k8s.aws`), `secretproviderclasses` (`secrets-store.csi.x-k8s.io`), `podmonitors` and `prometheusrules` (`monitoring.coreos.com`), bound to the runner's access entry |

### 11.7 Build order

| Step | What | Check before moving on |
| :---- | :---- | :---- |
| 0 | Confirm the region is enabled, the AZ IDs, `m6i.xlarge` in all three AZs, every endpoint service, and the Kubernetes version | `scripts/preflight/verify-region.sh af-south-1 m6i.xlarge 1.36` (read-only, free) |
| 1 | VPC (tenancy `default`, both DNS attributes on), secondary CIDR, DHCP option set, flow logs | §4.2 |
| 2 | 15 subnets, 15 route tables, associations | 15 distinct CIDRs; no `0.0.0.0/0` route anywhere |
| 3 | S3 and DynamoDB gateway endpoints on the 12 route tables | Prefix-list routes present |
| 4 | Endpoint security group and the 15 interface endpoints | Private DNS on; each name resolves to a VPC address from inside the VPC |
| 5 | NACLs and their rules (§11.4), or record that security groups alone are used | Includes C-1 to C-4, or the node in the AZ without a control-plane ENI never joins |
| 6 | Transit Gateway attachment, the proxy route in the runner subnet's table, the proxy allowlist entry for the runner's /32, and the explicit reservation of that /32 | §4.9 |
| 7 | EKS cluster: IAM role, KMS key, log group, cluster, OIDC provider | Endpoint private only; service CIDR as agreed |
| 8 | Ledger node group | 4 nodes `Ready`, spread across 3 AZs |
| 9 | Add-ons | NetworkPolicy enforced (proven with a connection that must be refused, §5.3) |
| 10 | Namespaces, quota, StorageClass, Role, runner access entry | Needs the runner's role ARN from the platform team |
| 11 | Node security group rule for the NLBs (#33) | Needs the platform's NLB security group IDs |
| 12 | Hand the values in §11.8 to the platform team | The platform's checks pass (below) |

After step 12 the platform team runs its read-only checks before building anything: the network contract (Terraform plan), `verify-endpoints.sh`, `verify-subnet-rules.sh`, `verify-cluster.sh`, `verify-admission.sh` and `verify-pull-canary.sh`. Each failure names the requirement number it breaks.

### 11.8 What the platform needs back

The platform does not read another team's Terraform state (D-25). It needs these values as plain text, keyed by AZ ID where per-AZ.

**Network:** `vpc_id`, `vpc_cidr_primary`, `vpc_cidr_secondary`, `dhcp_options_id`, region, `az_ids`; subnet IDs and CIDRs for each of the five roles; route table IDs for ledger, app, lb and endpoint; ledger NACL IDs; whether the gateway endpoints already exist and whether the interface endpoints are central.

**Egress:** proxy host, proxy port, and the allowed source /32.

**Cluster:** cluster name, endpoint, CA data, version; OIDC provider ARN and issuer URL; IRSA or Pod Identity; the two namespace names and their Pod Security level; StorageClass name and its KMS key ARN; which of the four add-ons in §5.4 are provided; whether the node group is dedicated, and its taint and label; node security group ID, node role ARN, node subnet IDs, lb subnet IDs; whether NetworkPolicy is enforced; whether the runner's access entry exists.

### 11.9 Reference implementation

The test environment builds all of this from three Terraform projects in this repository. They can be read as a working example, or applied in another account:

| Project | Builds | Notes |
| :---- | :---- | :---- |
| `mimic_vpc/terraform` | VPC, secondary CIDR, DHCP, flow logs, 15 subnets, 15 route tables, NACLs, gateway endpoints, runner IP reservation | Subnet plan in `locals.tf`; NACL rules in `modules/subnets/nacl.tf`; `scripts/emit-handover.sh` writes the §11.8 network values |
| `mimic_egress/terraform` | A stand-in for the shared egress proxy, reached over peering | Not needed where the bank's proxy and Transit Gateway exist |
| `mimic_eks/terraform` | Cluster, node group, add-on settings, runner access entry, tenancy manifest | **Defaults to `profile = "hostile"`**, which is deliberately misconfigured to prove the platform's checks (§10). Set `profile = "strict"` to get the configuration in §11.6 |

The interface endpoints are built by the platform's own `sbsa_besu/terraform/shared` root in testing, because there are no central endpoints there.

---

## 12. Decisions log

| ID | Decision | Reason |
| :---- | :---- | :---- |
| D-2 | Network inputs are checked, never assumed. The contract module creates nothing. | Fail in seconds with a requirement number, not 20 minutes into an apply |
| D-3 | Design for a true air gap; egress is a bonus, never a dependency | Besu needs no internet. Every outbound dependency is a failure mode. |
| D-9 | NetworkPolicy default-deny is mandatory | The main tenant boundary on a shared cluster |
| D-15 | VPC tenancy `default` | `dedicated` cannot be reversed and costs about USD 1,460 a month |
| D-16 | ECR is the only registry | IAM-native, endpoint-reachable, no private CA, no pull secret |
| D-17 | No pull-through cache | It needs an internet route |
| D-18 | Copy images by digest (`crane`/`skopeo`) | Keeps digest pins valid |
| D-20, D-21 | Runner gets tools and providers from an S3 bundle; no package manager | Nothing on the runner reaches the internet |
| D-23 | The platform never creates network or cluster-wide Kubernetes resources | Clear ownership; the code fails safe in a shared environment |
| D-24 | Cluster add-ons are provided by the cluster operator; the platform checks them and never installs them | A namespace tenant cannot install DaemonSets, CRDs or webhooks |
| D-25 | Network and cluster facts reach the platform as plain variables, never through another team's Terraform state | State access across teams is neither available nor desirable |
| D-26 | Dedicated, tainted ledger node group in ledger subnets | A payment ledger should not share a kernel with other tenants |
| D-27 | Node maintenance follows a written procedure | A forced drain is the most likely cause of a halt; no setting prevents it |
| D-28 | One cluster, two namespaces | Ledger and application isolation without a second cluster |
| D-29 | Subnet rules are checked against the flow table before each build | Blocked flows hang; they do not error |
| D-33, D-40 | Pod Security is checked by dry-running a bare Pod; warnings fail the check | A StatefulSet dry-run only warns, and a cluster-wide setting does not show in labels |
| D-36 | Post-deploy checks count things: 4 validators producing, 4 distinct nodes | The worst failure looks healthy |
| D-37 | Boundaries are proven by checks that must be refused | Access that is too broad, and policies nobody enforces, both look like success |
| D-38 | Image pull is proven by a test pod running under the node role | The deployer's credentials are not the node role's |
| D-39 | Required anti-affinity: one validator per node | A spread constraint cannot guarantee it |
| D-41 | Highest tested Kubernetes version enforced at plan time | Upgrades break the *next* deployment, not the upgrade itself |
| D-42 | Detective alarms for validator loss | There is no preventive control for a forced drain |
| D-43 | Free-IP margin checked before deploy, plus alarms | Free-address counts on shared subnets change with other tenants |
| CD-2 | GitHub Actions never deploys | Only Octopus touches environments |
| CD-5 | Validators change only through the one-at-a-time script, behind approval | A normal Helm step restarts all four together |
| CD-55–CD-62 | Octopus reaches the cluster through a polling Tentacle on the runner, via the shared proxy: two hostnames, no TLS inspection, /32 source | Outbound only; no public cluster endpoint; the smallest possible egress opening |
| B43 | Reserve the runner's IP in its subnet | The CNI's spare-address pool took it in testing |
| B49 | State bucket in the deploy region | The S3 gateway endpoint serves same-region buckets only |
| H1 | Validators: `OnDelete` + `ignore_changes` + rolling script | A blanket apply must never restart all four |
| H7, H21 | Secrets encryption with a CMK; IMDSv2 hop limit 1 | Defence in depth for keys and pod identity |

---

## 13. Open design items

These items depend on how the target environment is configured, and each one shapes part of the architecture:

1. Node maintenance procedure in §5.9 agreed and documented (#29)
2. Ledger node group dedicated and tainted, and its subnets (#28)
3. Subnet rules implemented as NACLs, security groups or both (#34)
4. NLB-to-pod path: node security group rule, or Security Groups for Pods (#33)
5. NetworkPolicy enforcement in the CNI (#35)
6. Pod identity mechanism: IRSA or Pod Identity (#31)
7. Available add-ons, and any tag condition in the load-balancer controller's IAM policy (#30)
8. Kubernetes version and upgrade schedule (#36)
9. Free addresses in the node, lb and runner subnets, and the reservation on the runner's IP (#39, B43)
10. A Terraform state bucket in `af-south-1` (§8)

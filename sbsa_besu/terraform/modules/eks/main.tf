# =============================================================================
# modules/eks/main.tf
# -----------------------------------------------------------------------------
# PURPOSE
#   Provisions the EKS cluster and everything required for it to host Besu:
#     * Cluster IAM role (control plane permissions)
#     * The EKS cluster itself, with a PRIVATE API endpoint (no public access)
#       and control-plane logging to CloudWatch
#     * The IAM OIDC provider (enables IRSA — see modules/iam)
#     * Node IAM role + a MANAGED NODE GROUP using a launch template that pins
#       gp3 volumes, enforces IMDSv2, and tags instances/volumes
#     * Core addons: vpc-cni (CNI networking), coredns, kube-proxy, and the
#       EBS CSI driver (handled in modules/storage-csi for the IRSA part)
#
# WHY A PRIVATE API ENDPOINT
#   The requirement is "nothing public". A public EKS API endpoint is a control-
#   plane attack surface. With endpoint_public_access = false, kubectl/helm must
#   reach the API over private networking (from within the VPC, a peered VPC, a
#   bastion via SSM, or a VPN). This is the correct posture for a financial
#   private network. (Operators access it via SSM Session Manager or the
#   app/ops VPC; documented in the manual guide.)
#
# WHY MANAGED NODE GROUP (vs self-managed)
#   Managed node groups give AWS-orchestrated, PDB-respecting rolling updates
#   for node AMI/version changes — exactly the safety property we need so an
#   EKS upgrade drains nodes ONE AT A TIME without violating the validator
#   PodDisruptionBudget (defined later in the Helm chart). They also reduce the
#   operational surface vs self-managing ASGs.
#
# WHY A LAUNCH TEMPLATE
#   The managed node group references a launch template so we can:
#     * force gp3 (cheaper/faster than gp2) for the node volume
#     * require IMDSv2 (http_tokens = required) — blocks SSRF-style credential
#       theft from the instance metadata service
#     * apply consistent tags to instances AND their EBS volumes
#
# WHY CNI (vpc-cni addon)
#   The quorum-kubernetes AWS guidance uses CNI so every pod gets a real VPC IP.
#   This is what makes external node
#   connectivity feasible. It is the default EKS networking mode via the
#   amazon-vpc-cni addon.
# =============================================================================

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# CONTROL PLANE IAM ROLE
# The EKS service assumes this to manage AWS resources on the cluster's behalf
# (ENIs, load balancers, etc.). Uses the AWS-managed AmazonEKSClusterPolicy.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name                 = "${var.name_prefix}-eks-cluster-role"
  assume_role_policy   = data.aws_iam_policy_document.cluster_assume.json
  permissions_boundary = var.permissions_boundary # H5: cap — no IAM/org/account mutation
  tags                 = merge(var.tags, { Component = "eks" })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# -----------------------------------------------------------------------------
# CONTROL PLANE SECURITY GROUP
# Dedicated SG for the cluster control-plane ENIs. Node SG (created by the node
# group) and this SG are wired together by EKS automatically. We keep an
# explicit handle so later modules (RPC NLB, etc.) can reference it if needed.
# -----------------------------------------------------------------------------
resource "aws_security_group" "cluster" {
  name        = "${var.name_prefix}-eks-cluster-sg"
  description = "EKS control plane security group"
  vpc_id      = var.vpc_id

  # Egress all — the control plane needs to reach nodes and AWS services.
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-eks-cluster-sg"
    Component = "eks"
  })
}

# -----------------------------------------------------------------------------
# CONTROL PLANE LOG GROUP
# EKS writes control-plane logs here. We pre-create the log group so we control
# its retention and tags (if you let EKS create it, retention defaults to never-
# expire, which costs money and is non-compliant for log lifecycle policies).
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  tags              = merge(var.tags, { Component = "eks" })
}

# -----------------------------------------------------------------------------
# SECRETS ENVELOPE-ENCRYPTION CMK (H7)
# -----------------------------------------------------------------------------
# Dedicated customer-managed KMS key that envelope-encrypts Kubernetes Secrets in
# etcd (the EKS "secrets" resource). The default key policy (account root) is
# sufficient — EKS creates a KMS grant using the deployer's kms permissions when
# encryption is enabled. Separate from the C12 node-key CMK so the two custody
# domains have independent policies/lifecycles.
resource "aws_kms_key" "secrets" {
  count = var.enable_secrets_encryption ? 1 : 0

  description             = "${var.cluster_name} — EKS Secrets envelope encryption (H7)."
  enable_key_rotation     = true
  deletion_window_in_days = var.secrets_kms_deletion_window_days

  tags = merge(var.tags, { Component = "eks", Purpose = "eks-secrets-encryption" })
}

resource "aws_kms_alias" "secrets" {
  count = var.enable_secrets_encryption ? 1 : 0

  name          = "alias/${var.name_prefix}-eks-secrets"
  target_key_id = aws_kms_key.secrets[0].key_id
}

# -----------------------------------------------------------------------------
# THE EKS CLUSTER
# -----------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.endpoint_public_access_cidrs : null
  }

  # H7: envelope-encrypt K8s Secrets in etcd with the dedicated CMK above. One-way
  # once set (AWS does not allow removing an encryption provider from a cluster).
  dynamic "encryption_config" {
    for_each = var.enable_secrets_encryption ? [1] : []
    content {
      provider {
        key_arn = aws_kms_key.secrets[0].arn
      }
      resources = ["secrets"]
    }
  }

  # Use EKS ACCESS ENTRIES (the modern replacement for the aws-auth ConfigMap)
  # so IAM principals — notably the In-VPC EC2 Runner (stage 3) — can be granted
  # Kubernetes RBAC declaratively. API_AND_CONFIG_MAP keeps the legacy ConfigMap
  # working too. bootstrap_cluster_creator_admin_permissions keeps whoever
  # created the cluster as a cluster admin.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Enable ALL control-plane log types — for a financial network you want the
  # full audit/authenticator/controllerManager/scheduler/api logs.
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = merge(var.tags, {
    Name      = var.cluster_name
    Component = "eks"
  })

  # Ensure the log group and policy attachment exist before the cluster, so the
  # first control-plane logs land in OUR retention-managed group.
  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_cloudwatch_log_group.cluster,
  ]
}

# -----------------------------------------------------------------------------
# IAM OIDC PROVIDER  (enables IRSA)
# -----------------------------------------------------------------------------
# The cluster exposes an OIDC issuer URL. Registering it as an IAM OIDC provider
# is what lets pods exchange projected service-account tokens for IAM role
# credentials (see modules/iam). Without this, IRSA does not work.
# -----------------------------------------------------------------------------
#
# NO thumbprint, and no `tls_certificate` data source to compute one (B50). That
# data source fetched the issuer over public HTTPS on EVERY plan — and data
# sources are read even with -refresh=false, so the In-VPC EC2 Runner's
# in-cluster plan hung on it (no route to oidc.eks.<region>.amazonaws.com). IAM
# does not use the thumbprint for EKS issuers (it trusts its own CA store), and
# provider 5.x makes `thumbprint_list` optional + computed: left unset, IAM
# fills it and the plan shows no change on an existing provider.
resource "aws_iam_openid_connect_provider" "oidc" {
  url            = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-eks-oidc"
    Component = "eks"
  })
}

# -----------------------------------------------------------------------------
# NODE IAM ROLE
# Worker nodes assume this. It gets the three AWS-managed policies every EKS
# node needs: worker node policy, CNI policy, and ECR read (to pull images).
# NOTE: deliberately NO Secrets Manager access here — that is scoped to the
# IRSA role in modules/iam so only Besu pods (not all pods) can read keys.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name                 = "${var.name_prefix}-eks-node-role"
  assume_role_policy   = data.aws_iam_policy_document.node_assume.json
  permissions_boundary = var.permissions_boundary # H5: cap — no IAM/org/account mutation
  tags                 = merge(var.tags, { Component = "eks" })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Allow nodes to be managed by SSM Session Manager — this is how operators get
# a shell on nodes WITHOUT opening SSH/22 or using a bastion with a public IP.
# Reinforces "nothing public".
resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# -----------------------------------------------------------------------------
# LAUNCH TEMPLATE for the node group
# Pins gp3, enforces IMDSv2, tags instances + volumes.
# -----------------------------------------------------------------------------
resource "aws_launch_template" "node" {
  name_prefix = "${var.name_prefix}-node-"

  # ---------------------------------------------------------------------------
  # Private CA trust for the container registry (CT-3)
  # ---------------------------------------------------------------------------
  # MIME MULTIPART IS MANDATORY on AL2023. EKS appends its own
  # application/node.eks.aws NodeConfig part to whatever is here; a bare shell
  # script is not merged, the node never finishes bootstrapping, and the node
  # group rolls back after ~15 minutes with no useful message. Anything added
  # here must stay inside a MIME part.
  #
  # This runs BEFORE the first image pull, which is the whole point: containerd
  # reads the OS trust store, so a node that joins without the CA fails every
  # pull from the registry with a generic ImagePullBackOff that names neither the
  # registry nor the certificate.
  #
  # The trailing newline before the closing boundary is required by the MIME
  # parser -- without it the part is silently dropped.
  # ---------------------------------------------------------------------------
  user_data = var.extra_ca_cert_pem == "" ? null : base64encode(<<-MIME
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="//"

    --//
    Content-Type: text/x-shellscript; charset="us-ascii"

    #!/bin/bash
    set -euo pipefail
    install -d -m 0755 /etc/pki/ca-trust/source/anchors
    cat > /etc/pki/ca-trust/source/anchors/private-registry-ca.crt <<'PRIVATE_CA_PEM'
    ${trimspace(var.extra_ca_cert_pem)}
    PRIVATE_CA_PEM
    chmod 0644 /etc/pki/ca-trust/source/anchors/private-registry-ca.crt
    update-ca-trust extract
    # containerd caches the trust store at start; it is running by this point on
    # AL2023, so without a reload the first pulls still fail.
    systemctl is-active --quiet containerd && systemctl restart containerd || true

    --//--
  MIME
  )

  # Root/data volume: gp3 (cheaper + better baseline perf than gp2). Encrypted.
  # H20: encrypt under a customer CMK when data_cmk_arn is set (else the AWS-managed
  # aws/ebs key). The CMK's policy MUST allow EBS + the node/autoscaling role to use
  # it (grants), or node launch fails — supply a properly-scoped data CMK for prod.
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_volume_size_gib
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.data_cmk_arn != "" ? var.data_cmk_arn : null
      delete_on_termination = true
    }
  }

  # IMDSv2 required: blocks the classic SSRF -> instance-credential-theft path.
  # H21: hop limit = 1 so a CONTAINER cannot reach node IMDSv2 and steal the node
  # role (pods use IRSA, not IMDS). A hop limit of 2 lets pod traffic (one extra
  # network hop) reach 169.254.169.254 and assume the node's ECR/SSM/CNI role,
  # undermining the IRSA isolation the secrets design relies on. (The runner keeps
  # hop limit 2 — it runs no pods.)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Tag the EC2 instances and their EBS volumes so the Resource Group and the
  # full-delete script can find them (managed node group instances otherwise
  # carry only EKS's own tags).
  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name      = "${var.name_prefix}-node"
      Component = "eks"
    })
  }
  tag_specifications {
    resource_type = "volume"
    tags = merge(var.tags, {
      Name      = "${var.name_prefix}-node-volume"
      Component = "eks"
    })
  }

  tags = merge(var.tags, { Component = "eks" })
}

# -----------------------------------------------------------------------------
# MANAGED NODE GROUP
# -----------------------------------------------------------------------------
# update_config.max_unavailable = 1 : during a node-group version/AMI update,
# AWS replaces nodes ONE AT A TIME. Combined with the validator
# PodDisruptionBudget (Helm, later stage), this guarantees an EKS upgrade never
# drains more than one validator simultaneously — preventing the chain halt the
# Besu docs warn about.
# -----------------------------------------------------------------------------
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name_prefix}-ng"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  scaling_config {
    desired_size = var.node_count
    min_size     = var.node_min
    max_size     = var.node_max
  }

  # One node at a time during managed updates — the structural safeguard.
  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  instance_types = [var.instance_type]

  # Explicit, not defaulted: the launch template's user_data is MIME multipart,
  # which only the AL2023 families accept.
  ami_type = var.ami_type

  # Labels let us target Besu workloads to these nodes and (later) taint a
  # dedicated validator node group if you choose to isolate validators.
  labels = {
    "besu.workload" = "true"
  }

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-ng"
    Component = "eks"
  })

  # The CNI/worker/ECR policy attachments must exist before nodes join, or they
  # fail to register with the cluster.
  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]

  # Ignore desired_size drift so the cluster autoscaler can change it at runtime
  # without Terraform trying to reset it on the next apply.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# -----------------------------------------------------------------------------
# CORE ADDONS (H10)
# Managed addons keep CNI/coredns/kube-proxy patched via EKS. Versions are now
# PINNABLE (var.addon_versions, resolve-then-pin per CLAUDE.md §6): empty = EKS
# default-for-cluster-version (prior behavior), a value = an explicit pin. Update
# conflicts use PRESERVE (not OVERWRITE) so a version bump does NOT clobber custom
# config (e.g. the VPC CNI NetworkPolicy setting). Sequence addon upgrades as their
# OWN reviewed step (addons → control plane → nodes one at a time), never bundled
# with a cluster_version bump — a CoreDNS rollout during a validator restart breaks
# the C10 wait-peer-dns gate.
# -----------------------------------------------------------------------------
resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "vpc-cni"
  addon_version = var.addon_versions.vpc_cni != "" ? var.addon_versions.vpc_cni : null

  # OVERWRITE on create so the managed addon owns the config; PRESERVE on update so
  # a version bump keeps our configuration_values / custom fields (H10).
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  # H6: enable the VPC CNI NetworkPolicy agent so besu-node NetworkPolicies actually
  # ENFORCE (without it the policy objects exist but are ignored). Pair with the
  # besu chart's networkPolicy.enabled.
  configuration_values = var.enable_network_policy ? jsonencode({ enableNetworkPolicy = "true" }) : null

  tags = merge(var.tags, { Component = "eks" })

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  addon_version               = var.addon_versions.coredns != "" ? var.addon_versions.coredns : null
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  tags                        = merge(var.tags, { Component = "eks" })
  depends_on                  = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  addon_version               = var.addon_versions.kube_proxy != "" ? var.addon_versions.kube_proxy : null
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  tags                        = merge(var.tags, { Component = "eks" })
  depends_on                  = [aws_eks_node_group.this]
}

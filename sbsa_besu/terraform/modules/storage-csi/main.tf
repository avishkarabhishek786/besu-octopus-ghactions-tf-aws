# =============================================================================
# modules/storage-csi/main.tf
# -----------------------------------------------------------------------------
# PURPOSE
#   Sets up persistent storage and secret-mounting for the cluster. The module
#   is deliberately split into TWO layers with different network requirements:
#
#   AWS-LAYER (always created — pure AWS API calls, work from anywhere):
#     1. EBS CSI DRIVER (EKS addon) + its IRSA role — lets Kubernetes
#        dynamically provision EBS volumes for Besu's PersistentVolumeClaims.
#
#   IN-CLUSTER LAYER (created only when deploy_in_cluster_resources = true —
#   these call the Kubernetes API and therefore require a PRIVATE network path
#   to the EKS endpoint; from a laptop against a private-endpoint cluster they
#   time out, so they are gated behind the toggle):
#     2. A gp3 STORAGECLASS with allowVolumeExpansion = true.
#     3. SECRETS STORE CSI DRIVER (+ AWS provider) via Helm.
#
# WHY THE SPLIT
#   The cluster has a PRIVATE API endpoint ("nothing public"). When Terraform
#   runs from outside the VPC (e.g. an operator laptop), it can reach AWS APIs
#   but NOT the Kubernetes API. So the AWS-layer parts apply fine from anywhere,
#   while the in-cluster parts must be applied from inside the VPC (an SSM-
#   managed runner / CI runner in a private subnet — the real deployment
#   pattern documented in CLAUDE.md stage 3). The toggle lets the SAME module
#   serve both: laptop bootstrap (toggle off) and in-VPC full apply (toggle on).
#
# WHY gp3 OVER gp2
#   gp3 decouples IOPS/throughput from size and is ~20% cheaper per GiB, with a
#   better performance baseline. Directly serves the cost-optimisation
#   requirement.
#
# WHY reclaimPolicy = Retain (production)
#   If a PVC/PV is accidentally deleted, Retain keeps the underlying EBS volume
#   (and therefore the blockchain data) so it can be recovered. Non-prod uses
#   Delete so test teardown leaves no orphaned volumes billing.
# =============================================================================

data "aws_partition" "current" {}

# -----------------------------------------------------------------------------
# EBS CSI DRIVER — IRSA ROLE
# The driver's controller pods run as the "ebs-csi-controller-sa" service
# account in kube-system. They need permission to create/attach/delete EBS
# volumes. We scope a role to that exact service account.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name                 = "${var.name_prefix}-ebs-csi-irsa"
  assume_role_policy   = data.aws_iam_policy_document.ebs_csi_assume.json
  permissions_boundary = var.permissions_boundary # H5: cap — no IAM/org/account mutation
  tags                 = merge(var.tags, { Component = "storage-csi" })
}

# AWS provides a managed policy with exactly the EBS CSI permissions.
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# -----------------------------------------------------------------------------
# EBS CSI DRIVER — EKS ADDON
# Installs the driver as a managed addon and wires it to the IRSA role above.
# -----------------------------------------------------------------------------
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = var.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn
  # H10: pinnable (resolve-then-pin). Empty = EKS default-for-cluster-version.
  addon_version = var.ebs_csi_addon_version != "" ? var.ebs_csi_addon_version : null
  # OVERWRITE on create (own the config); PRESERVE on update so a version bump keeps
  # custom fields (H10).
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = merge(var.tags, { Component = "storage-csi" })

  depends_on = [aws_iam_role_policy_attachment.ebs_csi]
}

# -----------------------------------------------------------------------------
# gp3 STORAGECLASS  (IN-CLUSTER — gated by deploy_in_cluster_resources)
# -----------------------------------------------------------------------------
# This becomes the default StorageClass. Besu PVCs (later) bind to it and get
# encrypted gp3 volumes. allow_volume_expansion lets you grow them in place.
# volumeBindingMode = WaitForFirstConsumer ensures the volume is created in the
# SAME AZ as the pod that will use it (critical: EBS is AZ-bound, so a volume in
# the wrong AZ can never attach to its pod).
#
# count: created only when deploy_in_cluster_resources = true (i.e. when
# Terraform runs from inside the VPC with reachability to the private EKS API).
# -----------------------------------------------------------------------------
resource "kubernetes_storage_class" "gp3" {
  count = var.deploy_in_cluster_resources ? 1 : 0

  metadata {
    name = "besu-gp3"
    annotations = {
      # Make this the cluster default StorageClass.
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = var.reclaim_policy
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"

  # C11 (2026-07-02): volumes provisioned by the EBS CSI driver are created by
  # the DRIVER, not Terraform, so the provider's default_tags never reach them.
  # That is how 79 orphaned PVC volumes (~2.5 TB) accumulated across past
  # deploy-tests without any DeletionGroup-keyed sweep seeing them. The
  # tagSpecification_N parameters make the driver stamp every volume it creates,
  # so the tag-keyed teardown (full-delete.sh) and cost allocation now cover
  # chain-data volumes too.
  parameters = merge(
    {
      type      = "gp3"
      encrypted = "true"
    },
    # H20: encrypt chain-data PVCs under a customer CMK when data_cmk_arn is set
    # (else the AWS-managed aws/ebs key). The CMK policy must allow the EBS CSI
    # driver's IRSA role to use it — supply a properly-scoped data CMK for prod.
    var.data_cmk_arn != "" ? { kmsKeyId = var.data_cmk_arn } : {},
    {
      for i, k in sort(keys(var.volume_tags)) :
      "tagSpecification_${i + 1}" => "${k}=${var.volume_tags[k]}"
    }
  )

  depends_on = [aws_eks_addon.ebs_csi]
}

# -----------------------------------------------------------------------------
# SECRETS STORE CSI DRIVER (+ AWS provider)  via Helm
# (IN-CLUSTER — gated by deploy_in_cluster_resources)
# -----------------------------------------------------------------------------
# Two pieces, matching the quorum-kubernetes cluster bootstrap:
#   1. The generic secrets-store-csi-driver chart.
#   2. The AWS provider DaemonSet that teaches the driver how to read AWS
#      Secrets Manager.
# Together they let a Besu pod declare a SecretProviderClass (later stage) and
# have its node key appear as a file in the pod, fetched with the IRSA role.
#
# count: created only when deploy_in_cluster_resources = true.
# -----------------------------------------------------------------------------
resource "helm_release" "secrets_store_csi_driver" {
  count = var.deploy_in_cluster_resources ? 1 : 0

  name             = "csi-secrets-store"
  repository       = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart            = "secrets-store-csi-driver"
  version          = "1.6.0" # pinned (verified current stable; requires k8s >= 1.30, we run 1.35)
  namespace        = "kube-system"
  create_namespace = false

  # Enable secret rotation so rotated keys propagate to pods.
  set {
    name  = "syncSecret.enabled"
    value = "true"
  }
  set {
    name  = "enableSecretRotation"
    value = "true"
  }

  # REQUIRED for the AWS provider + IRSA: configures tokenRequests on the
  # CSIDriver object so the driver receives a projected service-account token
  # (audience sts.amazonaws.com) and passes it to the AWS provider, which
  # exchanges it via AssumeRoleWithWebIdentity to read Secrets Manager. Without
  # this the mount fails: "CSI token error: serviceAccount.tokens not provided
  # - ensure tokenRequests is configured in CSIDriver spec".
  set {
    name  = "tokenRequests[0].audience"
    value = "sts.amazonaws.com"
  }

  depends_on = [aws_eks_addon.ebs_csi]
}

# The AWS provider for the Secrets Store CSI driver is published as a set of
# manifests, not a Helm chart in the standard repo. We install it from the
# upstream installer manifest via the kubernetes provider in a later stage's
# kubectl-style apply OR via a small helm chart mirror. For stage 1 we record
# the dependency; the actual provider DaemonSet apply is handled in the
# secrets/PKI stage where the SecretProviderClass is also defined, to keep all
# Secrets-Manager-related wiring in one place.

# =============================================================================
# mimic_eks — impersonates the cloud team's SHARED EKS CLUSTER (CT-5, D-32)
# -----------------------------------------------------------------------------
# THE RULE HERE IS THE OPPOSITE OF THE PLATFORM'S.
#   sbsa_besu/CLAUDE.md prime directive 1 says NEVER create a cluster, node
#   group, addon, CRD or any cluster-scoped Kubernetes kind. This project
#   creates all of them, because it is the other team. Do not let the two briefs
#   blur: the platform's rule is what protects the bank's real cluster.
#
# WHAT IT IS FOR
#   Two things, and the second is the reason it exists at all.
#     1. Somewhere to deploy the platform against under namespace tenancy.
#     2. A cluster that BREAKS THE PLATFORM'S CHECKS ON PURPOSE. The default
#        profile is "hostile" — see variables.tf. A gate that has only ever been
#        seen to pass is an assumption wearing a check's clothing (B12, and the
#        jq '// "absent"' bug that proved it twice more).
#
# THE CLUSTER MODULE IS NOT COPIED HERE.
#   It is sourced in place from sbsa_besu/terraform/modules/eks. §12.6 says that
#   directory MOVES here and is deleted from the platform — but it has not moved
#   yet, because sbsa_besu/terraform/chain/main.tf:101 still sources it and the
#   CT-5 banner is explicit that nothing is removed until shared-cluster requirements §4 is answered.
#   A copy would be a second source of truth and would drift. At cutover the
#   directory moves and only the `source` below changes.
#
# COST — THIS ROOT CREATES A BILLABLE EKS CONTROL PLANE.
#   ~USD 0.10/hr for the control plane plus nodes, in af-south-1 (~31% above
#   us-east-1). Same-day teardown is mandatory, same as the platform's
#   deploy-tests. ADVISE-ONLY: never apply this without the human asking.
# =============================================================================

locals {
  hostile = var.profile == "hostile"

  # ---------------------------------------------------------------------------
  # Resolve each knob: an explicit override wins, otherwise the profile decides.
  # `coalesce` is wrong for booleans here — it returns the first NON-NULL, which
  # is what we want, but a false override must survive, and coalesce(false, true)
  # correctly yields false. Spelled out rather than clever so it stays readable.
  # ---------------------------------------------------------------------------
  psa_level           = coalesce(var.psa_level, local.hostile ? "restricted" : "baseline")
  psa_cluster_wide    = coalesce(var.psa_cluster_wide, false)
  provide_lbc         = coalesce(var.provide_lbc, !local.hostile)
  provide_csi         = coalesce(var.provide_secrets_store_csi, !local.hostile)
  provide_prom        = coalesce(var.provide_prometheus_operator, !local.hostile)
  provide_logs        = coalesce(var.provide_log_shipping, !local.hostile)
  netpol              = coalesce(var.enable_network_policy, !local.hostile)
  dedicated           = coalesce(var.node_group_dedicated, !local.hostile)
  node_count          = coalesce(var.node_count, local.hostile ? 3 : 4)
  quota_cpu           = coalesce(var.quota_cpu, local.hostile ? "6" : "8")
  quota_memory        = coalesce(var.quota_memory, local.hostile ? "18Gi" : "24Gi")
  storage_binding     = coalesce(var.storage_binding_mode, local.hostile ? "Immediate" : "WaitForFirstConsumer")
  storage_expand      = coalesce(var.storage_allow_expansion, !local.hostile)
  access_cluster_wide = coalesce(var.access_entry_cluster_wide, local.hostile)
  crd_rbac            = coalesce(var.grant_custom_resource_rbac, !local.hostile)
  node_sg_allows_rpc  = coalesce(var.node_sg_allows_rpc, !local.hostile)
  public_endpoint     = coalesce(var.endpoint_public_access, local.hostile)
  k8s_version         = coalesce(var.kubernetes_version, local.hostile ? "1.37" : "1.36")

  cluster_name       = "${var.project_name}-${var.environment}-shared"
  storage_class_name = "gp3-${local.hostile ? "immediate" : "wffc"}"

  # Our pods land in the cloud team's APPLICATION subnets (CT-5). When #28 is
  # granted, the dedicated group goes in the ledger subnets instead, which is
  # the half of D-26 that restores the NACL and flow-log boundary — in their
  # hands, not ours.
  node_subnet_ids = local.dedicated && length(var.ledger_subnet_ids) > 0 ? var.ledger_subnet_ids : var.app_subnet_ids

  tags = {
    Project       = var.project_name
    Environment   = var.environment
    DeletionGroup = var.deletion_group
    Owner         = var.owner
    CostCenter    = var.cost_center
    ManagedBy     = "terraform"
    Mimics        = "cloud-team-shared-eks"
    Profile       = var.profile
  }
}

# -----------------------------------------------------------------------------
# GATE — the cluster and its subnets must be in one region.
# -----------------------------------------------------------------------------
# The mimic gets the same courtesy the platform does: fail at plan time with a
# message, not twenty minutes into an apply with an AWS error. mimic_vpc's
# equivalent gate is on its own inputs.
data "aws_region" "current" {}

resource "terraform_data" "region_agreement" {
  input = var.region

  lifecycle {
    precondition {
      condition     = data.aws_region.current.name == var.region
      error_message = "PROVIDER REGION MISMATCH (B25): var.region is '${var.region}' but the AWS provider is operating in '${data.aws_region.current.name}'. Every resource would be created in the wrong region and the apply would fail late on InvalidVpcID.NotFound."
    }
    precondition {
      condition     = var.region == var.network_region
      error_message = "REGION MISMATCH: this root deploys into '${var.region}' but the network hand-over describes a VPC in '${var.network_region}'. Subnet IDs do not travel between regions — re-run mimic_vpc/scripts/emit-handover.sh for '${var.region}'."
    }
    precondition {
      condition     = length(var.az_ids) == 3
      error_message = "3 AZ IDs required; the hand-over supplies ${length(var.az_ids)}. Four validators spread across three zones is what leaves a 2F+1 quorum when a zone is lost."
    }
  }
}

# -----------------------------------------------------------------------------
# The cluster, from the platform's own module (see the header).
# -----------------------------------------------------------------------------
module "eks" {
  source = "../../sbsa_besu/terraform/modules/eks"

  name_prefix        = "${var.project_name}-${var.environment}"
  cluster_name       = local.cluster_name
  kubernetes_version = local.k8s_version
  vpc_id             = var.vpc_id
  private_subnet_ids = values(local.node_subnet_ids)

  # hostile leaves the API endpoint PUBLIC. From inside the VPC that behaves
  # identically to a private one, which is exactly why the platform needs a gate
  # for it (CG-2) rather than an operator's recollection.
  endpoint_public_access = local.public_endpoint

  node_count           = local.node_count
  node_min             = local.node_count
  node_max             = local.node_count
  instance_type        = var.instance_type
  node_volume_size_gib = var.node_volume_size_gib

  # A fixture's logs are not evidence of record, and the group is deleted the
  # same day. The platform's own retention is a separate, longer decision.
  log_retention_days = 1

  # #35 — the switch that decides whether NetworkPolicy objects mean anything.
  enable_network_policy = local.netpol

  tags = local.tags

  depends_on = [terraform_data.region_agreement]
}

# -----------------------------------------------------------------------------
# #28 / D-26 — the dedicated, tainted node group, when granted.
# -----------------------------------------------------------------------------
# Reproduces both answers. Granted: a taint only the ledger's pods tolerate, so
# a missing toleration on our side shows up as Pending rather than as a silent
# landing on shared nodes. Refused: nothing here, and the platform's ISOLATION
# FLOOR gate (CG-9) then depends entirely on #35.
resource "aws_eks_node_group" "ledger" {
  count = local.dedicated ? 1 : 0

  cluster_name    = module.eks.cluster_name
  node_group_name = "${var.project_name}-${var.environment}-ledger"
  node_role_arn   = module.eks.node_role_arn
  subnet_ids      = values(local.node_subnet_ids)
  instance_types  = [var.instance_type]

  scaling_config {
    desired_size = local.node_count
    min_size     = local.node_count
    max_size     = local.node_count
  }

  labels = { "workload" = var.node_taint_value }

  taint {
    key    = var.node_taint_key
    value  = var.node_taint_value
    effect = "NO_SCHEDULE"
  }

  tags = merge(local.tags, { Purpose = "ledger-dedicated-28" })

  lifecycle {
    # The real cloud team's rotation tooling is what #29 is about. Here it
    # matters only that a taint change does not silently recycle the group
    # under a running chain mid-test.
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# -----------------------------------------------------------------------------
# #33 — ingress on THEIR node security group for our NLBs.
# -----------------------------------------------------------------------------
# hostile omits it. The symptom is NLB targets stuck unhealthy with
# Target.FailedHealthChecks and nothing anywhere naming a security group, which
# is why verify-deployed.sh asserts target health rather than reading config.
#
# The real cloud team would reference OUR NLB security groups. The mimic admits
# the VPC CIDR instead, because the platform's NLB SGs do not exist until it is
# deployed — and a mimic that cannot be applied before the platform is useless
# as a fixture. Noted so the difference is not mistaken for the real grant.
resource "aws_security_group_rule" "node_rpc" {
  count = local.node_sg_allows_rpc ? 1 : 0

  type              = "ingress"
  security_group_id = module.eks.node_security_group_id
  from_port         = 8545
  to_port           = 8546
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr_primary]
  description       = "#33 mimic: RPC + WS from the VPC. The real grant references our NLB security groups."
}

# -----------------------------------------------------------------------------
# #32 / D-34 — the access entry for the In-VPC EC2 Runner.
# -----------------------------------------------------------------------------
# hostile grants CLUSTER ADMIN. That is the silent direction of #32: it works
# exactly as well as a scoped grant, so nothing ever reports it, and only a check
# that asserts a NEGATIVE finds it (verify-cluster.sh, D-37).
resource "aws_eks_access_entry" "runner" {
  count = var.runner_role_arn != "" ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = var.runner_role_arn
  type          = "STANDARD"
  tags          = local.tags
}

resource "aws_eks_access_policy_association" "runner" {
  count = var.runner_role_arn != "" ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = var.runner_role_arn
  policy_arn    = local.access_cluster_wide ? "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy" : "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = local.access_cluster_wide ? "cluster" : "namespace"
    namespaces = local.access_cluster_wide ? null : [var.namespace_ledger, var.namespace_app]
  }

  depends_on = [aws_eks_access_entry.runner]
}

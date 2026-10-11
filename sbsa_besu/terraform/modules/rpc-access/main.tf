# =============================================================================
# modules/rpc-access/main.tf
# -----------------------------------------------------------------------------
# PURPOSE — the SWIFT-facing RPC edge. SWIFT reaches JSON-RPC over its private
# SIPN network as an mTLS client. We expose the RPC nodes via an INTERNAL,
# L4 (TCP) NLB doing TLS PASSTHROUGH so mTLS terminates at Besu itself (using
# the keystore/truststore issued from our CA). The NLB is locked to the SIPN
# source CIDRs. An optional PrivateLink endpoint service exposes the same NLB
# to a future, separately-deployed application VPC.
#
# WHY NLB PASSTHROUGH (not ALB)  — preserves end-to-end mTLS to the pod and
# matches the settled "per-user JWT method scoping at Besu" decision. The NLB
# never sees plaintext; it forwards TCP to the Besu RPC TLS listener.
#
# TARGET REGISTRATION — Terraform OWNS the NLB + target group (so it knows the
# ARN for PrivateLink), and the AWS Load Balancer Controller's TargetGroupBinding
# (a small in-cluster chart, stage besu) registers the RPC pod IPs into this
# target group. That split avoids the chicken-and-egg of referencing a
# controller-created NLB from Terraform.
# =============================================================================

data "aws_partition" "current" {}

# -----------------------------------------------------------------------------
# AWS LOAD BALANCER CONTROLLER — IRSA ROLE (AWS-layer; always created)
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "lbc_assume" {
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
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lbc" {
  name                 = "${var.name_prefix}-alb-controller-irsa"
  assume_role_policy   = data.aws_iam_policy_document.lbc_assume.json
  permissions_boundary = var.permissions_boundary # H5: cap — no IAM/org/account mutation
  tags                 = merge(var.tags, { Component = "rpc-access" })
}

# Official AWS Load Balancer Controller IAM policy (v3.4.0), vendored as a file
# so the permission set is pinned with the chart version.
resource "aws_iam_policy" "lbc" {
  name   = "${var.name_prefix}-alb-controller-policy"
  policy = file("${path.module}/iam_policy_alb.json")
  tags   = merge(var.tags, { Component = "rpc-access" })
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

# -----------------------------------------------------------------------------
# AWS LOAD BALANCER CONTROLLER — HELM (in-cluster; gated)
# -----------------------------------------------------------------------------
locals {
  # PORTING item 4: Helm value path -> chart_images key. Rendered as one string
  # `set` per attribute, and only for keys present, so an absent key keeps the
  # chart's own default rather than nulling it.
  lbc_image_sets_paths = {
    "image" = "lb-controller"
  }
  lbc_image_sets = merge([for path, key in local.lbc_image_sets_paths :
    { for attr, val in { repository = "${var.chart_images[key].registry}/${var.chart_images[key].repository}", tag = var.chart_images[key].tag } : "${path}.${attr}" => val }
    if contains(keys(var.chart_images), key)
  ]...)
}

resource "helm_release" "lbc" {
  count = var.deploy_in_cluster_resources ? 1 : 0

  name       = "aws-load-balancer-controller"
  repository = var.chart_repository != "" ? var.chart_repository : "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lb_controller_chart_version
  namespace  = "kube-system"

  dynamic "set" {
    for_each = local.lbc_image_sets
    content {
      name  = set.key
      value = set.value
      type  = "string"
    }
  }

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "vpcId"
    value = var.vpc_id
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.lbc.arn
  }

  depends_on = [aws_iam_role_policy_attachment.lbc]
}

# -----------------------------------------------------------------------------
# RPC NLB EDGE (AWS-layer; gated by enable_rpc_ingress)
# -----------------------------------------------------------------------------
# Security group for the NLB: ingress only from the SIPN source CIDRs on the RPC
# port, plus the VPC CIDR so in-VPC health checks / the runner can reach it.
resource "aws_security_group" "nlb" {
  count = var.enable_rpc_ingress ? 1 : 0

  name        = "${var.name_prefix}-rpc-nlb-sg"
  description = "RPC NLB: ingress from SIPN CIDRs (+VPC) on the RPC port only"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    # F21: skip any SIPN CIDR equal to the VPC CIDR — the static "In-VPC clients"
    # rule below already permits it, and a duplicate permission fails the apply
    # ("The same permission must not appear multiple times").
    for_each = toset([for c in var.swift_sipn_allowed_cidrs : c if c != var.vpc_cidr])
    content {
      description = "SWIFT SIPN"
      from_port   = var.rpc_port
      to_port     = var.rpc_port
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  # In-VPC access (health checks, the runner's mTLS smoke test).
  ingress {
    description = "In-VPC clients"
    from_port   = var.rpc_port
    to_port     = var.rpc_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "to targets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-rpc-nlb-sg", Component = "rpc-access" })
}

resource "aws_lb" "rpc" {
  count = var.enable_rpc_ingress ? 1 : 0

  name                             = "${var.name_prefix}-rpc-nlb"
  internal                         = true # never public — SWIFT reaches it over SIPN/private connectivity
  load_balancer_type               = "network"
  subnets                          = var.private_subnet_ids
  security_groups                  = [aws_security_group.nlb[0].id]
  enable_cross_zone_load_balancing = true
  # H13: for prod, block accidental deletion — the SWIFT NLB's DNS name is baked into
  # SWIFT's config, so a delete/replace breaks their connectivity. false for deploy-tests.
  enable_deletion_protection = var.enable_deletion_protection

  tags = merge(var.tags, { Name = "${var.name_prefix}-rpc-nlb", Component = "rpc-access" })
}

# Target group: IP targets (the RPC pod IPs, registered by the in-cluster
# TargetGroupBinding). TCP passthrough; TCP health check on the RPC port.
# Allow the NLB to reach the Besu RPC pods on the RPC port. With a
# Terraform-owned NLB (not controller-created), the AWS Load Balancer Controller
# does not auto-add this, so health checks + traffic are blocked without it.
resource "aws_security_group_rule" "pods_from_nlb" {
  count = var.enable_rpc_ingress ? 1 : 0

  type                     = "ingress"
  description              = "RPC NLB to Besu RPC pods"
  security_group_id        = var.cluster_primary_security_group_id
  source_security_group_id = aws_security_group.nlb[0].id
  protocol                 = "tcp"
  from_port                = var.rpc_port
  to_port                  = var.rpc_port
}

resource "aws_lb_target_group" "rpc" {
  count = var.enable_rpc_ingress ? 1 : 0

  name        = "${var.name_prefix}-rpc-tg"
  port        = var.rpc_port
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }

  tags = merge(var.tags, { Component = "rpc-access" })
}

resource "aws_lb_listener" "rpc" {
  count = var.enable_rpc_ingress ? 1 : 0

  load_balancer_arn = aws_lb.rpc[0].arn
  port              = var.rpc_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.rpc[0].arn
  }
}

# -----------------------------------------------------------------------------
# PRIVATELINK ENDPOINT SERVICE (gated) — exposes the NLB to a future app VPC.
# -----------------------------------------------------------------------------
resource "aws_vpc_endpoint_service" "rpc" {
  count = var.enable_rpc_ingress && var.enable_privatelink ? 1 : 0

  acceptance_required        = true # the app account must be explicitly accepted
  network_load_balancer_arns = [aws_lb.rpc[0].arn]

  tags = merge(var.tags, { Name = "${var.name_prefix}-rpc-privatelink", Component = "rpc-access" })
}

# =============================================================================
# STAGE 8 — APP-RPC EDGE (A′): a SEPARATE internal NLB + HTTP/WS target groups +
# a DEDICATED PrivateLink service for the app pool. Independent of the SWIFT edge
# above so the two RPC planes are separate edges with their own blast radius (per
# the mirror rule, created in BOTH envs; non-prod just runs fewer app-rpc nodes). The app
# VPC creates an interface endpoint to app_rpc_privatelink_service_name.
# =============================================================================
resource "aws_security_group" "app_nlb" {
  count = var.enable_app_rpc_ingress ? 1 : 0

  name        = "${var.name_prefix}-app-rpc-nlb-sg"
  description = "App-RPC NLB: ingress from the app VPC CIDR(s) (+chain VPC) on the app RPC HTTP/WS ports"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = toset(var.app_rpc_allowed_cidrs)
    content {
      description = "App VPC (via PrivateLink)"
      from_port   = var.app_rpc_http_port
      to_port     = var.app_rpc_ws_port
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  # In-VPC access (health checks, the runner's smoke test).
  ingress {
    description = "In-VPC clients"
    from_port   = var.app_rpc_http_port
    to_port     = var.app_rpc_ws_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "to targets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-app-rpc-nlb-sg", Component = "rpc-access" })
}

resource "aws_lb" "app_rpc" {
  count = var.enable_app_rpc_ingress ? 1 : 0

  # AWS caps LB/TG `name` at 32 chars; name_prefix (24) leaves 8, so the `name`
  # is compact (`-app-nlb`) while the human-readable Name tag keeps the full label.
  name                             = "${var.name_prefix}-app-nlb"
  internal                         = true # never public — app reaches it via PrivateLink
  load_balancer_type               = "network"
  subnets                          = var.private_subnet_ids
  security_groups                  = [aws_security_group.app_nlb[0].id]
  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = var.enable_deletion_protection # H13

  tags = merge(var.tags, { Name = "${var.name_prefix}-app-rpc-nlb", Component = "rpc-access" })
}

# Allow the app NLB to reach the app-rpc pods on the HTTP + WS ports.
resource "aws_security_group_rule" "pods_from_app_nlb" {
  count = var.enable_app_rpc_ingress ? 1 : 0

  type                     = "ingress"
  description              = "App-RPC NLB to Besu app-rpc pods (HTTP+WS)"
  security_group_id        = var.cluster_primary_security_group_id
  source_security_group_id = aws_security_group.app_nlb[0].id
  protocol                 = "tcp"
  from_port                = var.app_rpc_http_port
  to_port                  = var.app_rpc_ws_port
}

resource "aws_lb_target_group" "app_rpc_http" {
  count = var.enable_app_rpc_ingress ? 1 : 0

  name        = "${var.name_prefix}-app-htg" # ≤32 chars (see app NLB note); full label in Name tag
  port        = var.app_rpc_http_port
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-app-rpc-http-tg", Component = "rpc-access" })
}

resource "aws_lb_target_group" "app_rpc_ws" {
  count = var.enable_app_rpc_ingress && var.app_rpc_ws_enabled ? 1 : 0

  name        = "${var.name_prefix}-app-wtg" # ≤32 chars (see app NLB note); full label in Name tag
  port        = var.app_rpc_ws_port
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-app-rpc-ws-tg", Component = "rpc-access" })
}

resource "aws_lb_listener" "app_rpc_http" {
  count = var.enable_app_rpc_ingress ? 1 : 0

  load_balancer_arn = aws_lb.app_rpc[0].arn
  port              = var.app_rpc_http_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_rpc_http[0].arn
  }
}

resource "aws_lb_listener" "app_rpc_ws" {
  count = var.enable_app_rpc_ingress && var.app_rpc_ws_enabled ? 1 : 0

  load_balancer_arn = aws_lb.app_rpc[0].arn
  port              = var.app_rpc_ws_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_rpc_ws[0].arn
  }
}

# Dedicated PrivateLink service for the app pool (separate from the SWIFT one).
resource "aws_vpc_endpoint_service" "app_rpc" {
  count = var.enable_app_rpc_ingress ? 1 : 0

  acceptance_required        = true # the app account's endpoint must be explicitly accepted
  network_load_balancer_arns = [aws_lb.app_rpc[0].arn]

  tags = merge(var.tags, { Name = "${var.name_prefix}-app-rpc-privatelink", Component = "rpc-access" })
}

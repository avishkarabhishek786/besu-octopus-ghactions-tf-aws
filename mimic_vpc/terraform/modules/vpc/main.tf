# =============================================================================
# modules/vpc — the VPC itself, its CIDRs, DNS, and VPC-level flow logs.
# -----------------------------------------------------------------------------
# In production every resource in this module belongs to the CLOUD TEAM. It
# exists here only so the platform can be built against something that behaves
# identically. Each attribute maps to a numbered requirement in the spec.
# =============================================================================

# -----------------------------------------------------------------------------
# The VPC.
# -----------------------------------------------------------------------------
# #1  instance_tenancy is set EXPLICITLY even though "default" is the provider
#     default. The value is IMMUTABLE after creation, and a VPC created with
#     "dedicated" forces every instance onto dedicated tenancy regardless of the
#     launch template — roughly USD 1,460/month in per-region fees plus ~10% on
#     instance rates, and EKS managed node groups do not support dedicated HOST
#     placement at all. One explicit line is cheap insurance against an
#     irreversible, expensive mistake.
#
# #2  BOTH DNS attributes must be true. AWS interface endpoints work by having
#     Private DNS override the public service hostname with the endpoint's
#     private IP, and Private DNS requires both. With no Internet Gateway, a
#     failure here does not error — every AWS SDK call resolves to a public IP
#     with no route and HANGS until timeout. That breaks node bootstrap, IRSA,
#     KMS decryption of validator keys, secret retrieval and log shipping, all
#     with the same uninformative symptom.
# -----------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  instance_tenancy     = "default" # #1 — immutable; never change to "dedicated"
  enable_dns_support   = true      # #2
  enable_dns_hostnames = true      # #2

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-vpc"
    Component = "network"
  })
}

# -----------------------------------------------------------------------------
# #17 — Secondary CIDR, associated but DELIBERATELY UNUSED.
# -----------------------------------------------------------------------------
# 100.64.0.0/10 is carrier-grade NAT space (RFC 6598), not RFC 1918. It consumes
# none of the enterprise IPAM allocation and is never routed outside the VPC, so
# it costs the cloud team nothing to grant.
#
# NO SUBNETS ARE CREATED IN IT, and that is the point. Associating it now means
# that if the estate ever outgrows the /20, moving pod IPs onto it is a config
# change (enable VPC CNI custom networking) rather than an association request
# plus a rolling replacement of every node on a live ledger.
#
# scripts/verify-contract.sh asserts that this block stays empty.
# -----------------------------------------------------------------------------
resource "aws_vpc_ipv4_cidr_block_association" "secondary" {
  count      = var.enable_secondary_cidr ? 1 : 0
  vpc_id     = aws_vpc.this.id
  cidr_block = var.secondary_cidr
}

# -----------------------------------------------------------------------------
# #3 — DHCP option set.
# -----------------------------------------------------------------------------
# Created explicitly rather than relying on the account default, because the
# real risk in an enterprise VPC is a custom option set pointing only at
# on-premises DNS servers. When that happens, endpoint Private DNS stops
# resolving unless those servers forward to the Amazon resolver — producing
# symptoms identical to a #2 failure, from an entirely different cause.
#
# AmazonProvidedDNS is what the platform requires. In production the cloud team
# must additionally ensure the ECR endpoints resolve via Private DNS (#22).
# -----------------------------------------------------------------------------
resource "aws_vpc_dhcp_options" "this" {
  domain_name_servers = ["AmazonProvidedDNS"]
  domain_name         = var.region == "us-east-1" ? "ec2.internal" : "${var.region}.compute.internal"

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-dhcp"
    Component = "network"
  })
}

resource "aws_vpc_dhcp_options_association" "this" {
  vpc_id          = aws_vpc.this.id
  dhcp_options_id = aws_vpc_dhcp_options.this.id
}

# -----------------------------------------------------------------------------
# VPC-level flow logs — the cloud team's, in production.
# -----------------------------------------------------------------------------
# The platform additionally requests SUBNET-level flow logs on the ledger
# subnets delivered to its own destination (#14), because network forensics on
# the ledger is a compliance artifact that cannot live solely under another
# team's ownership.
#
# This is the ONLY billable resource in this project. Keep retention short in
# deploy-tests.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "flow_logs" {
  count             = var.enable_flow_logs ? 1 : 0
  name              = "/${var.name_prefix}/vpc-flow-logs"
  retention_in_days = var.flow_log_retention_days
  tags              = merge(var.tags, { Component = "network" })
}

data "aws_iam_policy_document" "flow_logs_assume" {
  count = var.enable_flow_logs ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      // scoped to this log group only — not logs:* on every group in the account
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  count              = var.enable_flow_logs ? 1 : 0
  name_prefix        = "${var.name_prefix}-flowlogs-"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume[0].json
  tags               = merge(var.tags, { Component = "network" })
}

resource "aws_iam_role_policy" "flow_logs" {
  count  = var.enable_flow_logs ? 1 : 0
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "this" {
  count                = var.enable_flow_logs ? 1 : 0
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn         = aws_iam_role.flow_logs[0].arn
  tags                 = merge(var.tags, { Name = "${var.name_prefix}-flow-log", Component = "network" })
}

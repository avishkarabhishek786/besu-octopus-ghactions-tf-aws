# =============================================================================
# main.tf — the `shared` root: VPC endpoints and the private hosted zone
# -----------------------------------------------------------------------------
# WHAT
#   The AWS service reachability layer for a VPC with NO egress. Interface
#   endpoints (one ENI per AZ in the endpoint subnets) plus the two free gateway
#   endpoints, plus the private hosted zone that gives the RPC plane a stable
#   internal name.
#
# WHY IT IS A SEPARATE ROOT
#   Both clusters depend on it and it outlives both. See backend.tf.
#
# WHY IT APPLIES FIRST (order 2.0 in CLAUDE.md)
#   Nothing else works without it. Node bootstrap needs ecr.api/ecr.dkr/s3 to
#   pull images, ec2 to describe itself, sts to assume its role, and eks to
#   register; the runner needs ssm/ssmmessages/ec2messages to be reachable at
#   all. Apply this BEFORE the runner and before the chain.
#
# THE FAILURE MODE THAT MAKES THIS FILE DANGEROUS
#   A missing endpoint does not error. The SDK call routes to a public IP that
#   has no path out, and HANGS until its timeout — surfacing as a pod stuck in
#   Init, a node that never joins, or an addon that never reports ready, with
#   nothing in any log naming the missing service. Adding an AWS service to any
#   workload in this VPC and adding its endpoint are ONE change, never two.
# =============================================================================

locals {
  name_prefix = var.name_prefix_override != "" ? var.name_prefix_override : "${var.project_name}-${var.environment}"

  # Interface endpoints are skipped entirely when the cloud team runs them
  # centrally (Q-2) — creating our own on top would work but bills a second time
  # for every service, the single largest avoidable line item in this design.
  interface_services = var.central_interface_endpoints ? [] : var.interface_endpoint_services

  # One ENI per AZ. Endpoint ENIs deliberately live in their own small subnets,
  # never alongside NLB nodes (CLAUDE.md §3.2).
  endpoint_subnet_ids = values(var.endpoint_subnet_ids)

  # Gateway endpoints write a prefix-list route into every route table they
  # associate with. `data` is excluded: it hosts managed databases that need
  # neither service, and every route added to someone else's route table is a
  # change we have to justify to the cloud team.
  gateway_route_table_ids = concat(
    values(var.ledger_route_table_ids),
    values(var.app_route_table_ids),
    values(var.lb_route_table_ids),
    values(var.endpoint_route_table_ids),
  )

  # Clients live across the whole VPC, and the secondary CIDR is included so
  # that turning on VPC CNI custom networking later (pods on 100.64.x) does not
  # silently break every AWS API call from a pod.
  client_cidrs = compact([var.vpc_cidr_primary, var.vpc_cidr_secondary])
}

# -----------------------------------------------------------------------------
# Security group for the endpoint ENIs.
# -----------------------------------------------------------------------------
# Interface endpoints are ENIs with a security group, and that SG is the real
# access control on them: without an ingress rule the endpoint exists and
# resolves but every connection times out — the same silent failure as a missing
# endpoint. 443 only; every AWS API here is HTTPS.
# -----------------------------------------------------------------------------
resource "aws_security_group" "endpoints" {
  provider = aws.primary

  count = length(local.interface_services) > 0 ? 1 : 0

  name        = "${local.name_prefix}-vpce"
  description = "HTTPS from inside the VPC to the AWS interface endpoint ENIs"
  vpc_id      = var.vpc_id

  tags = { Name = "${local.name_prefix}-vpce", Component = "endpoints" }

  # Recreating this SG means every endpoint ENI is briefly unreachable, so make
  # the replacement land before the detach rather than after.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  provider = aws.primary

  for_each = length(local.interface_services) > 0 ? toset(local.client_cidrs) : toset([])

  security_group_id = aws_security_group.endpoints[0].id
  description       = "HTTPS from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# Endpoint ENIs answer in-VPC calls; they never originate traffic. No egress
# rule is created, which is deliberate — an empty egress set denies all.

# -----------------------------------------------------------------------------
# Interface endpoints — 15 services x 3 AZ (CLAUDE.md §5.1)
# -----------------------------------------------------------------------------
resource "aws_vpc_endpoint" "interface" {
  provider = aws.primary

  for_each = toset(local.interface_services)

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.primary_region}.${each.value}"
  vpc_endpoint_type = "Interface"

  subnet_ids          = local.endpoint_subnet_ids
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = var.endpoint_private_dns

  tags = {
    Name      = "${local.name_prefix}-vpce-${replace(each.value, ".", "-")}"
    Component = "endpoints"
  }
}

# -----------------------------------------------------------------------------
# Gateway endpoints — FREE (#10)
# -----------------------------------------------------------------------------
# S3 IS NOT OPTIONAL: it carries container image layer retrieval for every image
# pull as well as Terraform state. Nothing in either cluster starts without it.
#
# Created only when the cloud team has not already made them. Ownership is a
# question at all because associating one writes a route into route tables that
# belong to them.
# -----------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  provider = aws.primary

  count = var.gateway_endpoints_exist ? 0 : 1

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.primary_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.gateway_route_table_ids

  tags = { Name = "${local.name_prefix}-vpce-s3", Component = "endpoints" }
}

resource "aws_vpc_endpoint" "dynamodb" {
  provider = aws.primary

  count = var.gateway_endpoints_exist ? 0 : 1

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.primary_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.gateway_route_table_ids

  tags = { Name = "${local.name_prefix}-vpce-dynamodb", Component = "endpoints" }
}

# -----------------------------------------------------------------------------
# Private hosted zone
# -----------------------------------------------------------------------------
# The RPC server certificate is issued for rpc.<zone> (issue-app-rpc-cert.sh).
# In the old two-VPC design the app VPC resolved that name through PrivateLink
# private DNS; in a single shared VPC there is no such mechanism, so the name
# needs a real zone or every TLS client fails hostname verification against an
# NLB DNS name that does not match the certificate.
#
# The zone is created here; the `rpc` record is written by the `chain` root,
# which is the only root that knows the NLB. That split is deliberate: the zone
# must survive a chain teardown, or the app cluster loses name resolution the
# moment the ledger is rebuilt.
# -----------------------------------------------------------------------------
resource "aws_route53_zone" "private" {
  provider = aws.primary

  count = var.create_private_dns_zone ? 1 : 0

  name    = var.private_dns_zone
  comment = "Internal names for ${local.name_prefix}; rpc record written by the chain root"

  vpc {
    vpc_id     = var.vpc_id
    vpc_region = var.primary_region
  }

  tags = { Name = "${local.name_prefix}-${var.private_dns_zone}", Component = "dns" }
}

# =============================================================================
# modules/subnets — the 15 subnets, their route tables, the ledger NACLs, and
# (conditionally) the gateway/interface endpoints.
# -----------------------------------------------------------------------------
# In production all of this is the CLOUD TEAM's, except the endpoints, which the
# platform asks to own (#15, decision D-11).
# =============================================================================

# -----------------------------------------------------------------------------
# Subnets.
# -----------------------------------------------------------------------------
# #5  availability_zone_id, NOT availability_zone. AZ *names* map to different
#     physical zones in different accounts, so a hand-over expressed in names is
#     not reproducible. Using the ID makes placement deterministic and lets the
#     platform pin QBFT validators to known physical zones.
#
# NO PUBLIC IPs, EVER. There is no Internet Gateway in this VPC and there never
# will be (CLAUDE.md prime directive 2), so map_public_ip_on_launch is false on
# every subnet without exception.
# -----------------------------------------------------------------------------
resource "aws_subnet" "this" {
  for_each = var.subnets

  vpc_id                  = var.vpc_id
  cidr_block              = each.value.cidr
  availability_zone_id    = each.value.az_id # #5
  map_public_ip_on_launch = false

  tags = merge(
    var.tags,
    # #4 — only the load-balancer subnets carry the Kubernetes discovery tags.
    # Tagging every subnet would let the AWS Load Balancer Controller place an
    # NLB in the ledger or endpoint subnets, which #16 exists to prevent.
    each.value.role == "lb" ? var.lb_subnet_tags : {},
    {
      Name      = "${var.name_prefix}-${each.key}"
      Component = "network"
      Role      = each.value.role
      AzId      = each.value.az_id
    },
  )
}

# -----------------------------------------------------------------------------
# #12 — one route table per subnet.
# -----------------------------------------------------------------------------
# Deliberately NOT one shared table. The ledger's route tables must be distinct
# from the applications' so that a routing change made on behalf of an
# application cannot alter the ledger's reachability.
#
# NOTE WHAT IS ABSENT: there is no `route` block anywhere in this file. The only
# routes are the `local` routes AWS adds automatically for the primary and
# secondary CIDRs. The ledger subnets must never acquire a default route, and
# scripts/verify-contract.sh asserts that no 0.0.0.0/0 route exists in any table.
# In production the cloud team adds Transit Gateway routes here for on-premises
# destinations; the mimic has none, which is correct. The container registry needs
# no route at all -- it is ECR, reached through VPC endpoints (CT-3a).
# -----------------------------------------------------------------------------
resource "aws_route_table" "this" {
  for_each = var.subnets

  vpc_id = var.vpc_id

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-rt-${each.key}"
    Component = "network"
    Role      = each.value.role
  })
}

resource "aws_route_table_association" "this" {
  for_each = var.subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.this[each.key].id
}

# -----------------------------------------------------------------------------
# #13 — NACLs on the LEDGER subnets only.
# -----------------------------------------------------------------------------
# Consolidating the ledger and the application estate into one VPC removed the
# VPC-level boundary between them. A NACL restores a STATELESS L3 boundary that
# does not depend on security-group correctness — defence in depth for a system
# carrying SWIFT traffic, and a control auditors ask about.
#
# THE BASELINE IS DELIBERATELY PERMISSIVE, AND THE EXPLICIT ALLOW RULES ARE NOT
# OPTIONAL: an aws_network_acl with no rules DENIES ALL TRAFFIC. Shipping one
# without these rules would black-hole the ledger subnets on creation.
#
# The platform (`sbsa_besu`) owns the real rules — the mimic's job is only to
# prove the resource exists and is addressable by ID, not to guess the ruleset.
# -----------------------------------------------------------------------------
locals {
  ledger_subnet_keys = [for k, v in var.subnets : k if v.role == "ledger"]
}

resource "aws_network_acl" "ledger" {
  for_each = toset(local.ledger_subnet_keys)

  vpc_id     = var.vpc_id
  subnet_ids = [aws_subnet.this[each.key].id]

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-nacl-${each.key}"
    Component = "network"
    Note      = "baseline allow-all; rules owned by the platform project"
  })
}

resource "aws_network_acl_rule" "ledger_ingress_baseline" {
  for_each       = toset(local.ledger_subnet_keys)
  network_acl_id = aws_network_acl.ledger[each.key].id
  rule_number    = 100
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

resource "aws_network_acl_rule" "ledger_egress_baseline" {
  for_each       = toset(local.ledger_subnet_keys)
  network_acl_id = aws_network_acl.ledger[each.key].id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

# -----------------------------------------------------------------------------
# #10 — Gateway endpoints (S3, DynamoDB). FREE.
# -----------------------------------------------------------------------------
# Creating one writes a prefix-list route into every route table it associates
# with, which is why ownership is a question at all: the route tables are the
# cloud team's.
#
# S3 IS NOT OPTIONAL. It carries container image layer retrieval for every image
# pull, plus Terraform state. Nothing in either cluster starts without it.
#
# Associated to the ledger, app, lb and endpoint route tables — not to `data`,
# which hosts managed databases with no need for either service.
# -----------------------------------------------------------------------------
locals {
  endpoint_route_table_ids = [
    for k, v in var.subnets : aws_route_table.this[k].id
    if contains(["ledger", "app", "lb", "endpoint"], v.role)
  ]
}

resource "aws_vpc_endpoint" "s3" {
  count             = var.gateway_endpoints_created_here ? 1 : 0
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.endpoint_route_table_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-s3", Component = "network" })
}

resource "aws_vpc_endpoint" "dynamodb" {
  count             = var.gateway_endpoints_created_here ? 1 : 0
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.endpoint_route_table_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-ddb", Component = "network" })
}

# -----------------------------------------------------------------------------
# Q-2 — OPTIONAL: interface endpoints created here, simulating a cloud team that
# operates them centrally. Default OFF.
# -----------------------------------------------------------------------------
# The position we have asked for (#15 / D-11) is that the PLATFORM owns these,
# because `kms` sits on the validator-startup critical path and the SSM trio is
# the only access path to the deployment runner — neither may depend on another
# team's change queue. This toggle exists so the alternative can be exercised if
# Q-2 comes back positive.
#
# The security group below is created ONLY on this path. Under the default
# arrangement the platform owns all security groups (#6), and this project
# creates none.
# -----------------------------------------------------------------------------
resource "aws_security_group" "endpoints" {
  count       = var.simulate_central_endpoints ? 1 : 0
  name_prefix = "${var.name_prefix}-vpce-"
  description = "Simulated centrally-operated interface endpoints (Q-2 path only)"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from within the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [for k, v in var.subnets : v.cidr]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-sg", Component = "network" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.simulate_central_endpoints ? toset(var.interface_endpoint_services) : toset([])

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true # #2 — useless without both VPC DNS attributes
  security_group_ids  = [aws_security_group.endpoints[0].id]

  subnet_ids = [
    for k, v in var.subnets : aws_subnet.this[k].id if v.role == "endpoint"
  ]

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-${each.value}", Component = "network" })
}

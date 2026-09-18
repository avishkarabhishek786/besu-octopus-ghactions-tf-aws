# =============================================================================
# modules/peering — the path between the ledger VPC and the egress service.
# -----------------------------------------------------------------------------
# IN PRODUCTION this is a Transit Gateway attachment the cloud team owns, and
# the route they add to our ledger route tables is "egress prefix -> TGW". A
# VPC peering is the free, same-account stand-in. To the client both are the
# same thing: a route to a prefix. (Fidelity gap recorded in CLAUDE.md §1.)
#
# WHAT GOES INTO THE LEDGER VPC — AND WHAT DOES NOT
#   Exactly one route per LEDGER route table: the egress /24, via the peering.
#   Never 0.0.0.0/0 (mimic_vpc rule #2 stands). Never into the app, lb, endpoint
#   or data tables — the application estate has no business reaching a proxy
#   whose only permitted client is the ledger runner (CD-60).
# =============================================================================

resource "aws_vpc_peering_connection" "this" {
  vpc_id      = var.egress_vpc_id # requester: the egress service
  peer_vpc_id = var.ledger_vpc_id # accepter: the consumer
  auto_accept = true              # same account, same region

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-to-ledger"
    Component = "egress-peering"
  })
}

# DNS resolution across the peering, both ways: the runner resolves the VIP's
# private zone (associated to its VPC anyway), and the proxy could resolve
# ledger hostnames if it ever needed to log them by name.
resource "aws_vpc_peering_connection_options" "this" {
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id

  requester {
    allow_remote_vpc_dns_resolution = true
  }
  accepter {
    allow_remote_vpc_dns_resolution = true
  }
}

# Egress side: the ledger /20 is reachable back through the peering (return path).
resource "aws_route" "egress_to_ledger" {
  route_table_id            = var.egress_route_table_id
  destination_cidr_block    = var.ledger_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

# Ledger side: the cloud team's one route, in the ledger tables only.
resource "aws_route" "ledger_to_egress" {
  for_each = var.ledger_route_table_ids

  route_table_id            = each.value
  destination_cidr_block    = var.egress_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

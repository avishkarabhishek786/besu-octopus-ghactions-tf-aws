# =============================================================================
# modules/egress-vpc — the cloud team's egress VPC: the one place with an IGW.
# -----------------------------------------------------------------------------
# In production this VPC is the bank's, sits behind their Transit Gateway, and
# is the internet edge for every private VPC that is allowed any egress at all.
# Here it is a /24 with ONE public subnet holding the proxy and the NLB node.
#
# WHY AN IGW AND NOT A NAT GATEWAY
#   The proxy instance itself carries the public address (auto-assigned in the
#   public subnet). A NAT gateway would add ~USD 1.10/day for nothing: there is
#   exactly one instance, and it IS the egress point. The ledger VPC still has
#   no IGW, no NAT and no default route — the "nothing public" property of OUR
#   VPC is untouched, because this is THEIR VPC (CD-63).
# =============================================================================

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  instance_tenancy     = "default"
  enable_dns_support   = true # the NLB alias record and Squid's own resolution need both
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-vpc"
    Component = "egress"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-igw"
    Component = "egress"
  })
}

# One public subnet, addressed by AZ ID (same discipline as the hand-over: AZ
# names map to different physical zones per account).
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 2, 0) # first quarter of the block; the rest is spare
  availability_zone_id    = var.az_id
  map_public_ip_on_launch = true # the proxy is the internet edge; it needs the public address

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-public-${var.az_id}"
    Component = "egress"
    Tier      = "public"
  })
}

# The default route lives HERE and only here. The peering module adds the
# ledger prefix to this same table.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-public-rt"
    Component = "egress"
  })
}

resource "aws_route" "default_to_igw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Flow logs — evidence. After a deploy-test they show every source that ever
# reached the proxy port; the expected answer is one address (the runner) plus
# the NLB health checks. Anything else is a finding.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "flow_logs" {
  count             = var.enable_flow_logs ? 1 : 0
  name              = "/${var.name_prefix}/vpc-flow-logs"
  retention_in_days = var.flow_log_retention_days
  tags              = merge(var.tags, { Component = "egress" })
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
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"] # this group only
  }
}

resource "aws_iam_role" "flow_logs" {
  count              = var.enable_flow_logs ? 1 : 0
  name_prefix        = "${var.name_prefix}-flowlogs-"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume[0].json
  tags               = merge(var.tags, { Component = "egress" })
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
  tags                 = merge(var.tags, { Component = "egress" })
}

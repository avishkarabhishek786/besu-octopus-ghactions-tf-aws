# =============================================================================
# modules/vip — the "traffic load balancer" in front of the proxy, plus its name.
# -----------------------------------------------------------------------------
# WHAT THE CLOUD TEAM SAID: egress is fronted by a load balancer. So the client
# never sees an instance — it sees a HOSTNAME that resolves to a VIP. This module
# is that VIP (an internal NLB) and that hostname (a Route 53 private hosted
# zone, associated to the ledger VPC, standing in for corporate DNS).
#
# WHY AN NLB, NOT AN ALB
#   The client speaks HTTP CONNECT to the proxy and then carries an opaque TLS
#   tunnel through it. An ALB would try to be an HTTP endpoint in its own right
#   and cannot forward CONNECT. A TCP pass-through is the only faithful shape.
#
# WHY CLIENT-IP PRESERVATION IS THE ONE SETTING THAT MATTERS
#   The proxy's allowlist is BY SOURCE (CD-60). If the NLB rewrote the source to
#   its own address, Squid would see the NLB, not the runner, and either the ACL
#   would admit everything behind the NLB or nothing at all. Instance targets
#   preserve the client IP by default; it is set explicitly anyway so a future
#   switch to IP targets cannot silently lose it — and verify-egress.sh probe 8
#   tests it end to end.
# =============================================================================

resource "aws_lb" "vip" {
  name               = substr("${var.name_prefix}-vip", 0, 32)
  internal           = true # a private VIP: only the peered ledger VPC can reach it
  load_balancer_type = "network"
  subnets            = [var.subnet_id]

  # Deploy-tests tear down the same day (no-deletion-protection rule).
  enable_deletion_protection = false

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-vip"
    Component = "egress-vip"
  })
}

resource "aws_lb_target_group" "proxy" {
  name        = substr("${var.name_prefix}-proxy-tg", 0, 32)
  port        = var.proxy_port
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  preserve_client_ip = "true" # see the module header — the allowlist depends on it

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = merge(var.tags, { Component = "egress-vip" })
}

resource "aws_lb_target_group_attachment" "proxy" {
  target_group_arn = aws_lb_target_group.proxy.arn
  target_id        = var.target_instance_id
  port             = var.proxy_port
}

resource "aws_lb_listener" "proxy" {
  load_balancer_arn = aws_lb.vip.arn
  port              = var.proxy_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.proxy.arn
  }

  tags = merge(var.tags, { Component = "egress-vip" })
}

# -----------------------------------------------------------------------------
# The name. A private zone created against THIS VPC and then associated to the
# ledger VPC, so `proxy.<zone>` resolves from the runner. Terraform needs the
# creating VPC in the zone block and the extra association as a separate
# resource; ignore_changes stops the two from fighting over the vpc list.
# -----------------------------------------------------------------------------
resource "aws_route53_zone" "egress" {
  name    = var.dns_zone
  comment = "mimic of the bank's corporate DNS for the egress VIP (${var.name_prefix})"

  vpc {
    vpc_id = var.vpc_id
  }

  lifecycle {
    ignore_changes = [vpc]
  }

  tags = merge(var.tags, { Component = "egress-vip" })
}

resource "aws_route53_zone_association" "consumer" {
  zone_id = aws_route53_zone.egress.zone_id
  vpc_id  = var.consumer_vpc_id
}

resource "aws_route53_record" "proxy" {
  zone_id = aws_route53_zone.egress.zone_id
  name    = "${var.hostname}.${var.dns_zone}"
  type    = "A"

  alias {
    name                   = aws_lb.vip.dns_name
    zone_id                = aws_lb.vip.zone_id
    evaluate_target_health = false
  }
}

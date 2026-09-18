# =============================================================================
# modules/proxy — one Squid forward proxy, the way the bank's would look to us.
# -----------------------------------------------------------------------------
# WHAT
#   An AL2023 instance in the egress VPC's public subnet running Squid with the
#   allowlist in squid.conf.tftpl. Reached only through the NLB VIP (modules/vip)
#   from the ledger VPC over the peering; administered only over SSM.
#
# WHY SQUID
#   It is the reference implementation of an explicit CONNECT proxy with
#   source/destination ACLs — exactly the client-visible behaviour of the
#   Zscaler/BlueCoat/Palo Alto-class estate a bank runs. The client cannot tell
#   the difference, which is the fidelity bar (CLAUDE.md §0 #1).
#
# WHY `dnf install` IS ALLOWED HERE
#   D-21 (no package manager, no internet) governs OUR runner in OUR VPC. This
#   is THEIR proxy in THEIR VPC, and it has an Internet Gateway by definition.
# =============================================================================

data "aws_partition" "current" {}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# -----------------------------------------------------------------------------
# IAM — SSM Session Manager only. The proxy needs no AWS API access of its own.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "proxy" {
  name               = "${var.name_prefix}-proxy-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = merge(var.tags, { Component = "egress-proxy" })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.proxy.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "proxy" {
  name = "${var.name_prefix}-proxy-profile"
  role = aws_iam_role.proxy.name
  tags = merge(var.tags, { Component = "egress-proxy" })
}

# -----------------------------------------------------------------------------
# SECURITY GROUP
# -----------------------------------------------------------------------------
# Inbound: the proxy port from the ledger VPC (clients arrive with their real
# source address — the NLB preserves it — so the SG sees ledger IPs, not NLB
# IPs) and from this VPC (the NLB's health checks). Nothing from the internet:
# the public IP exists so packets can LEAVE, not so anything can arrive.
# Outbound: 443 only — the tunnels to Octopus, the SSM agent, and AL2023's
# HTTPS-only dnf mirrors. The Squid ACL, not this SG, is the allowlist; the SG
# keeps the surface small if the ACL were ever misconfigured.
# -----------------------------------------------------------------------------
resource "aws_security_group" "proxy" {
  name        = "${var.name_prefix}-proxy-sg"
  description = "Egress proxy: proxy port from the ledger VPC + NLB health checks; 443 out only"
  vpc_id      = var.vpc_id

  ingress {
    description = "Proxy port from the ledger VPC (client IP preserved by the NLB)"
    from_port   = var.proxy_port
    to_port     = var.proxy_port
    protocol    = "tcp"
    cidr_blocks = [var.client_cidr]
  }

  ingress {
    description = "Proxy port from this VPC (NLB health checks)"
    from_port   = var.proxy_port
    to_port     = var.proxy_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "HTTPS out: the CONNECT tunnels to Octopus, SSM, dnf mirrors"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-proxy-sg"
    Component = "egress-proxy"
  })
}

# -----------------------------------------------------------------------------
# THE INSTANCE
# -----------------------------------------------------------------------------
locals {
  squid_conf = templatefile("${path.module}/squid.conf.tftpl", {
    proxy_port           = var.proxy_port
    visible_hostname     = "${var.name_prefix}-proxy"
    allowed_source_cidr  = var.allowed_source_cidr
    allowed_destinations = var.allowed_destinations
  })
}

resource "aws_instance" "proxy" {
  ami                  = data.aws_ssm_parameter.al2023.value
  instance_type        = var.instance_type
  subnet_id            = var.subnet_id
  iam_instance_profile = aws_iam_instance_profile.proxy.name

  vpc_security_group_ids      = [aws_security_group.proxy.id]
  associate_public_ip_address = true # the egress edge; see the module header

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  # A config change must produce a NEW proxy, not a drifted one. This is a
  # mimic: recreating it costs a minute and guarantees the running ACL is the
  # one in source.
  user_data_replace_on_change = true

  # Plain shell user data is correct for a bare EC2 instance (the MIME-multipart
  # requirement in build finding B12 is EKS-node specific).
  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    STATUS=/var/lib/egress-proxy/BOOTSTRAP_STATUS
    mkdir -p /var/lib/egress-proxy
    fatal() { echo "FAILED: $1" > "$STATUS"; echo "[proxy-bootstrap] FATAL: $1"; exit 1; }

    dnf install -y -q squid || fatal "dnf install squid failed (no internet from the egress subnet? IGW/default route missing?)"

    cat > /etc/squid/squid.conf <<'SQUID'
    ${local.squid_conf}
    SQUID

    # Parse before start: a bad ACL must fail the bootstrap loudly, not leave a
    # proxy up with Squid's default (far wider) config.
    squid -k parse || fatal "squid.conf failed to parse — see /var/log/squid/cache.log"
    systemctl enable --now squid || fatal "squid failed to start"
    sleep 2
    systemctl is-active --quiet squid || fatal "squid is not active after start"

    echo "OK: squid $(squid -v | head -1 | awk '{print $4}') listening on ${var.proxy_port}; source=${var.allowed_source_cidr}; destinations=${join(",", var.allowed_destinations)}" > "$STATUS"
    echo "[proxy-bootstrap] ready"
  EOF

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-proxy"
    Component = "egress-proxy"
  })
}

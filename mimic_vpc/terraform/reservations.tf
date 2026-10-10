# =============================================================================
# reservations.tf — explicit CIDR reservations for pinned addresses (#34, B43)
# -----------------------------------------------------------------------------
# The ledger subnets are shared by the EKS nodes and the platform's In-VPC EC2
# Runner, whose IP is pinned because the egress proxy allowlists one /32
# (CD-60). The VPC CNI keeps a warm pool of secondary IPs on every node ENI,
# drawn from the subnet; on 2026-10-10 it was holding the runner's address and
# EC2 refused the instance (InvalidIPAddress.InUse). An EXPLICIT reservation is
# AWS's answer: the address is then only ever assigned on explicit request —
# which is exactly how the runner asks for it — and never automatically.
#
# This is the subnet owner's job, so in production it is the cloud team's: it
# rides the same R-10 ticket as the proxy allowlist entry for that /32.
# =============================================================================
locals {
  ledger_subnet_cidrs_by_az = module.subnets.subnet_cidrs_by_role["ledger"]
  ledger_subnet_ids_by_az   = module.subnets.subnet_ids_by_role["ledger"]
}

resource "terraform_data" "reservation_gates" {
  for_each = var.pinned_ip_reservations

  input = each.value

  lifecycle {
    precondition {
      condition     = contains(keys(local.ledger_subnet_cidrs_by_az), each.key)
      error_message = "pinned_ip_reservations: ${each.key} is not a ledger AZ (${join(", ", keys(local.ledger_subnet_cidrs_by_az))})."
    }
    precondition {
      condition = can(cidrhost("${each.value}/32", 0)) && try(
        cidrsubnet("${each.value}/${split("/", local.ledger_subnet_cidrs_by_az[each.key])[1]}", 0, 0) == local.ledger_subnet_cidrs_by_az[each.key],
      false)
      error_message = "pinned_ip_reservations: ${each.value} is not inside the ${each.key} ledger subnet (${try(local.ledger_subnet_cidrs_by_az[each.key], "?")})."
    }
  }
}

resource "aws_ec2_subnet_cidr_reservation" "pinned" {
  for_each = var.pinned_ip_reservations

  subnet_id        = local.ledger_subnet_ids_by_az[each.key]
  cidr_block       = "${each.value}/32"
  reservation_type = "explicit"
  description      = "pinned consumer address (#34 / R-10, B43)"

  depends_on = [terraform_data.reservation_gates]
}

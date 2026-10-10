# =============================================================================
# terraform/runner/ip-guard.tf — the pinned IP must be free when we plan (B43)
# -----------------------------------------------------------------------------
# The runner is pinned to the one /32 the egress proxy allowlists (CD-60), in a
# LEDGER subnet — which the EKS nodes share. The VPC CNI keeps a warm pool of
# secondary IPs on every node ENI and takes them from the subnet at random; on
# 2026-10-10 it was holding 10.60.0.250 when `terraform: runner` ran, and EC2
# refused the instance mid-apply (InvalidIPAddress.InUse) — after the chain and
# the runner bundle had already succeeded.
#
# The PERMANENT fix is the subnet owner's: an EXPLICIT subnet CIDR reservation
# on the /32 (requirement #34 / R-10; mimic_vpc `pinned_ip_reservations`).
# AWS then never hands that address out automatically — only an explicit
# private_ip request like ours can take it.
#
# This guard is the platform's half: fail at PLAN, naming the holder and the
# fix, instead of at apply with half an environment up. It cannot see the
# reservation (the provider has no data source for one), so it catches the
# symptom — and the symptom is exactly what breaks the apply.
#
# The runner itself holds the IP on every plan after the first; that is fine.
# Any OTHER interface holding it is not.
# =============================================================================
data "aws_network_interfaces" "runner_ip_holders" {
  count = local.runner_private_ip == null ? 0 : 1

  filter {
    name   = "subnet-id"
    values = [local.runner_subnet_id]
  }
  filter {
    name   = "addresses.private-ip-address"
    values = [local.runner_private_ip]
  }
}

data "aws_instances" "existing_runner" {
  count = local.runner_private_ip == null ? 0 : 1

  instance_tags = {
    Name = "${local.chain.name_prefix}-runner"
  }
  instance_state_names = ["pending", "running", "stopping", "stopped"]
}

locals {
  runner_ip_holders = local.runner_private_ip == null ? [] : data.aws_network_interfaces.runner_ip_holders[0].ids
  runner_holds_ip   = local.runner_private_ip == null ? false : contains(data.aws_instances.existing_runner[0].private_ips, local.runner_private_ip)
}

resource "terraform_data" "ip_guard" {
  lifecycle {
    precondition {
      condition     = length(local.runner_ip_holders) == 0 || local.runner_holds_ip
      error_message = <<-EOT
        The runner's pinned IP ${coalesce(local.runner_private_ip, "-")} is held by ${join(", ", local.runner_ip_holders)} in ${local.runner_subnet_id}, which is not the runner (B43). EC2 would refuse the instance with InvalidIPAddress.InUse mid-apply.
        Usually the VPC CNI's warm pool on an EKS node (description "aws-K8S-i-..."). The lasting fix belongs to the subnet owner: an EXPLICIT subnet CIDR reservation on this /32 (#34 / R-10). Then free it:
          aws ec2 create-subnet-cidr-reservation --subnet-id ${local.runner_subnet_id} --cidr ${coalesce(local.runner_private_ip, "0.0.0.0")}/32 --reservation-type explicit --description "CD-60 runner"
          aws ec2 unassign-private-ip-addresses --network-interface-id <the ENI above> --private-ip-addresses ${coalesce(local.runner_private_ip, "0.0.0.0")}
        and plan again.
      EOT
    }
  }
}

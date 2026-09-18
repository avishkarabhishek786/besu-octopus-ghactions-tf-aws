# =============================================================================
# modules/network-contract — CREATES NO INFRASTRUCTURE. ASSERTS EVERYTHING.
# -----------------------------------------------------------------------------
# The single highest-value module in this project.
#
# The network belongs to another team. Every assumption we make about it is a
# silent dependency that, when broken, surfaces twenty minutes into an EKS apply
# — or worse, at Kubernetes Service-creation time, long after budget is spent.
# With no Internet Gateway, misrouted calls do not error: they HANG until
# timeout, which is the most expensive failure mode to diagnose.
#
# This module converts every one of those assumptions into a named, fail-fast
# assertion that cites the requirement number from
# docs/NETWORK_REQUIREMENTS_CLOUD_TEAM.md, so a failure can be quoted straight
# back to the cloud team.
#
# WHY `terraform_data` AND NOT `check` BLOCKS
#   `check` blocks emit WARNINGS and let the apply proceed. That is wrong here:
#   these are gates, not advisories. `terraform_data` with `lifecycle`
#   preconditions FAILS THE PLAN. It creates no AWS resource — only a state
#   placeholder — so the module still builds nothing.
# =============================================================================

locals {
  all_subnet_ids = merge(
    { for az, id in var.ledger_subnet_ids : "ledger-${az}" => id },
    { for az, id in var.app_subnet_ids : "app-${az}" => id },
    { for az, id in var.lb_subnet_ids : "lb-${az}" => id },
    { for az, id in var.endpoint_subnet_ids : "endpoint-${az}" => id },
    { for az, id in var.data_subnet_ids : "data-${az}" => id },
  )

  all_route_table_ids = merge(
    { for az, id in var.ledger_route_table_ids : "ledger-${az}" => id },
    { for az, id in var.app_route_table_ids : "app-${az}" => id },
    { for az, id in var.lb_route_table_ids : "lb-${az}" => id },
    { for az, id in var.endpoint_route_table_ids : "endpoint-${az}" => id },
  )
}

locals {
  # ---------------------------------------------------------------------------
  # CIDR overlap arithmetic.
  # ---------------------------------------------------------------------------
  # Terraform has no CIDR-overlap function, and this check guards a setting that
  # is IMMUTABLE after cluster creation (#9), so it is worth computing properly
  # rather than eyeballing. Two blocks overlap iff, when both are shifted right
  # by (32 - the SHORTER prefix length), their network integers are equal.
  # ---------------------------------------------------------------------------
  _cidrs = {
    service   = var.eks_service_cidr
    primary   = var.vpc_cidr_primary
    secondary = var.vpc_cidr_secondary
  }

  _num = {
    for k, c in local._cidrs : k => c == null ? null : {
      bits = tonumber(split("/", c)[1])
      int = (
        tonumber(split(".", split("/", c)[0])[0]) * 16777216 +
        tonumber(split(".", split("/", c)[0])[1]) * 65536 +
        tonumber(split(".", split("/", c)[0])[2]) * 256 +
        tonumber(split(".", split("/", c)[0])[3])
      )
    }
  }

  _shift_primary = pow(2, 32 - min(local._num.service.bits, local._num.primary.bits))
  service_overlaps_primary = (
    floor(local._num.service.int / local._shift_primary) ==
    floor(local._num.primary.int / local._shift_primary)
  )

  _shift_secondary = var.vpc_cidr_secondary == null ? 1 : pow(2, 32 - min(local._num.service.bits, local._num.secondary.bits))
  service_overlaps_secondary = var.vpc_cidr_secondary == null ? false : (
    floor(local._num.service.int / local._shift_secondary) ==
    floor(local._num.secondary.int / local._shift_secondary)
  )
}

data "aws_vpc" "this" { id = var.vpc_id }

data "aws_subnet" "this" {
  for_each = local.all_subnet_ids
  id       = each.value
}

data "aws_route_table" "this" {
  for_each       = local.all_route_table_ids
  route_table_id = each.value
}

# -----------------------------------------------------------------------------
# GATE 1 — VPC attributes. All three are IMMUTABLE or effectively so.
# -----------------------------------------------------------------------------
resource "terraform_data" "vpc_attributes" {
  input = var.vpc_id

  lifecycle {
    precondition {
      condition     = data.aws_vpc.this.instance_tenancy == "default"
      error_message = "#1 VIOLATED: VPC instance_tenancy is '${data.aws_vpc.this.instance_tenancy}', not 'default'. Every instance is forced onto dedicated tenancy regardless of our launch template: ~USD 1,460/month in per-region fees plus ~10% on instance rates, and EKS managed node groups do not support dedicated HOST placement at all. This CANNOT be changed on an existing VPC — the cloud team must recreate it."
    }
    precondition {
      condition     = data.aws_vpc.this.enable_dns_support
      error_message = "#2 VIOLATED: enableDnsSupport is false. Interface endpoint Private DNS cannot override the public service hostname, so every AWS SDK call resolves to a public IP with no route and HANGS until timeout. Breaks node bootstrap, IRSA, KMS decryption of validator keys, secret retrieval and log shipping."
    }
    precondition {
      condition     = data.aws_vpc.this.enable_dns_hostnames
      error_message = "#2 VIOLATED: enableDnsHostnames is false. Private DNS requires BOTH attributes; symptoms are identical to enableDnsSupport being off."
    }
    precondition {
      condition     = data.aws_vpc.this.cidr_block == var.vpc_cidr_primary
      error_message = "Hand-over mismatch: the VPC's actual CIDR is ${data.aws_vpc.this.cidr_block} but the contract declares ${var.vpc_cidr_primary}. The tfvars fragment is stale — re-request it from the cloud team."
    }
  }
}

# -----------------------------------------------------------------------------
# GATE 2 — AZ placement and subnet membership.
# -----------------------------------------------------------------------------
resource "terraform_data" "az_placement" {
  input = var.az_ids

  lifecycle {
    precondition {
      condition     = length(var.az_ids) == 3
      error_message = "#5 VIOLATED: exactly 3 AZ IDs required. QBFT runs 4 validators spread across 3 AZs so the loss of one zone leaves a 2F+1 quorum; fewer zones means a single AZ failure can halt the ledger."
    }
    precondition {
      condition     = length(distinct([for k, s in data.aws_subnet.this : s.availability_zone_id])) == 3
      error_message = "#5 VIOLATED: the supplied subnets span ${length(distinct([for k, s in data.aws_subnet.this : s.availability_zone_id]))} distinct AZ IDs, not 3."
    }
    precondition {
      condition     = alltrue([for k, s in data.aws_subnet.this : s.vpc_id == var.vpc_id])
      error_message = "Hand-over mismatch: one or more supplied subnets do not belong to VPC ${var.vpc_id}."
    }
    precondition {
      condition     = alltrue([for k, s in data.aws_subnet.this : !s.map_public_ip_on_launch])
      error_message = "A supplied subnet auto-assigns public IPs. This VPC has no Internet Gateway and must have no publicly-addressed workloads."
    }
  }
}

# -----------------------------------------------------------------------------
# GATE 3 — the load-balancer discovery tag.
# -----------------------------------------------------------------------------
# The nastiest failure in the whole contract: without this tag everything
# provisions cleanly and the NLB carrying SWIFT mTLS traffic simply never
# appears, days later, at Service-creation time. Catch it before the cluster is
# even built.
# -----------------------------------------------------------------------------
resource "terraform_data" "lb_subnet_tags" {
  input = var.lb_subnet_ids

  lifecycle {
    precondition {
      condition = alltrue([
        for az, id in var.lb_subnet_ids :
        try(data.aws_subnet.this["lb-${az}"].tags["kubernetes.io/role/internal-elb"], "") == "1"
      ])
      error_message = "#4 VIOLATED: 'kubernetes.io/role/internal-elb=1' is missing from at least one load-balancer subnet. The AWS Load Balancer Controller discovers subnets by tag, so the internal NLBs carrying SWIFT mTLS traffic will never be placed — and the failure appears only when a Kubernetes Service is created, not now. If a tag policy or landing-zone guardrail strips this tag, the cloud team must be told."
    }
  }
}

# -----------------------------------------------------------------------------
# GATE 4 — the no-egress property.
# -----------------------------------------------------------------------------
# The ledger must never acquire a default route. Asserted three ways because
# each represents a different mistake: a default route added for an application
# (#12), an Internet Gateway attached to the VPC, and a NAT Gateway.
# -----------------------------------------------------------------------------
resource "terraform_data" "no_egress" {
  input = var.vpc_id

  lifecycle {
    precondition {
      condition = alltrue([
        for k, rt in data.aws_route_table.this :
        length([for r in rt.routes : r if r.cidr_block == "0.0.0.0/0"]) == 0
      ])
      error_message = "#12 VIOLATED: a supplied route table carries a 0.0.0.0/0 route. This VPC is air-gapped by design and the ledger subnets must never acquire a default route. If the cloud team added one for an application, the ledger needs its own dedicated route tables."
    }
    precondition {
      condition = alltrue([
        for k, rt in data.aws_route_table.this :
        length([for r in rt.routes : r if can(regex("^igw-", coalesce(r.gateway_id, "-")))]) == 0
      ])
      error_message = "An Internet Gateway is routed from a supplied route table. This VPC must have no IGW (constraint CT-2)."
    }
    precondition {
      condition = alltrue([
        for k, rt in data.aws_route_table.this :
        length([for r in rt.routes : r if coalesce(r.nat_gateway_id, "-") != "-"]) == 0
      ])
      error_message = "A NAT Gateway is routed from a supplied route table. NAT requires a public subnet, which this VPC does not have."
    }
  }
}

# -----------------------------------------------------------------------------
# GATE 5 — capacity. Free addresses are a shared, exhaustible resource.
# -----------------------------------------------------------------------------
# A ledger subnet that runs out of addresses means validator pods cannot be
# scheduled, and below 3 of 4 validators QBFT loses quorum and block production
# stops. Refusing to build is far better than building something that fails
# under an application team's autoscaler months later.
# -----------------------------------------------------------------------------
resource "terraform_data" "capacity" {
  input = var.min_free_ips_ledger

  lifecycle {
    precondition {
      condition = alltrue([
        for az, id in var.ledger_subnet_ids :
        data.aws_subnet.this["ledger-${az}"].available_ip_address_count >= var.min_free_ips_ledger
      ])
      error_message = "#11 VIOLATED: a ledger subnet has fewer than ${var.min_free_ips_ledger} free addresses. The VPC CNI reserves whole ENIs' worth of IPs per node (~50 on m6i.xlarge), so this WILL leave validator pods unschedulable. If the ledger shares subnets with applications, request dedicated ledger subnets."
    }
    precondition {
      condition = alltrue([
        for k, s in data.aws_subnet.this :
        s.available_ip_address_count >= var.min_free_ips_other
      ])
      error_message = "A supplied subnet has fewer than ${var.min_free_ips_other} free addresses."
    }
  }
}

# -----------------------------------------------------------------------------
# GATE 6 — EKS service CIDR. IMMUTABLE after cluster creation (#9).
# -----------------------------------------------------------------------------
resource "terraform_data" "service_cidr" {
  input = var.eks_service_cidr

  lifecycle {
    precondition {
      condition     = !local.service_overlaps_primary
      error_message = "#9 VIOLATED: the EKS service CIDR ${var.eks_service_cidr} overlaps the VPC primary CIDR ${var.vpc_cidr_primary}. This value is IMMUTABLE after cluster creation — a collision found later means rebuilding the cluster."
    }
    precondition {
      condition     = !local.service_overlaps_secondary
      error_message = "#9 VIOLATED: the EKS service CIDR ${var.eks_service_cidr} overlaps the secondary CIDR ${coalesce(var.vpc_cidr_secondary, "-")}."
    }
  }
}

# -----------------------------------------------------------------------------
# GATE 7 — region portability.
# -----------------------------------------------------------------------------
# Everything here is region-parameterised so that moving production to
# af-south-1 is a tfvars change. `az_ids` is the one input that cannot travel —
# AZ IDs are region-scoped — and a stale hand-over file is the likeliest way to
# get a region switch wrong.
#
# Two distinct mistakes are caught:
#   1. az_ids that do not exist in the configured region at all
#   2. az_ids that exist, but disagree with the AZs the supplied subnets are
#      actually in — i.e. the tfvars fragment is from a previous deployment
# -----------------------------------------------------------------------------
data "aws_availability_zones" "this" {
  state = "available"
}

resource "terraform_data" "region_portability" {
  input = var.az_ids

  lifecycle {
    precondition {
      condition     = length(setsubtract(toset(var.az_ids), toset(data.aws_availability_zones.this.zone_ids))) == 0
      error_message = "az_ids ${jsonencode(var.az_ids)} are not all valid in this region. Valid here: ${jsonencode(data.aws_availability_zones.this.zone_ids)}. AZ IDs are region-scoped — when you switch region you must update az_ids AND re-request the network hand-over."
    }
    precondition {
      condition     = toset(var.az_ids) == toset([for k, s in data.aws_subnet.this : s.availability_zone_id])
      error_message = "STALE HAND-OVER: az_ids ${jsonencode(var.az_ids)} disagree with the AZs the supplied subnets are actually in (${jsonencode(distinct([for k, s in data.aws_subnet.this : s.availability_zone_id]))}). Re-request network-handover.auto.tfvars from the cloud team."
    }
  }
}

# -----------------------------------------------------------------------------
# GATE 8 — the cluster must be built in the VPC's own region.
# -----------------------------------------------------------------------------
# `primary_region` drives the AWS provider; `network_region` is a fact stated by
# the hand-over. If they diverge, every subnet lookup fails with "InvalidSubnetID
# .NotFound" — technically accurate, entirely unhelpful, and it appears only
# after the provider has been configured.
#
# This is the mistake a region switch invites: change primary_region to
# af-south-1, forget to re-request the hand-over, and the subnet IDs still point
# at us-east-1.
# -----------------------------------------------------------------------------
resource "terraform_data" "region_agreement" {
  input = var.deploy_region

  lifecycle {
    precondition {
      condition     = var.deploy_region == var.network_region
      error_message = "REGION MISMATCH: this root deploys into '${var.deploy_region}' but the network hand-over describes a VPC in '${var.network_region}'. Subnet and route-table IDs do not travel between regions — re-request network-handover.auto.tfvars for '${var.deploy_region}', or correct primary_region."
    }
  }
}

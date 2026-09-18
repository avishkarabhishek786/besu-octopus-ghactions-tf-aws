# =============================================================================
# main.tf (root) — wires the four modules and asserts the shape.
# -----------------------------------------------------------------------------
# This project creates: one small VPC with an Internet Gateway, one Squid
# forward proxy, one internal NLB (the "traffic load balancer" VIP), one private
# hosted zone associated to the ledger VPC, one VPC peering, and exactly one
# route in each LEDGER route table. That is the cloud team's shared egress, as
# far as a consumer can observe it (CD-63).
#
# It never creates anything else inside the ledger VPC, and never a default
# route there — `mimic_vpc` rule #2 is unchanged.
# =============================================================================

locals {
  name_prefix = "${var.project_name}-${var.environment}-egress"

  # CD-59: the ONLY two permitted destinations, derived from the instance name.
  allowed_destinations = [
    "${var.octopus_instance}.octopus.app",
    "polling.${var.octopus_instance}.octopus.app",
  ]

  # CD-60: the ONLY permitted source.
  allowed_source_cidr = "${var.runner_private_ip}/32"

  proxy_fqdn = "${var.proxy_hostname}.${var.proxy_dns_zone}"
}

# -----------------------------------------------------------------------------
# CIDR arithmetic. Terraform has no cidrcontains() (build finding B1), so
# overlap and membership are computed on integers: an IPv4 address is a base-256
# number, a CIDR is [network, network + 2^(32-prefix) - 1].
# -----------------------------------------------------------------------------
locals {
  _ip_to_int = { for c in compact([var.egress_vpc_cidr, var.vpc_cidr_primary, var.vpc_cidr_secondary]) :
    c => sum([for i, o in split(".", cidrhost(c, 0)) : tonumber(o) * pow(256, 3 - i)])
  }
  _cidr_size = { for c in keys(local._ip_to_int) : c => pow(2, 32 - tonumber(split("/", c)[1])) }
  _range     = { for c in keys(local._ip_to_int) : c => { lo = local._ip_to_int[c], hi = local._ip_to_int[c] + local._cidr_size[c] - 1 } }

  egress_overlaps_primary   = local._range[var.egress_vpc_cidr].lo <= local._range[var.vpc_cidr_primary].hi && local._range[var.vpc_cidr_primary].lo <= local._range[var.egress_vpc_cidr].hi
  egress_overlaps_secondary = var.vpc_cidr_secondary == null ? false : (local._range[var.egress_vpc_cidr].lo <= local._range[var.vpc_cidr_secondary].hi && local._range[var.vpc_cidr_secondary].lo <= local._range[var.egress_vpc_cidr].hi)

  # Is the runner's pinned IP inside one of the ledger subnets? The hand-over's
  # informational subnet_cidrs_by_role makes this checkable here; when absent we
  # cannot tell and say so rather than guess.
  ledger_subnet_cidrs = var.subnet_cidrs_by_role == null ? [] : values(var.subnet_cidrs_by_role["ledger"])
  runner_ip_in_ledger = length(local.ledger_subnet_cidrs) == 0 ? true : anytrue([
    for c in local.ledger_subnet_cidrs : cidrsubnet("${var.runner_private_ip}/${split("/", c)[1]}", 0, 0) == c
  ])
}

# -----------------------------------------------------------------------------
# HARD GATES — these must block, not warn, so they ride terraform_data
# preconditions (a `check` block only warns).
# -----------------------------------------------------------------------------
data "aws_availability_zones" "this" {
  state = "available"
}

resource "terraform_data" "gates" {
  input = {
    egress_vpc_cidr = var.egress_vpc_cidr
    runner_ip       = var.runner_private_ip
    az_id           = var.az_id
  }

  lifecycle {
    precondition {
      condition     = var.region == var.network_region
      error_message = "region (${var.region}) must equal the hand-over's network_region (${var.network_region}): the peering is same-region, as the bank's TGW attachment would be."
    }
    precondition {
      condition     = !local.egress_overlaps_primary
      error_message = "egress_vpc_cidr ${var.egress_vpc_cidr} overlaps the ledger primary CIDR ${var.vpc_cidr_primary}. VPC peering refuses overlapping CIDRs — pick a disjoint block."
    }
    precondition {
      condition     = !local.egress_overlaps_secondary
      error_message = "egress_vpc_cidr ${var.egress_vpc_cidr} overlaps the ledger SECONDARY CIDR ${coalesce(var.vpc_cidr_secondary, "n/a")}. The secondary block is unused but associated, and peering counts it."
    }
    precondition {
      condition     = local.runner_ip_in_ledger
      error_message = "runner_private_ip ${var.runner_private_ip} is not inside any ledger subnet (${join(", ", local.ledger_subnet_cidrs)}). The allowlisted source must be the runner's address IN a ledger subnet, or the proxy will refuse the Tentacle (CD-60)."
    }
    precondition {
      condition     = contains(data.aws_availability_zones.this.zone_ids, var.az_id)
      error_message = "az_id ${var.az_id} is not valid in region ${var.region}. Valid AZ IDs here: ${jsonencode(data.aws_availability_zones.this.zone_ids)}."
    }
  }
}

# -----------------------------------------------------------------------------
# The modules.
# -----------------------------------------------------------------------------
module "egress_vpc" {
  source = "./modules/egress-vpc"

  name_prefix             = local.name_prefix
  region                  = var.region
  vpc_cidr                = var.egress_vpc_cidr
  az_id                   = var.az_id
  enable_flow_logs        = var.enable_flow_logs
  flow_log_retention_days = var.flow_log_retention_days
  tags                    = {}

  depends_on = [terraform_data.gates]
}

module "proxy" {
  source = "./modules/proxy"

  name_prefix          = local.name_prefix
  region               = var.region
  vpc_id               = module.egress_vpc.vpc_id
  vpc_cidr             = var.egress_vpc_cidr
  subnet_id            = module.egress_vpc.public_subnet_id
  instance_type        = var.instance_type
  proxy_port           = var.proxy_port
  allowed_source_cidr  = local.allowed_source_cidr
  allowed_destinations = local.allowed_destinations
  client_cidr          = var.vpc_cidr_primary # SG: who may reach the proxy port (the ACL narrows further)
  tags                 = {}
}

module "vip" {
  source = "./modules/vip"

  name_prefix        = local.name_prefix
  vpc_id             = module.egress_vpc.vpc_id
  subnet_id          = module.egress_vpc.public_subnet_id
  proxy_port         = var.proxy_port
  target_instance_id = module.proxy.instance_id
  dns_zone           = var.proxy_dns_zone
  hostname           = var.proxy_hostname
  consumer_vpc_id    = var.vpc_id
  tags               = {}
}

module "peering" {
  source = "./modules/peering"

  name_prefix            = local.name_prefix
  egress_vpc_id          = module.egress_vpc.vpc_id
  egress_vpc_cidr        = var.egress_vpc_cidr
  egress_route_table_id  = module.egress_vpc.public_route_table_id
  ledger_vpc_id          = var.vpc_id
  ledger_vpc_cidr        = var.vpc_cidr_primary
  ledger_route_table_ids = var.ledger_route_table_ids
  tags                   = {}
}

# =============================================================================
# handover.tf — the cloud team's network, as consumed by this project.
# -----------------------------------------------------------------------------
# Values arrive in `network-handover.auto.tfvars`, which Terraform loads
# automatically. During development that file is produced by the sibling
# project:  mimic_vpc/scripts/emit-handover.sh
#
# In production it is assembled BY HAND from what the cloud team sends. Its
# shape is the contract.
#
# NOTHING downstream may read these variables directly — everything consumes
# module.network.* instead, so no cluster can be built on an unvalidated network.
# =============================================================================

variable "vpc_id" { type = string }
variable "vpc_cidr_primary" { type = string }
variable "vpc_cidr_secondary" {
  type    = string
  default = null
}
variable "dhcp_options_id" {
  type    = string
  default = null
}
variable "network_region" {
  description = <<-EOT
    #5 — the region the cloud team's VPC lives in. A FACT about the hand-over,
    not a preference: `primary_region` must equal it, and the network-contract
    module asserts that. Without the assertion, a tfvars edit could point the
    cluster at one region while the subnet IDs belong to another — which fails
    late and confusingly rather than at plan time.
  EOT
  type        = string
}

variable "az_ids" { type = list(string) }

variable "ledger_subnet_ids" { type = map(string) }
variable "app_subnet_ids" { type = map(string) }
variable "lb_subnet_ids" { type = map(string) }
variable "endpoint_subnet_ids" { type = map(string) }
variable "data_subnet_ids" { type = map(string) }

variable "ledger_route_table_ids" { type = map(string) }
variable "app_route_table_ids" { type = map(string) }
variable "lb_route_table_ids" { type = map(string) }
variable "endpoint_route_table_ids" { type = map(string) }

variable "ledger_nacl_ids" {
  description = "#13 — the cloud team owns the NACLs; we manage the RULES."
  type        = map(string)
  default     = {}
}

variable "gateway_endpoints_exist" {
  description = "#10 — true when the cloud team created the S3/DynamoDB gateway endpoints; false when we must create them."
  type        = bool
  default     = false
}

variable "central_interface_endpoints" {
  description = "Q-2 — true when the cloud team operates interface endpoints centrally, so we must NOT create our own."
  type        = bool
  default     = false
}

variable "subnet_cidrs_by_role" {
  description = "Informational — for security-group and NACL rule authoring."
  type        = map(map(string))
  default     = {}
}

# -----------------------------------------------------------------------------
# THE GATE. Every apply passes through this before touching anything else.
# -----------------------------------------------------------------------------
module "network_contract" {
  source = "../modules/network-contract"

  # WITHOUT THIS the gates inherit the DEFAULT provider, whose region comes from
  # the shell (AWS_REGION / AWS_DEFAULT_REGION / profile) rather than from
  # var.primary_region — so they would validate a different region's network
  # than the one being deployed into. Gate 8 cannot catch that: it compares two
  # variables, not the provider's actual region.
  providers = {
    aws = aws.primary
  }

  vpc_id             = var.vpc_id
  vpc_cidr_primary   = var.vpc_cidr_primary
  network_region     = var.network_region
  deploy_region      = var.primary_region
  vpc_cidr_secondary = var.vpc_cidr_secondary
  az_ids             = var.az_ids

  ledger_subnet_ids   = var.ledger_subnet_ids
  app_subnet_ids      = var.app_subnet_ids
  lb_subnet_ids       = var.lb_subnet_ids
  endpoint_subnet_ids = var.endpoint_subnet_ids
  data_subnet_ids     = var.data_subnet_ids

  ledger_route_table_ids   = var.ledger_route_table_ids
  app_route_table_ids      = var.app_route_table_ids
  lb_route_table_ids       = var.lb_route_table_ids
  endpoint_route_table_ids = var.endpoint_route_table_ids
}

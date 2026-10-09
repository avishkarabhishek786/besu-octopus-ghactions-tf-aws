# Keyed by AZ ID so the platform can place workloads deterministically (#5).
output "subnet_ids_by_role" {
  description = "role => { az_id => subnet_id }"
  value = {
    for role in distinct([for v in var.subnets : v.role]) :
    role => { for k, v in var.subnets : v.az_id => aws_subnet.this[k].id if v.role == role }
  }
}

output "route_table_ids_by_role" {
  description = "role => { az_id => route_table_id }"
  value = {
    for role in distinct([for v in var.subnets : v.role]) :
    role => { for k, v in var.subnets : v.az_id => aws_route_table.this[k].id if v.role == role }
  }
}

output "ledger_nacl_ids" {
  description = "az_id => nacl_id for the LEDGER subnets. #13 was withdrawn as an ask and D-32 made the rules the cloud team's: the mimic now authors them in nacl.tf. Exported so the platform can READ and verify them (verify-subnet-rules.sh), not manage them."
  value       = { for k in local.ledger_subnet_keys : var.subnets[k].az_id => aws_network_acl.role[k].id }
}

output "subnet_cidrs_by_role" {
  value = {
    for role in distinct([for v in var.subnets : v.role]) :
    role => { for k, v in var.subnets : v.az_id => v.cidr if v.role == role }
  }
}

output "nacl_rules_authored" {
  description = <<-EOT
    Every NACL rule this project authored, with the #34 flow each implements.
    Exported for three reasons, all practical:
      * an operator can see WHAT WAS PERMITTED without reading HCL or the console;
      * the platform's verify-subnet-rules.sh output can be compared against it
        line by line, so a disagreement is visible rather than argued about;
      * when `nacl_break_flow` is set, the dropped rules are simply absent here,
        which makes the fixture's current state self-describing.
    Empty unless nacl_mode = "flows".
  EOT
  value = var.nacl_mode != "flows" ? [] : [
    for k, r in local.nacl_rules_effective : {
      subnet    = r.subnet
      direction = r.egress ? "egress" : "ingress"
      rule      = r.rule_num
      protocol  = r.proto
      ports     = "${r.from}-${r.to}"
      cidr      = r.cidr
      flow      = r.flow
    }
  ]
}

output "nacl_mode" {
  description = "Which rule mode produced the above. Carried into the hand-over so a confusing platform failure can be traced to the fixture's configuration in one step."
  value       = var.nacl_mode
}

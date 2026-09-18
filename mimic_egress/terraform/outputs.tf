# =============================================================================
# outputs.tf — THE HAND-OVER CONTRACT (what the bank's ticket reply contains)
# -----------------------------------------------------------------------------
# `scripts/emit-handover.sh` renders these into `egress-handover.auto.tfvars`
# for the platform. Only CLIENT CONFIGURATION crosses this boundary: a hostname,
# a port, a routed prefix, the allowlisted source and destinations. Nothing
# about how the proxy is built (instance, Squid, NLB, peering) is exposed — the
# bank would not tell us either, and the platform must not come to depend on it.
# =============================================================================

output "egress_proxy_host" {
  description = "Hostname of the egress VIP as resolvable from the ledger VPC. The platform configures `Tentacle polling-proxy --proxyHost` with this (CD-57)."
  value       = local.proxy_fqdn
}

output "egress_proxy_port" {
  description = "TCP port of the egress VIP (`--proxyPort`)."
  value       = var.proxy_port
}

output "egress_vpc_cidr" {
  description = "The prefix the ledger route tables now route to the egress service. For security-group authoring and for checking that no H6 NetworkPolicy allow-rule names it."
  value       = var.egress_vpc_cidr
}

output "egress_allowed_source" {
  description = "The single /32 the proxy admits (CD-60). The platform's runner MUST launch with this address — sbsa_besu's runner root reads it as its runner_private_ip default."
  value       = local.allowed_source_cidr
}

output "egress_allowed_destinations" {
  description = "The two hostnames the proxy permits, CONNECT to 443 only (CD-59). Informational — mirrors the ticket."
  value       = local.allowed_destinations
}

# --- Operator-only (NOT part of the hand-over file) ---------------------------
output "proxy_instance_id" {
  description = "The Squid instance, for `aws ssm start-session` when reading access.log. Operator-only; never emitted to the platform."
  value       = module.proxy.instance_id
}

output "peering_connection_id" {
  description = "For teardown checks. Operator-only."
  value       = module.peering.peering_connection_id
}

output "region" { value = var.region }

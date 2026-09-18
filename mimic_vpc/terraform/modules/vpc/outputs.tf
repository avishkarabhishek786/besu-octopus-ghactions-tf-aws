output "vpc_id" { value = aws_vpc.this.id }
output "vpc_cidr_primary" { value = aws_vpc.this.cidr_block }
output "vpc_cidr_secondary" {
  value = var.enable_secondary_cidr ? var.secondary_cidr : null
}
output "dhcp_options_id" { value = aws_vpc_dhcp_options.this.id }

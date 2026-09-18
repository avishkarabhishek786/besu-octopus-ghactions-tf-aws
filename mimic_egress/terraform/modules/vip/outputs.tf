output "proxy_fqdn" { value = aws_route53_record.proxy.fqdn }
output "nlb_dns_name" { value = aws_lb.vip.dns_name }
output "zone_id" { value = aws_route53_zone.egress.zone_id }

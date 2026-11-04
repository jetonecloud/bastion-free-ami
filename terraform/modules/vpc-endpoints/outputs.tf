output "interface_endpoint_ids" {
  description = "Map of service short name to interface endpoint ID."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "interface_endpoint_dns_entries" {
  description = "Map of service short name to the endpoint's DNS entries, for diagnosing resolution problems from an access node."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.dns_entry }
}

output "s3_endpoint_id" {
  description = "ID of the S3 gateway endpoint, or empty when disabled."
  value       = var.enable_s3_endpoint ? aws_vpc_endpoint.s3[0].id : ""
}

output "s3_endpoint_prefix_list_id" {
  description = "Prefix list ID of the S3 gateway endpoint. Use this in an access node egress rule if you narrow egress_cidr_blocks and still need S3 for agent updates."
  value       = var.enable_s3_endpoint ? aws_vpc_endpoint.s3[0].prefix_list_id : ""
}

output "security_group_id" {
  description = "ID of the endpoint security group, or empty when existing groups were supplied."
  value       = var.create_security_group ? aws_security_group.endpoints[0].id : ""
}

output "enabled_endpoints" {
  description = "Endpoints this module created, so a reviewer can confirm the set matches what the access path needs and nothing more."
  value = concat(
    keys(local.interface_endpoints),
    var.enable_s3_endpoint ? ["s3 (gateway)"] : [],
  )
}

output "monthly_cost_estimate_usd" {
  description = "Rough monthly cost of the interface endpoints created here, at the us-east-1 list price of ~$0.01/hour per AZ per endpoint, excluding data processing. Gateway endpoints are free. Compare against ~$33/month for a single NAT gateway: a private no-NAT setup is usually both cheaper and more contained."
  value = format(
    "~$%.2f/month for %d interface endpoint(s) across %d subnet(s), excluding data processing charges",
    length(local.interface_endpoints) * length(var.subnet_ids) * 0.01 * 730,
    length(local.interface_endpoints),
    length(var.subnet_ids),
  )
}

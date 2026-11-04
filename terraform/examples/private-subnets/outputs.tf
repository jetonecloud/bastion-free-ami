output "access_role_arn" {
  description = "Role the platform team assumes to reach the access node. MFA is required to assume it."
  value       = module.access_iam.role_arns["platform"]
}

output "node_filter" {
  description = "Tag filter for scripts/connect and scripts/verify."
  value       = module.access_node.node_filter
}

output "find_node_command" {
  description = "List healthy access nodes."
  value       = module.access_node.find_node_command
}

output "endpoints_created" {
  description = "The VPC endpoints backing the access path. With no NAT gateway, this list is the complete set of ways out of the subnet."
  value       = module.vpc_endpoints.enabled_endpoints
}

output "endpoint_cost_estimate" {
  description = "Rough monthly cost of the interface endpoints, for comparison against a NAT gateway."
  value       = module.vpc_endpoints.monthly_cost_estimate_usd
}

output "session_log_group" {
  description = "CloudWatch Logs group holding shell session transcripts."
  value       = module.session_logging.cloudwatch_log_group_name
}

output "session_log_bucket" {
  description = "S3 bucket archiving session logs. Public access is blocked, SSE-KMS and versioning are on."
  value       = module.session_logging.s3_bucket_name
}

output "session_logging_limitations" {
  description = "What is and is not captured. Port-forwarding traffic contents are not in either destination."
  value       = module.session_logging.session_logging_limitations
}

output "emergency_scale_up_command" {
  description = "Restore access capacity without SSH."
  value       = module.access_node.emergency_scale_up_command
}

output "no_internet_egress_note" {
  description = "What this example's network posture actually guarantees."
  value       = "This VPC has no internet gateway, no NAT gateway, and no 0.0.0.0/0 route. Access nodes reach AWS services only through the endpoints listed in endpoints_created, and have no path to the internet to exfiltrate over. Anything else the node needs must get its own endpoint -- there is no NAT to fall back on."
}

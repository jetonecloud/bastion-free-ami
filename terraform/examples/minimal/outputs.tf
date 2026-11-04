output "access_role_arn" {
  description = "Role the platform team assumes to reach the access node."
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

output "connect_shell_command" {
  description = "Open a shell on a healthy access node. Replace <instance-id> with a value from find_node_command, or use scripts/connect which does that for you."
  value = join(" ", [
    "aws ssm start-session",
    "--region ${var.region}",
    "--target <instance-id>",
    "--document-name ${module.session_logging.session_preferences_document_name}",
  ])
}

output "session_log_group" {
  description = "CloudWatch Logs group holding shell session transcripts."
  value       = module.session_logging.cloudwatch_log_group_name
}

output "session_logging_limitations" {
  description = "What is and is not captured. Read this before treating the log group as a complete record of access."
  value       = module.session_logging.session_logging_limitations
}

output "emergency_scale_up_command" {
  description = "Restore access capacity without SSH. Keep this in your incident runbook."
  value       = module.access_node.emergency_scale_up_command
}

output "access_iam_warnings" {
  description = "Configuration contradictions detected in the IAM setup. Empty means none."
  value       = module.access_iam.warnings
}

output "nat_gateway_cost_note" {
  description = "Reminder of this example's dominant cost."
  value       = "This example runs one NAT gateway at roughly $33/month plus data processing. terraform/examples/private-subnets replaces it with VPC endpoints, which is cheaper and removes internet egress entirely."
}

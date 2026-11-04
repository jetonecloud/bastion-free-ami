output "team_role_arns" {
  description = "Role ARN per team. Each is restricted to its own node pool by tag and to its own targets by session document."
  value       = module.access_iam.role_arns
}

output "team_document_arns" {
  description = "The authoritative answer to \"what can each team actually connect to\": the session document ARNs each team's policy permits."
  value       = module.access_iam.team_document_arns
}

output "forward_target_documents" {
  description = "Per-target session documents. The host and port in each are fixed properties, not caller-supplied parameters, which is what makes them an allowlist."
  value       = module.access_iam.forward_target_documents
}

output "connect_commands" {
  description = "Ready-to-run command per forwarding target, with the correct document name for this deployment."
  value       = module.access_iam.connect_commands
}

output "node_pools" {
  description = "Tag filters for each node pool. Pass to scripts/connect --tag."
  value = {
    shared   = module.access_node_shared.node_filter
    payments = module.access_node_payments.node_filter
  }
}

output "session_log_group" {
  description = "CloudWatch Logs group holding shell session transcripts for all teams."
  value       = module.session_logging.cloudwatch_log_group_name
}

output "session_log_bucket" {
  description = "S3 archive of session logs, retained for seven years."
  value       = module.session_logging.s3_bucket_name
}

output "session_logging_limitations" {
  description = "Read before presenting the log group as a complete record. The analytics team only ever port-forwards, so for that team CloudTrail records that a tunnel existed and nothing about what went through it."
  value       = module.session_logging.session_logging_limitations
}

output "iam_limitations" {
  description = "What IAM can and cannot enforce in this setup, as data an audit response can quote."
  value       = module.access_iam.iam_limitations
}

output "access_iam_warnings" {
  description = "Configuration contradictions detected. Empty means none -- which for this example it should be."
  value       = module.access_iam.warnings
}

output "elevation_path" {
  description = "How to get root on an access node, and why it is auditable."
  value = {
    how  = "Assume the platform role (${try(module.access_iam.role_arns["platform"], "n/a")}). It is tagged SSMSessionRunAs=ec2-user, so Session Manager starts its sessions as ec2-user, which retains cloud-init's passwordless sudo. Every other team lands on ssm-user, which the AMI strips of sudo."
    why  = "Elevation is a separate role rather than a sudo rule on the node, so obtaining it is a distinct MFA-gated sts:AssumeRole event in CloudTrail. 'Who had root on the access node, and when' is answerable from the audit trail rather than from a sudoers file nobody reads."
    mfa  = "Requires MFA no older than 15 minutes."
    note = "Session Manager cannot authenticate as root itself; this grants an account that can sudo, which is the closest supported equivalent."
  }
}

output "emergency_scale_up_commands" {
  description = "Restore capacity for either node pool without SSH. Keep these in the incident runbook."
  value = {
    shared   = module.access_node_shared.emergency_scale_up_command
    payments = module.access_node_payments.emergency_scale_up_command
  }
}

output "kms_key_arn" {
  description = "ARN of the KMS key encrypting session data and session logs. Pass to access-node (so the instance role can use it) and access-iam (so callers get kms:GenerateDataKey)."
  value       = local.kms_key_arn
}

output "kms_key_id" {
  description = "Key ID of the session KMS key, or empty when an existing key was supplied."
  value       = var.create_kms_key ? aws_kms_key.session[0].key_id : ""
}

output "kms_alias_name" {
  description = "Alias of the session KMS key, or empty when an existing key was supplied."
  value       = var.create_kms_key ? aws_kms_alias.session[0].name : ""
}

output "cloudwatch_log_group_name" {
  description = "Name of the session log group. Pass to access-node so the instance role may write to it."
  value       = var.enable_cloudwatch_logs ? aws_cloudwatch_log_group.sessions[0].name : ""
}

output "cloudwatch_log_group_arn" {
  description = "ARN of the session log group, for Logs Insights queries and IAM scoping."
  value       = var.enable_cloudwatch_logs ? aws_cloudwatch_log_group.sessions[0].arn : ""
}

output "cloudwatch_retention_days" {
  description = "Retention applied to the session log group. Reported so scripts/verify and an auditor can confirm a retention is actually set."
  value       = var.enable_cloudwatch_logs ? var.cloudwatch_retention_days : 0
}

output "s3_bucket_name" {
  description = "Name of the session log archive bucket, or empty when archiving is off."
  value       = var.enable_s3_archive ? aws_s3_bucket.archive[0].id : ""
}

output "s3_bucket_arn" {
  description = "ARN of the session log archive bucket, or empty when archiving is off."
  value       = var.enable_s3_archive ? aws_s3_bucket.archive[0].arn : ""
}

output "s3_key_prefix" {
  description = "Key prefix under which session logs are archived. Needed to scope the instance role's s3:PutObject and to point Athena at the right path."
  value       = var.enable_s3_archive ? var.s3_key_prefix : ""
}

output "session_preferences_document_name" {
  description = "Name of the session document this module manages, or empty when it manages none. Pass to access-iam as the document teams are allowed to use."
  value       = local.preferences_document_name != null ? local.preferences_document_name : ""
}

output "session_preferences_document_content" {
  description = "The session preferences document content this module would apply, emitted whether or not it manages one. Diff this against your account's existing SSM-SessionManagerRunShell before deciding to adopt it: `aws ssm get-document --name SSM-SessionManagerRunShell --query Content --output text | jq .`"
  value       = jsonencode(local.session_preferences)
}

output "session_logging_limitations" {
  description = "The logging gaps that matter for audit scope, returned as data so a report or a wiki page can quote them rather than restating them from memory."
  value = {
    port_forwarding_not_logged = "Session Manager does not log port-forwarding or SSH session content. AWS: 'Logging isn't available for Session Manager sessions that connect through port forwarding or SSH.' CloudTrail records that the session happened, with principal, target, document, and duration -- not what passed through the tunnel."
    shell_sessions_logged      = var.enable_cloudwatch_logs ? "Shell session keystrokes and output stream to ${local.log_group_name}." : "Shell session logging to CloudWatch Logs is DISABLED for this deployment."
    credentials_in_shell_logs  = "Because shell sessions capture keystrokes, a credential typed at a prompt lands in the log. Use `stty -echo; read VAR; stty echo`."
    datastore_level_visibility = "For statement-level visibility, enable logging at the datastore: RDS audit logs, ElastiCache slow logs, ALB access logs, EKS audit logs. See docs/access-paths.md."
  }
}

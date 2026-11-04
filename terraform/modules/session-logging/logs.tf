# ---------------------------------------------------------------------
# CloudWatch Logs
#
# Shell session I/O lands here. Port-forwarding and SSH sessions do NOT:
# AWS does not log them at all, by design, because Session Manager is
# only a tunnel for that traffic. See the module README.
# ---------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "sessions" {
  count = var.enable_cloudwatch_logs ? 1 : 0

  name = local.log_group_name
  # Validated against the list CloudWatch Logs accepts, with 0 (never
  # expire) deliberately excluded -- see variables.tf.
  retention_in_days = var.cloudwatch_retention_days
  kms_key_id        = local.kms_key_arn

  tags = merge(local.tags, { Name = local.log_group_name })
}

# ---------------------------------------------------------------------
# Alarms
#
# The AMI deliberately does not halt when its audit partition fills
# (docs/design.md): halting the access node removes everyone's route
# into the VPC during the incident that filled the disk. An alarm is
# what replaces that signal, so the trade-off is observed rather than
# merely accepted.
#
# This alarm reads the CloudWatch Agent's disk_used_percent metric,
# which the hardened-al2023 logging role configures. If you build from a
# base that does not ship the agent, this alarm will sit in
# INSUFFICIENT_DATA -- which is itself worth alarming on.
# ---------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "audit_disk" {
  count = var.create_audit_disk_alarm ? 1 : 0

  alarm_name        = "${var.name}-access-node-audit-disk"
  alarm_description = "Access-node disk usage is above ${var.audit_disk_alarm_threshold_percent}%. The access node does not halt on a full audit partition by design (bastion-free-ami); this alarm is the compensating control. Investigate before auditd starts rotating away records."

  namespace           = "CWAgent"
  metric_name         = "disk_used_percent"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.audit_disk_alarm_threshold_percent
  comparison_operator = "GreaterThanThreshold"

  # Missing data means the agent stopped reporting, which on the one
  # host the team relies on for access is a problem in its own right.
  treat_missing_data = "breaching"

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = merge(local.tags, { Name = "${var.name}-access-node-audit-disk" })
}

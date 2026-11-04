output "autoscaling_group_name" {
  description = "Name of the access node ASG."
  value       = aws_autoscaling_group.access_node.name
}

output "autoscaling_group_arn" {
  description = "ARN of the access node ASG."
  value       = aws_autoscaling_group.access_node.arn
}

output "launch_template_id" {
  description = "ID of the access node launch template."
  value       = aws_launch_template.access_node.id
}

output "launch_template_latest_version" {
  description = "Latest version of the launch template. Changes when ami_id changes, which is what triggers an instance refresh."
  value       = aws_launch_template.access_node.latest_version
}

output "security_group_id" {
  description = "ID of the egress-only security group, or empty when existing groups were supplied."
  value       = var.create_security_group ? aws_security_group.access_node[0].id : ""
}

output "iam_role_arn" {
  description = "ARN of the access node instance role."
  value       = aws_iam_role.access_node.arn
}

output "iam_role_name" {
  description = "Name of the access node instance role."
  value       = aws_iam_role.access_node.name
}

output "iam_instance_profile_name" {
  description = "Name of the instance profile. Needed by tests/smoke-test.sh."
  value       = aws_iam_instance_profile.access_node.name
}

output "access_tag_key" {
  description = "Tag key access-iam must match in its ssm:resourceTag condition. Pass this straight into the access-iam module so the two cannot drift apart."
  value       = var.access_tag_key
}

output "access_tag_value" {
  description = "Tag value access-iam must match. Pass this straight into the access-iam module."
  value       = var.access_tag_value
}

output "node_filter" {
  description = "Tag filter for finding a healthy node. scripts/connect and scripts/verify take this as --tag."
  value       = "${var.access_tag_key}=${var.access_tag_value}"
}

#
# Operational commands. These are outputs rather than documentation so
# they are always correct for this deployment: the right ASG name, the
# right region, no placeholders to mistype at 03:00.
#
output "find_node_command" {
  description = "Read-only command listing healthy access nodes registered with Session Manager."
  value = join(" ", [
    "aws ssm describe-instance-information",
    "--region ${local.region}",
    "--filters 'Key=tag:${var.access_tag_key},Values=${var.access_tag_value}'",
    "--query \"InstanceInformationList[?PingStatus=='Online'].InstanceId\"",
    "--output text",
  ])
}

output "emergency_scale_up_command" {
  description = "Restore capacity when the schedule has scaled to zero, or when the ASG is empty. Requires only autoscaling:SetDesiredCapacity -- no SSH, no bastion, no console. Keep this in your incident runbook."
  value = join(" ", [
    "aws autoscaling set-desired-capacity",
    "--region ${local.region}",
    "--auto-scaling-group-name ${aws_autoscaling_group.access_node.name}",
    "--desired-capacity ${max(var.desired_capacity, 1)}",
    "--honor-cooldown",
  ])
}

output "start_instance_refresh_command" {
  description = "Trigger an AMI rollout by hand, if you would rather not wait for the next apply."
  value = join(" ", [
    "aws autoscaling start-instance-refresh",
    "--region ${local.region}",
    "--auto-scaling-group-name ${aws_autoscaling_group.access_node.name}",
    "--preferences 'MinHealthyPercentage=${var.instance_refresh_min_healthy_percentage},InstanceWarmup=${var.instance_warmup_seconds}'",
  ])
}

output "schedule_enabled" {
  description = "Whether the scale-to-zero schedule is active. Surfaced because a deployment that scales access to zero out of hours is something an on-call engineer needs to know about before they are paged."
  value       = var.enable_schedule
}

output "schedule_summary" {
  description = "Human-readable description of the scaling schedule, or a note that there is none."
  value = var.enable_schedule ? format(
    "Scales to %d at '%s' and back to %d at '%s' (%s). Access is unavailable in that window until the scale-up action runs or emergency_scale_up_command is used.",
    var.schedule_scale_down_desired_capacity,
    var.schedule_scale_down_cron,
    var.desired_capacity,
    var.schedule_scale_up_cron,
    var.schedule_time_zone != "" ? var.schedule_time_zone : "UTC",
  ) : "No schedule: capacity is constant at ${var.desired_capacity}."
}

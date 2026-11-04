variable "name" {
  type        = string
  description = "Name prefix for resources created by this module."
  default     = "bfa-access-node"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{1,30}$", var.name))
    error_message = "name must be 2-31 characters of letters, digits, and hyphens, starting with a letter or digit."
  }
}

variable "ami_id" {
  type        = string
  description = "AMI built by packer/, matching instance_type's architecture. Read it from SSM: data.aws_ssm_parameter.this with name /bastion-free-ami/<region>/latest."

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "ami_id must be an AMI ID (ami-...)."
  }
}

variable "instance_type" {
  type        = string
  description = "Instance type. An access node forwards TCP and runs no workload, so the smallest burstable type is usually right. Must match the AMI architecture (t3.* for x86_64, t4g.* for arm64)."
  default     = "t3.small"
}

#
# Network. There is deliberately no associate_public_ip_address variable:
# see network.tf.
#
variable "subnet_ids" {
  type        = list(string)
  description = "PRIVATE subnets to launch access nodes into, ideally one per AZ. Must reach the SSM endpoints through a NAT gateway or the interface endpoints from the vpc-endpoints module. Passing public subnets is not blocked by Terraform but defeats the design."

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "subnet_ids must contain at least one subnet."
  }
}

variable "vpc_id" {
  type        = string
  description = "VPC the access nodes live in. Used to create the egress-only security group."

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must be a VPC ID (vpc-...)."
  }
}

variable "create_security_group" {
  type        = bool
  description = "Create an egress-only security group with no inbound rules. Set false only if you pass security_group_ids you have verified have no inbound rules."
  default     = true
}

variable "security_group_ids" {
  type        = list(string)
  description = "Existing security groups to attach instead of the module's own. These MUST have no inbound rules: Session Manager needs none, and an inbound rule here is exactly what this kit exists to remove."
  default     = []
}

variable "egress_cidr_blocks" {
  type        = list(string)
  description = "Destination CIDRs the access node may reach on TCP 443 (the AWS APIs) and on the ports it forwards to. Defaults to the whole IPv4 space because a node that cannot reach your datastores is useless; narrow it to your VPC CIDR when you are using VPC endpoints and only forwarding inside the VPC."
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for c in var.egress_cidr_blocks : can(cidrnetmask(c))])
    error_message = "egress_cidr_blocks must all be valid IPv4 CIDR blocks."
  }
}

#
# Capacity and self-healing
#
variable "min_size" {
  type        = number
  description = "ASG minimum size. Keep at least 1 unless you use the scale-to-zero schedule: self-healing must not require a human, and a human cannot SSH in to fix this."
  default     = 1

  validation {
    condition     = var.min_size >= 0
    error_message = "min_size must be 0 or greater."
  }
}

variable "max_size" {
  type        = number
  description = "ASG maximum size."
  default     = 2

  validation {
    condition     = var.max_size >= 1
    error_message = "max_size must be at least 1."
  }
}

variable "desired_capacity" {
  type        = number
  description = "ASG desired capacity. Two nodes across AZs is a reasonable default for a team that cannot afford to lose access; one is fine if an AZ outage taking access with it is acceptable."
  default     = 1

  validation {
    condition     = var.desired_capacity >= 0
    error_message = "desired_capacity must be 0 or greater."
  }
}

variable "health_check_grace_period" {
  type        = number
  description = "Seconds after launch before EC2 health checks count. Needs to cover boot plus SSM Agent registration."
  default     = 300
}

variable "root_volume_size_gb" {
  type        = number
  description = "Root volume size. The node stores nothing; this holds the OS and local logs."
  default     = 10

  validation {
    condition     = var.root_volume_size_gb >= 8
    error_message = "root_volume_size_gb must be at least 8 GiB."
  }
}

variable "ebs_kms_key_id" {
  type        = string
  description = "KMS key for root volume encryption. Empty uses the account's default EBS key. Encryption itself is not optional."
  default     = ""
}

variable "enable_detailed_monitoring" {
  type        = bool
  description = "Enable 1-minute EC2 metrics. Costs a little; makes a failing access node visible faster."
  default     = false
}

#
# Instance refresh -- how a new AMI rolls out without anyone logging in
#
variable "enable_instance_refresh" {
  type        = bool
  description = "Roll instances automatically when the launch template changes, which is how an AMI update is deployed. Disable only if you drive refreshes yourself."
  default     = true
}

variable "instance_refresh_min_healthy_percentage" {
  type        = number
  description = "Minimum percentage of the ASG kept in service during a refresh. 100 means a new node is up before an old one goes, so access is never interrupted; it requires max_size > desired_capacity."
  default     = 100

  validation {
    condition     = var.instance_refresh_min_healthy_percentage >= 0 && var.instance_refresh_min_healthy_percentage <= 100
    error_message = "instance_refresh_min_healthy_percentage must be between 0 and 100."
  }
}

variable "instance_warmup_seconds" {
  type        = number
  description = "Seconds a new instance is given to become useful before the refresh continues. Should cover SSM Agent registration, or a refresh can cycle every node before any is reachable."
  default     = 180
}

#
# Optional scale-to-zero schedule
#
variable "enable_schedule" {
  type        = bool
  description = "Scale the ASG down out of hours and back up in the morning. OFF by default: a schedule that scales access to zero is also a schedule that locks you out at 19:00 during an incident. The module outputs the one-line command to scale back up, which needs no SSH."
  default     = false
}

variable "schedule_scale_down_cron" {
  type        = string
  description = "Cron (UTC unless schedule_time_zone is set) for scaling to scale_down_desired_capacity."
  default     = "0 19 * * MON-FRI"
}

variable "schedule_scale_up_cron" {
  type        = string
  description = "Cron (UTC unless schedule_time_zone is set) for scaling back to desired_capacity."
  default     = "0 7 * * MON-FRI"
}

variable "schedule_scale_down_desired_capacity" {
  type        = number
  description = "Capacity during the scaled-down window. 0 means no access at all until the scale-up action or a manual override runs."
  default     = 0

  validation {
    condition     = var.schedule_scale_down_desired_capacity >= 0
    error_message = "schedule_scale_down_desired_capacity must be 0 or greater."
  }
}

variable "schedule_time_zone" {
  type        = string
  description = "IANA time zone for the schedule crons, e.g. Europe/London. Empty means UTC. Set this if you want the window to track local working hours across DST."
  default     = ""
}

#
# Session logging integration -- values come from the session-logging
# module's outputs.
#
variable "session_log_group_name" {
  type        = string
  description = "CloudWatch Logs group for session logs. The instance role is granted write access scoped to this group. Empty omits the grant."
  default     = ""
}

variable "session_log_bucket_arn" {
  type        = string
  description = "ARN of the S3 session log archive bucket. Empty omits the grant."
  default     = ""
}

variable "session_log_bucket_prefix" {
  type        = string
  description = "Key prefix within the archive bucket that the instance role may write to."
  default     = "sessions/"
}

variable "session_kms_key_arn" {
  type        = string
  description = "ARN of the session KMS key. The instance role needs kms:GenerateDataKey and kms:Decrypt on it for KMS-encrypted sessions and logs. Empty omits the grant."
  default     = ""
}

variable "attach_cloudwatch_agent_policy" {
  type        = bool
  description = "Attach the AWS managed CloudWatchAgentServerPolicy so the CloudWatch Agent baked into the AMI can ship OS logs and metrics. Needed for the audit-disk alarm."
  default     = true
}

variable "additional_policy_arns" {
  type        = list(string)
  description = "Extra IAM policy ARNs for the instance role. Keep this empty if you can: every permission here is available to anyone with a session on the node."
  default     = []
}

#
# Tagging. The team tag is what access-iam's IAM conditions match on, so
# it is load-bearing rather than cosmetic.
#
variable "access_tag_key" {
  type        = string
  description = "Tag key that access-iam policies match with the ssm:resourceTag condition to decide who may start a session here. Must agree with the access-iam module's value."
  default     = "BastionFreeAccess"

  validation {
    condition     = can(regex("^[a-zA-Z0-9+=._:@/-]{1,128}$", var.access_tag_key))
    error_message = "access_tag_key must be a valid AWS tag key (1-128 characters)."
  }
}

variable "access_tag_value" {
  type        = string
  description = "Tag value identifying which team(s) may reach these nodes. Use a distinct value per access-node deployment if different teams must not share nodes."
  default     = "shared"

  validation {
    condition     = can(regex("^[a-zA-Z0-9+=._:@/-]{1,256}$", var.access_tag_value))
    error_message = "access_tag_value must be a valid AWS tag value (1-256 characters)."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource this module creates, and propagated to instances."
  default     = {}
}

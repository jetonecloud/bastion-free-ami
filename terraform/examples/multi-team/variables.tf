variable "region" {
  type        = string
  description = "AWS region."
  default     = "us-east-1"
}

variable "name" {
  type        = string
  description = "Name prefix for everything this example creates."
  default     = "bfa-mt"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{0,20}$", var.name))
    error_message = "name must be 1-21 characters of letters, digits, and hyphens (it prefixes IAM role and SSM document names)."
  }
}

variable "environment" {
  type        = string
  description = "Environment tag value."
  default     = "example"
}

variable "vpc_id" {
  type        = string
  description = "Existing VPC to deploy into."

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must be a VPC ID (vpc-...)."
  }
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Existing PRIVATE subnets, ideally one per AZ. Must reach the Systems Manager endpoints via NAT or VPC endpoints."

  validation {
    condition     = length(var.private_subnet_ids) > 0
    error_message = "private_subnet_ids must contain at least one subnet."
  }
}

variable "instance_type" {
  type        = string
  description = "Access node instance type. Must match the AMI architecture."
  default     = "t3.small"
}

#
# Forwarding targets. Each becomes a dedicated Port session document
# with the host and port as fixed properties -- which is the only way
# AWS lets you allowlist a forwarding target per team.
#
variable "payments_db_host" {
  type        = string
  description = "Hostname of the payments database, e.g. payments.cluster-abc.us-east-1.rds.amazonaws.com. Baked into the payments team's session document."
}

variable "analytics_db_host" {
  type        = string
  description = "Hostname of the analytics warehouse. Baked into the analytics team's session document."
}

variable "analytics_cache_host" {
  type        = string
  description = "Primary endpoint of the analytics ElastiCache cluster. Baked into the analytics team's session document."
}

#
# Who may assume each role. Use specific role ARNs: an account root ARN
# means every principal in the account that can call sts:AssumeRole,
# which makes the per-team separation above decorative.
#
variable "payments_principal_arns" {
  type        = list(string)
  description = "Principals allowed to assume the payments access role."

  validation {
    condition     = length(var.payments_principal_arns) > 0
    error_message = "payments_principal_arns must contain at least one principal ARN."
  }
}

variable "analytics_principal_arns" {
  type        = list(string)
  description = "Principals allowed to assume the analytics access role."

  validation {
    condition     = length(var.analytics_principal_arns) > 0
    error_message = "analytics_principal_arns must contain at least one principal ARN."
  }
}

variable "platform_principal_arns" {
  type        = list(string)
  description = "Principals allowed to assume the platform access role. This role is the elevation path (sessions run as ec2-user, which has sudo), so keep it to the smallest group that genuinely needs root on the access node."

  validation {
    condition     = length(var.platform_principal_arns) > 0
    error_message = "platform_principal_arns must contain at least one principal ARN."
  }
}

variable "alarm_sns_topic_arns" {
  type        = list(string)
  description = "SNS topics notified by the audit-disk alarm."
  default     = []
}

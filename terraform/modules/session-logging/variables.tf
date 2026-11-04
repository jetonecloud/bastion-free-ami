variable "name" {
  type        = string
  description = "Name prefix for resources created by this module."
  default     = "bastion-free-ami"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,38}$", var.name))
    error_message = "name must be 2-39 characters of lowercase letters, digits, and hyphens, starting with a letter or digit (it is used in S3 bucket and KMS alias names)."
  }
}

#
# KMS
#
variable "create_kms_key" {
  type        = bool
  description = "Create a customer-managed KMS key for session data, CloudWatch Logs, and the S3 archive. Set false and pass kms_key_arn to reuse an existing key."
  default     = true
}

variable "kms_key_arn" {
  type        = string
  description = "ARN of an existing KMS key to use when create_kms_key is false. Must allow the CloudWatch Logs and (if used) S3 service principals."
  default     = ""

  validation {
    condition     = var.kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN, or empty."
  }
}

variable "kms_deletion_window_days" {
  type        = number
  description = "Waiting period before a scheduled KMS key deletion completes. Session logs encrypted with a deleted key become permanently unreadable, so the default is the maximum."
  default     = 30

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be between 7 and 30."
  }
}

variable "kms_enable_key_rotation" {
  type        = bool
  description = "Enable annual automatic rotation of the KMS key material. Previously encrypted logs stay readable."
  default     = true
}

#
# CloudWatch Logs
#
variable "enable_cloudwatch_logs" {
  type        = bool
  description = "Stream shell session I/O to CloudWatch Logs. NOTE: port forwarding and SSH sessions are never logged by AWS regardless of this setting -- see the module README."
  default     = true
}

variable "cloudwatch_log_group_name" {
  type        = string
  description = "Log group for session data. Defaults to /aws/ssm/<name>/sessions."
  default     = ""
}

variable "cloudwatch_retention_days" {
  type        = number
  description = "Retention for the session log group. A defined retention is required: 0 (never expire) is rejected, because an unbounded audit log is both a cost and a liability."
  default     = 365

  validation {
    # The values CloudWatch Logs accepts, minus 0 (never expire).
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.cloudwatch_retention_days
    )
    error_message = "cloudwatch_retention_days must be one of the retention values CloudWatch Logs supports (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653). 0 (never expire) is deliberately not allowed."
  }
}

variable "cloudwatch_streaming_enabled" {
  type        = bool
  description = "Stream session output continuously rather than uploading it once at session end. Continuous streaming means a session that is killed mid-way still leaves a log."
  default     = true
}

#
# S3 archive
#
variable "enable_s3_archive" {
  type        = bool
  description = "Also archive session logs to S3. Useful for retention beyond what CloudWatch Logs is economical for, and for Athena queries."
  default     = false
}

variable "s3_bucket_name" {
  type        = string
  description = "Name for the archive bucket. Defaults to <name>-session-logs-<account-id> to avoid collisions in the global namespace."
  default     = ""
}

variable "s3_key_prefix" {
  type        = string
  description = "Key prefix for archived session logs."
  default     = "sessions/"
}

variable "s3_archive_retention_days" {
  type        = number
  description = "Days before archived session logs expire. Set 0 to keep them indefinitely (an explicit choice, unlike the CloudWatch retention where 0 is rejected, because S3 lifecycle has no 'never expire' sentinel to confuse it with)."
  default     = 730

  validation {
    condition     = var.s3_archive_retention_days >= 0
    error_message = "s3_archive_retention_days must be 0 or greater."
  }
}

variable "s3_transition_to_glacier_days" {
  type        = number
  description = "Days before archived logs move to Glacier Instant Retrieval. Set 0 to disable the transition."
  default     = 90

  validation {
    condition     = var.s3_transition_to_glacier_days == 0 || var.s3_transition_to_glacier_days >= 1
    error_message = "s3_transition_to_glacier_days must be 0 (disabled) or at least 1."
  }
}

#
# Session preferences -- read the warnings. These settings are
# account-and-region GLOBAL, not per-ASG and not per-team.
#
variable "manage_session_preferences" {
  type        = bool
  description = "Manage the account-wide SSM-SessionManagerRunShell document. Defaults to false because this document is shared by every Session Manager user in the account and region, usually already exists, and overwriting it changes behaviour for teams that have nothing to do with this kit. Prefer custom_preferences_document_name. See the module README for the import procedure."
  default     = false
}

variable "i_understand_preferences_are_account_wide" {
  type        = bool
  description = "Second key required to set manage_session_preferences = true. Exists so that adopting an account-global setting is a deliberate act rather than a default that surprises someone."
  default     = false
}

variable "custom_preferences_document_name" {
  type        = string
  description = "Create a separately named Standard_Stream session document instead of touching the account default. Preferences then apply only to sessions started through this kit, and access-iam grants teams this document. This is the recommended path for shared accounts. Mutually exclusive with manage_session_preferences."
  default     = ""

  validation {
    condition     = var.custom_preferences_document_name == "" || can(regex("^[a-zA-Z0-9_.-]{3,128}$", var.custom_preferences_document_name))
    error_message = "custom_preferences_document_name must be 3-128 characters of letters, digits, underscore, period, or hyphen."
  }
}

variable "idle_session_timeout_minutes" {
  type        = number
  description = "Minutes of inactivity before a session is ended. AWS allows 1-60."
  default     = 20

  validation {
    condition     = var.idle_session_timeout_minutes >= 1 && var.idle_session_timeout_minutes <= 60
    error_message = "idle_session_timeout_minutes must be between 1 and 60 (the range the Session document schema accepts)."
  }
}

variable "max_session_duration_minutes" {
  type        = number
  description = "Maximum session length regardless of activity. AWS allows 1-1440. Note this also caps port-forwarding sessions, so set it longer than your longest legitimate tunnel."
  default     = 240

  validation {
    condition     = var.max_session_duration_minutes >= 1 && var.max_session_duration_minutes <= 1440
    error_message = "max_session_duration_minutes must be between 1 and 1440 (the range the Session document schema accepts)."
  }
}

variable "run_as_enabled" {
  type        = bool
  description = "Authenticate sessions as a named OS user rather than ssm-user. Session Manager never permits root. Leave false to use ssm-user, which the AMI strips of sudo."
  default     = false
}

variable "run_as_default_user" {
  type        = string
  description = "OS user for sessions when run_as_enabled is true. Must exist on the node or sessions fail to start with no fallback. An IAM entity tagged SSMSessionRunAs overrides this per-principal."
  default     = ""

  validation {
    condition     = var.run_as_default_user != "root"
    error_message = "run_as_default_user cannot be root: Session Manager does not support authenticating sessions as root, and sessions on an access node must not be privileged."
  }
}

variable "shell_profile_linux" {
  type        = string
  description = "Commands run at the start of each Linux session. Defaults to printing the AMI's session banner, which warns the user that keystrokes are logged before they type a credential."
  default     = "cat /etc/bastion-free-ami/session-banner 2>/dev/null || true"
}

#
# Alarms
#
variable "create_audit_disk_alarm" {
  type        = bool
  description = "Create a CloudWatch alarm on access-node disk usage. The AMI deliberately does not halt on a full audit partition (see docs/design.md), so an alarm is what replaces that signal."
  default     = false
}

variable "audit_disk_alarm_threshold_percent" {
  type        = number
  description = "Disk-used percentage that triggers the audit disk alarm."
  default     = 80

  validation {
    condition     = var.audit_disk_alarm_threshold_percent > 0 && var.audit_disk_alarm_threshold_percent < 100
    error_message = "audit_disk_alarm_threshold_percent must be between 1 and 99."
  }
}

variable "alarm_sns_topic_arns" {
  type        = list(string)
  description = "SNS topics notified by the alarms this module creates."
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource this module creates."
  default     = {}
}

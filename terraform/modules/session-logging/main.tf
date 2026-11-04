data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  # `.region`, not `.name`: the name attribute is deprecated as of AWS
  # provider 6.0.
  region    = data.aws_region.current.region
  partition = data.aws_partition.current.partition

  log_group_name = (
    var.cloudwatch_log_group_name != ""
    ? var.cloudwatch_log_group_name
    : "/aws/ssm/${var.name}/sessions"
  )

  bucket_name = (
    var.s3_bucket_name != ""
    ? var.s3_bucket_name
    : "${var.name}-session-logs-${local.account_id}"
  )

  kms_key_arn = var.create_kms_key ? aws_kms_key.session[0].arn : var.kms_key_arn

  # Which session document (if any) this module manages. The two paths
  # are mutually exclusive, enforced by a precondition below.
  manage_account_default = var.manage_session_preferences && var.custom_preferences_document_name == ""
  manage_custom_document = var.custom_preferences_document_name != ""

  preferences_document_name = (
    local.manage_custom_document
    ? var.custom_preferences_document_name
    : (local.manage_account_default ? "SSM-SessionManagerRunShell" : null)
  )

  # The exact content this module would apply. Emitted as an output even
  # when nothing is managed, so you can diff it against the document your
  # account already has before deciding to adopt it.
  session_preferences = {
    schemaVersion = "1.0"
    description   = "Session Manager preferences managed by bastion-free-ami (${var.name})"
    sessionType   = "Standard_Stream"
    inputs = {
      s3BucketName                = var.enable_s3_archive ? local.bucket_name : ""
      s3KeyPrefix                 = var.enable_s3_archive ? var.s3_key_prefix : ""
      s3EncryptionEnabled         = var.enable_s3_archive
      cloudWatchLogGroupName      = var.enable_cloudwatch_logs ? local.log_group_name : ""
      cloudWatchEncryptionEnabled = var.enable_cloudwatch_logs
      cloudWatchStreamingEnabled  = var.cloudwatch_streaming_enabled
      kmsKeyId                    = local.kms_key_arn
      runAsEnabled                = var.run_as_enabled
      runAsDefaultUser            = var.run_as_default_user
      idleSessionTimeout          = tostring(var.idle_session_timeout_minutes)
      maxSessionDuration          = tostring(var.max_session_duration_minutes)
      shellProfile = {
        windows = ""
        linux   = var.shell_profile_linux
      }
    }
  }

  tags = merge(
    {
      Project   = "bastion-free-ami"
      Module    = "session-logging"
      ManagedBy = "terraform"
    },
    var.tags
  )
}

# ---------------------------------------------------------------------
# Guard rails.
#
# These are preconditions rather than variable validations because each
# one spans several variables. `terraform_data` is a built-in resource
# (no provider required, supported by both Terraform and OpenTofu); it
# is used here purely as a place to hang checks that must fail a plan.
# It is NOT counted to zero: preconditions on a resource with count = 0
# are never evaluated, which would make every check below silently
# vacuous.
# ---------------------------------------------------------------------
resource "terraform_data" "preconditions" {
  input = var.name

  lifecycle {
    precondition {
      condition     = !(var.manage_session_preferences && var.custom_preferences_document_name != "")
      error_message = "manage_session_preferences and custom_preferences_document_name are mutually exclusive: choose either the account-wide default document or a separately named one."
    }

    precondition {
      condition     = !var.manage_session_preferences || var.i_understand_preferences_are_account_wide
      error_message = "manage_session_preferences = true also requires i_understand_preferences_are_account_wide = true. SSM-SessionManagerRunShell is shared by every Session Manager user in this account and region; changing it affects teams unrelated to this kit, and it usually already exists. See the module README for how to import it, or set custom_preferences_document_name instead."
    }

    precondition {
      condition     = var.create_kms_key || var.kms_key_arn != ""
      error_message = "Set create_kms_key = true, or pass kms_key_arn. Session logs are encrypted either way."
    }

    precondition {
      condition     = !var.run_as_enabled || var.run_as_default_user != ""
      error_message = "run_as_enabled = true requires run_as_default_user. AWS documents that turning on Run As without specifying a user makes every session fail to start, with no fallback to ssm-user."
    }

    precondition {
      condition     = var.enable_cloudwatch_logs || var.enable_s3_archive
      error_message = "At least one of enable_cloudwatch_logs or enable_s3_archive must be true. Shipping an access kit with no session record defeats the point; if you really intend that, set enable_cloudwatch_logs = true and cloudwatch_retention_days = 1."
    }
  }
}

# ---------------------------------------------------------------------
# KMS
# ---------------------------------------------------------------------
resource "aws_kms_key" "session" {
  count = var.create_kms_key ? 1 : 0

  description             = "bastion-free-ami (${var.name}): Session Manager session data and session log encryption"
  deletion_window_in_days = var.kms_deletion_window_days
  enable_key_rotation     = var.kms_enable_key_rotation
  policy                  = data.aws_iam_policy_document.kms[0].json

  tags = merge(local.tags, { Name = "${var.name}-session" })
}

resource "aws_kms_alias" "session" {
  count = var.create_kms_key ? 1 : 0

  name          = "alias/${var.name}-session"
  target_key_id = aws_kms_key.session[0].key_id
}

data "aws_iam_policy_document" "kms" {
  count = var.create_kms_key ? 1 : 0

  # Resource "*" in every statement below is unavoidable and is not a
  # wildcard in the usual sense: a KMS key policy is attached to exactly
  # one key, and "*" within it means "this key". A key policy cannot
  # name its own ARN, because the ARN does not exist until the key is
  # created. Scoping is therefore done with conditions, not resources.
  statement {
    sid       = "EnableIAMPoliciesForAccount"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    # Without this, the key is unmanageable: IAM cannot grant access to
    # a key whose own policy does not delegate to the account. This is
    # the AWS default key policy statement.
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_cloudwatch_logs ? [1] : []

    content {
      sid    = "AllowCloudWatchLogs"
      effect = "Allow"

      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncryptFrom",
        "kms:ReEncryptTo",
        "kms:GenerateDataKey",
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:DescribeKey",
      ]
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = ["logs.${local.region}.amazonaws.com"]
      }

      # Restricts the service principal to encrypting log groups in this
      # account and region, so the key cannot be used against another
      # account's logs.
      condition {
        test     = "ArnLike"
        variable = "kms:EncryptionContext:aws:logs:arn"
        values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
      }
    }
  }

  # Session Manager requests a data key to encrypt the session stream
  # between the client and the managed node.
  statement {
    sid    = "AllowSessionManagerService"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  # No statement for s3.amazonaws.com. Objects are written to the
  # archive by SSM Agent on the access node using the instance role, and
  # S3 calls KMS on that caller's behalf, so the caller's own
  # kms:GenerateDataKey/kms:Decrypt grant (attached by
  # terraform/modules/access-node) is what applies. The account-root
  # statement above is what lets IAM make that grant effective.
}

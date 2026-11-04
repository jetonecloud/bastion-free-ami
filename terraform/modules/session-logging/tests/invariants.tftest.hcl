# Tests for session-logging. Run with:
#
#   cd terraform/modules/session-logging && terraform test

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
}

variables {
  name = "bfa-test"
}

# ---------------------------------------------------------------------
# Logging defaults
# ---------------------------------------------------------------------
run "log_group_is_encrypted_and_retained" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.sessions[0].retention_in_days == 365
    error_message = "The session log group must have a defined retention."
  }

  assert {
    condition     = aws_cloudwatch_log_group.sessions[0].kms_key_id != null
    error_message = "The session log group must be KMS-encrypted; it contains session transcripts."
  }
}

run "rejects_never_expire_retention" {
  command = plan

  # 0 means "never expire" in CloudWatch Logs. Rejected deliberately:
  # an unbounded audit log is both a cost and a liability.
  variables {
    cloudwatch_retention_days = 0
  }

  expect_failures = [
    var.cloudwatch_retention_days,
  ]
}

run "rejects_invalid_retention_value" {
  command = plan

  variables {
    cloudwatch_retention_days = 42
  }

  expect_failures = [
    var.cloudwatch_retention_days,
  ]
}

run "kms_key_rotates_and_has_max_deletion_window" {
  command = plan

  assert {
    condition     = aws_kms_key.session[0].enable_key_rotation == true
    error_message = "Key rotation should be on by default."
  }

  assert {
    condition     = aws_kms_key.session[0].deletion_window_in_days == 30
    error_message = "The deletion window should default to the 30-day maximum: logs encrypted with a deleted key are permanently unreadable."
  }
}

# ---------------------------------------------------------------------
# The account-wide preferences guard rail
# ---------------------------------------------------------------------
run "manages_no_session_document_by_default" {
  command = plan

  assert {
    condition     = length(aws_ssm_document.preferences) == 0
    error_message = "By default this module must not manage any session document. SSM-SessionManagerRunShell is account-and-region global and usually already exists."
  }

  assert {
    condition     = output.session_preferences_document_name == ""
    error_message = "With nothing managed, the document name output should be empty."
  }

  assert {
    condition     = output.session_preferences_document_content != ""
    error_message = "The module must still emit the content it WOULD apply, so an operator can diff it against the account's existing document before adopting it."
  }
}

run "refuses_account_wide_document_without_second_key" {
  command = plan

  variables {
    manage_session_preferences = true
    # i_understand_preferences_are_account_wide deliberately left false
  }

  expect_failures = [
    terraform_data.preconditions,
  ]
}

run "accepts_account_wide_document_with_both_keys" {
  command = plan

  variables {
    manage_session_preferences                = true
    i_understand_preferences_are_account_wide = true
  }

  assert {
    condition     = aws_ssm_document.preferences[0].name == "SSM-SessionManagerRunShell"
    error_message = "With both keys set, the module should manage the account default document."
  }
}

run "custom_document_needs_no_acknowledgement" {
  command = plan

  # The recommended path: a separately named document leaves the account
  # default untouched, so it needs no second key.
  variables {
    custom_preferences_document_name = "bfa-SessionManagerRunShell"
  }

  assert {
    condition     = aws_ssm_document.preferences[0].name == "bfa-SessionManagerRunShell"
    error_message = "A custom document name should be used as-is."
  }

  assert {
    condition     = aws_ssm_document.preferences[0].document_type == "Session"
    error_message = "Session preferences documents must be of type Session."
  }
}

run "rejects_both_document_paths_at_once" {
  command = plan

  variables {
    manage_session_preferences                = true
    i_understand_preferences_are_account_wide = true
    custom_preferences_document_name          = "bfa-SessionManagerRunShell"
  }

  expect_failures = [
    terraform_data.preconditions,
  ]
}

# ---------------------------------------------------------------------
# Run As
# ---------------------------------------------------------------------
run "rejects_root_as_run_as_user" {
  command = plan

  variables {
    run_as_enabled      = true
    run_as_default_user = "root"
  }

  expect_failures = [
    var.run_as_default_user,
  ]
}

run "rejects_run_as_without_a_user" {
  command = plan

  # AWS documents that enabling Run As without a user makes every
  # session fail to start, with no fallback to ssm-user.
  variables {
    run_as_enabled = true
  }

  expect_failures = [
    terraform_data.preconditions,
  ]
}

# ---------------------------------------------------------------------
# Session document content
# ---------------------------------------------------------------------
run "timeouts_are_within_aws_limits" {
  command = plan

  variables {
    idle_session_timeout_minutes = 61
  }

  expect_failures = [
    var.idle_session_timeout_minutes,
  ]
}

run "max_duration_is_within_aws_limits" {
  command = plan

  variables {
    max_session_duration_minutes = 1441
  }

  expect_failures = [
    var.max_session_duration_minutes,
  ]
}

run "refuses_to_disable_all_logging" {
  command = plan

  variables {
    enable_cloudwatch_logs = false
    enable_s3_archive      = false
  }

  expect_failures = [
    terraform_data.preconditions,
  ]
}

# ---------------------------------------------------------------------
# S3 archive controls
# ---------------------------------------------------------------------
run "s3_archive_blocks_public_access_and_encrypts" {
  command = plan

  variables {
    enable_s3_archive = true
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.archive[0].block_public_acls &&
      aws_s3_bucket_public_access_block.archive[0].block_public_policy &&
      aws_s3_bucket_public_access_block.archive[0].ignore_public_acls &&
      aws_s3_bucket_public_access_block.archive[0].restrict_public_buckets
    )
    error_message = "All four public access block settings must be on for a bucket holding session transcripts."
  }

  assert {
    condition     = aws_s3_bucket_server_side_encryption_configuration.archive[0].rule[0].apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms"
    error_message = "The session log archive must use SSE-KMS."
  }

  assert {
    condition     = aws_s3_bucket_versioning.archive[0].versioning_configuration[0].status == "Enabled"
    error_message = "Versioning must be on: an audit archive where an object can be silently replaced is not an audit archive."
  }

  assert {
    condition     = aws_s3_bucket_ownership_controls.archive[0].rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs must be disabled so access is governed by policy alone."
  }
}

run "logging_limitations_are_reported" {
  command = plan

  # The port-forwarding logging gap is the single most commonly missed
  # fact about this architecture, so the module reports it as data
  # rather than relying on someone reading a document.
  assert {
    condition     = strcontains(output.session_logging_limitations["port_forwarding_not_logged"], "port forwarding")
    error_message = "The module must report that port-forwarding session content is not logged."
  }
}

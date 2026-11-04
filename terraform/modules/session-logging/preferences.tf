# ---------------------------------------------------------------------
# Session Manager preferences.
#
# READ THIS BEFORE SETTING manage_session_preferences = true.
#
# Session Manager's logging, idle timeout, maximum duration, Run As, and
# KMS settings live in ONE SSM document per account per region, named
# SSM-SessionManagerRunShell. It is not per-team, not per-ASG, and not
# per-VPC. In most accounts it ALREADY EXISTS, because somebody opened
# the Session Manager console and clicked Preferences once.
#
# So this module offers three postures, and the default is the cautious
# one:
#
#   1. manage nothing (default). The module still emits the document
#      content it would apply, as the session_preferences_document_content
#      output, so you can diff it against what you have.
#
#   2. custom_preferences_document_name = "bfa-SessionManagerRunShell".
#      RECOMMENDED for shared accounts. Creates a separately named
#      Standard_Stream document. Preferences apply only to sessions
#      started through this kit; the account default is untouched.
#      access-iam grants teams this document instead.
#
#   3. manage_session_preferences = true, plus the second key
#      i_understand_preferences_are_account_wide = true. Takes ownership
#      of the account default. Only do this if you know no other team
#      depends on it.
#
# If you choose (3) and the document already exists, Terraform will fail
# with DocumentAlreadyExists rather than clobber it. Import it first:
#
#   terraform import \
#     'module.session_logging.aws_ssm_document.preferences[0]' \
#     SSM-SessionManagerRunShell
#
# then run `terraform plan` and READ THE DIFF before applying. The plan
# will show you exactly which account-wide settings you are about to
# change. This module will never overwrite that document without you
# having seen that diff.
# ---------------------------------------------------------------------
resource "aws_ssm_document" "preferences" {
  count = local.preferences_document_name != null ? 1 : 0

  name            = local.preferences_document_name
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode(local.session_preferences)

  tags = merge(local.tags, { Name = local.preferences_document_name })

  lifecycle {
    precondition {
      condition = (
        local.manage_custom_document ||
        (var.manage_session_preferences && var.i_understand_preferences_are_account_wide)
      )
      error_message = "Refusing to manage SSM-SessionManagerRunShell without i_understand_preferences_are_account_wide = true."
    }
  }
}

# session-logging

KMS key, CloudWatch Logs group, optional S3 archive, retention, and
Session Manager preferences for a bastion-free deployment.

## Read this before you use `manage_session_preferences`

Session Manager's logging, idle timeout, maximum duration, Run As, and
KMS settings live in **one SSM document per account per region**, named
`SSM-SessionManagerRunShell`. It is not per-team, not per-ASG, not
per-VPC. **In most accounts it already exists**, because somebody opened
the Session Manager console and clicked Preferences once.

A module that unconditionally declared that document would either fail
with `DocumentAlreadyExists` or — worse, after a careless import —
silently replace an account-wide setting other teams depend on. So this
module offers three postures.

### 1. Manage nothing (the default)

The module creates the KMS key, log group, and archive, and emits the
preferences document content it *would* apply as an output. Nothing
account-wide is touched.

```sh
terraform output -raw session_preferences_document_content | jq .

# Compare against what your account actually has:
aws ssm get-document --name SSM-SessionManagerRunShell \
  --query Content --output text | jq .
```

Sessions use whatever the account default already says — which may mean
no logging. Check.

### 2. A separately named document (recommended)

```hcl
custom_preferences_document_name = "bfa-SessionManagerRunShell"
```

Creates a `Standard_Stream` document under your own name. Preferences
apply only to sessions started through this kit; the account default is
untouched. `access-iam` grants teams this document via
`session_document_name`.

This is the right answer for any shared account, and it is what
`terraform/examples/multi-team` uses.

### 3. Take over the account default

```hcl
manage_session_preferences                = true
i_understand_preferences_are_account_wide = true
```

Both keys are required — adopting an account-global setting should be
deliberate, not a default somebody inherited.

**If the document already exists**, Terraform fails with
`DocumentAlreadyExists` rather than clobbering it. Import it first:

```sh
terraform import \
  'module.session_logging.aws_ssm_document.preferences[0]' \
  SSM-SessionManagerRunShell

terraform plan   # READ THIS DIFF
```

The plan shows exactly which account-wide settings you are about to
change. This module will never overwrite that document without you
having seen that diff.

## What is not in the logs

> Logging isn't available for Session Manager sessions that connect
> through port forwarding or SSH.
> — AWS Systems Manager User Guide

So the log group contains **shell sessions only**. For RDS,
ElastiCache, internal HTTP, and the EKS API — all of which use port
forwarding — CloudTrail records that the session happened, with
principal, target, document, and duration. Not what passed through it.

`terraform output session_logging_limitations` returns this as data, so
a report or wiki page can quote it rather than restating it from
memory. `docs/audit-evidence.md` has the wording to use with an
auditor.

The converse also matters: shell sessions log **keystrokes**, so a
credential typed at a prompt lands in the log group. Treat it as a
secret-bearing store.

## Usage

```hcl
module "session_logging" {
  source = "./terraform/modules/session-logging"

  name = "bfa"

  enable_cloudwatch_logs    = true
  cloudwatch_retention_days = 365

  enable_s3_archive         = true
  s3_archive_retention_days = 730

  custom_preferences_document_name = "bfa-SessionManagerRunShell"

  idle_session_timeout_minutes = 20
  max_session_duration_minutes = 240

  create_audit_disk_alarm = true
  alarm_sns_topic_arns    = [aws_sns_topic.alerts.arn]
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | `"bastion-free-ami"` | Name prefix. Used in S3 bucket and KMS alias names. |
| `create_kms_key` | bool | `true` | Create a CMK for session data and logs. |
| `kms_key_arn` | string | `""` | Existing key to use when `create_kms_key = false`. |
| `kms_deletion_window_days` | number | `30` | Deletion waiting period. Defaults to the maximum: logs encrypted with a deleted key are permanently unreadable. |
| `kms_enable_key_rotation` | bool | `true` | Annual key rotation. |
| `enable_cloudwatch_logs` | bool | `true` | Stream shell session I/O to CloudWatch Logs. |
| `cloudwatch_log_group_name` | string | `""` | Defaults to `/aws/ssm/<name>/sessions`. |
| `cloudwatch_retention_days` | number | `365` | Retention. **0 (never expire) is rejected.** |
| `cloudwatch_streaming_enabled` | bool | `true` | Stream continuously rather than uploading at session end. |
| `enable_s3_archive` | bool | `false` | Archive session logs to S3. |
| `s3_bucket_name` | string | `""` | Defaults to `<name>-session-logs-<account-id>`. |
| `s3_key_prefix` | string | `"sessions/"` | Archive key prefix. |
| `s3_archive_retention_days` | number | `730` | Expiry. 0 keeps indefinitely. |
| `s3_transition_to_glacier_days` | number | `90` | Glacier IR transition. 0 disables. |
| `manage_session_preferences` | bool | `false` | Manage the account-wide document. Read the warning above. |
| `i_understand_preferences_are_account_wide` | bool | `false` | Second key required by the above. |
| `custom_preferences_document_name` | string | `""` | Create a separately named document instead. Recommended. |
| `idle_session_timeout_minutes` | number | `20` | 1–60. |
| `max_session_duration_minutes` | number | `240` | 1–1440. Also caps port-forwarding sessions. |
| `run_as_enabled` | bool | `false` | Authenticate as a named OS user rather than `ssm-user`. |
| `run_as_default_user` | string | `""` | Required when the above is true. Cannot be `root`. |
| `shell_profile_linux` | string | prints the session banner | Commands run at session start. |
| `create_audit_disk_alarm` | bool | `false` | Alarm on access node disk pressure. |
| `audit_disk_alarm_threshold_percent` | number | `80` | Alarm threshold. |
| `alarm_sns_topic_arns` | list(string) | `[]` | Topics to notify. |
| `tags` | map(string) | `{}` | Tags for all resources. |

## Outputs

| Name | Description |
|---|---|
| `kms_key_arn` | Session KMS key ARN. Pass to `access-node` and `access-iam`. |
| `kms_key_id` | Key ID, or empty when an existing key was supplied. |
| `kms_alias_name` | Key alias, or empty. |
| `cloudwatch_log_group_name` | Session log group name. Pass to `access-node`. |
| `cloudwatch_log_group_arn` | Log group ARN. |
| `cloudwatch_retention_days` | Retention actually applied. |
| `s3_bucket_name` | Archive bucket, or empty. |
| `s3_bucket_arn` | Archive bucket ARN, or empty. |
| `s3_key_prefix` | Archive key prefix. |
| `session_preferences_document_name` | Document this module manages, or empty. Pass to `access-iam`. |
| `session_preferences_document_content` | The content it would apply. Diff before adopting. |
| `session_logging_limitations` | The logging gaps, as structured data. |

## Preconditions

The module fails the plan, with an explanation, when:

- `manage_session_preferences` is set without the acknowledgement key
- both document paths are configured at once
- `run_as_enabled` is set with no user (AWS: every session then fails
  to start, with no fallback)
- neither CloudWatch Logs nor the S3 archive is enabled
- `create_kms_key = false` with no `kms_key_arn`

## Notes on the controls

- **The S3 bucket's protections are not variables.** Public access
  blocked on all four dimensions, SSE-KMS, versioning, ACLs disabled,
  and deny statements for plaintext transport and the wrong KMS key. A
  bucket of session transcripts is one of the more sensitive objects in
  an account.
- **Session log writes come from the instance role**, not from the
  `ssm.amazonaws.com` service principal, so there is no bucket-policy
  Allow for a service. `access-node` attaches the scoped grant.
- **`cloudwatch_retention_days = 0` is rejected** deliberately. An
  unbounded audit log is both a cost and a liability.

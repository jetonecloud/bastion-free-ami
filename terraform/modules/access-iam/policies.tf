# ---------------------------------------------------------------------
# Per-team session policy.
#
# Four things make this least-privilege rather than merely scoped:
#
#   1. StartSession on instances is conditioned on ssm:resourceTag, so a
#      team reaches only its own access nodes.
#   2. StartSession on documents lists only the documents that team may
#      use, with ssm:SessionDocumentAccessCheck forcing IAM to evaluate
#      document access. Without that condition, granting the shell
#      document can effectively permit others.
#   3. TerminateSession and ResumeSession are scoped to
#      session/${aws:userid}-*, so a user can only end their own
#      session. aws:userid is used rather than aws:username because AWS
#      documents the latter as not working for federated principals.
#   4. ssmmessages:OpenDataChannel is scoped the same way, so a caller
#      cannot attach to somebody else's data channel.
# ---------------------------------------------------------------------
data "aws_iam_policy_document" "team" {
  for_each = var.teams

  # --- which nodes -------------------------------------------------
  statement {
    sid    = "StartSessionOnTaggedNodes"
    effect = "Allow"

    actions = ["ssm:StartSession"]

    # instance/* is scoped by the tag condition below, not by ARN:
    # access nodes come from an ASG, so their instance IDs are not known
    # at apply time and change on every replacement. The tag is the
    # stable identity, which is why access-node treats it as
    # load-bearing.
    resources = ["arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/${var.access_tag_key}"
      values   = [each.value.access_tag_value]
    }
  }

  # --- which documents ---------------------------------------------
  statement {
    sid    = "StartSessionWithPermittedDocuments"
    effect = "Allow"

    actions   = ["ssm:StartSession"]
    resources = local.team_document_arns[each.key]

    # Forces the caller to name a document and forces IAM to check
    # access to it. This is what turns the document list above into an
    # actual allowlist.
    dynamic "condition" {
      for_each = var.enforce_session_document_access_check ? [1] : []

      content {
        test     = "Bool"
        variable = "ssm:SessionDocumentAccessCheck"
        values   = ["true"]
      }
    }
  }

  # --- own sessions only -------------------------------------------
  statement {
    sid    = "ManageOwnSessionsOnly"
    effect = "Allow"

    actions = [
      "ssm:TerminateSession",
      "ssm:ResumeSession",
    ]

    # ${aws:userid} expands to the caller's unique ID, so this ARN
    # pattern matches only sessions that caller started. Session IDs are
    # generated as "<userid>-<random>", which is why the trailing -*.
    resources = ["arn:${local.partition}:ssm:*:*:session/$${aws:userid}-*"]
  }

  statement {
    sid    = "OpenOwnDataChannel"
    effect = "Allow"

    actions   = ["ssmmessages:OpenDataChannel"]
    resources = ["arn:${local.partition}:ssm:*:*:session/$${aws:userid}-*"]
  }

  # --- discovery ----------------------------------------------------
  # Needed to find a healthy node before connecting to it. Read-only.
  statement {
    sid    = "DiscoverNodes"
    effect = "Allow"

    actions = [
      "ssm:DescribeInstanceInformation",
      "ssm:GetConnectionStatus",
      "ec2:DescribeInstances",
    ]

    # Resource "*" is unavoidable: all three are list/describe
    # operations that enumerate across the account and accept no
    # resource ARN. ssm:DescribeInstanceInformation in particular has no
    # resource-level permission support at all. They are read-only and
    # expose instance metadata, not data or credentials. The tag
    # condition on StartSession above is what limits what a caller can
    # actually connect to.
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.allow_describe_sessions ? [1] : []

    content {
      sid       = "DescribeSessions"
      effect    = "Allow"
      actions   = ["ssm:DescribeSessions"]
      resources = ["*"]

      # Also unavoidable, and worth knowing about: DescribeSessions
      # cannot be restricted to a caller's own sessions. It is a list
      # operation with no condition key for the session owner, so a
      # caller sees other users' session IDs and target instances. They
      # still cannot join or end them -- that is what the
      # ${aws:userid} scoping above prevents. Set
      # allow_describe_sessions = false if even the listing is too much;
      # the Session Manager console will stop working.
    }
  }

  # --- document introspection ---------------------------------------
  # The console needs these to offer a document picker. Scoped to the
  # documents this team may actually use.
  dynamic "statement" {
    for_each = length(local.team_document_arns[each.key]) > 0 ? [1] : []

    content {
      sid       = "ReadPermittedDocuments"
      effect    = "Allow"
      actions   = ["ssm:GetDocument"]
      resources = local.team_document_arns[each.key]
    }
  }

  # --- session encryption -------------------------------------------
  dynamic "statement" {
    for_each = var.session_kms_key_arn != "" ? [1] : []

    content {
      sid    = "GenerateSessionDataKey"
      effect = "Allow"

      # Session Manager asks the CALLER for a data key when session
      # data is KMS-encrypted. Without this, a KMS-encrypted session
      # fails to start with an opaque error.
      actions   = ["kms:GenerateDataKey"]
      resources = [var.session_kms_key_arn]
    }
  }

  # --- explicit denies ----------------------------------------------
  # Defence against a future broad grant elsewhere in the account. An
  # explicit Deny cannot be overridden by any Allow, so these hold even
  # if someone later attaches PowerUserAccess to the same principal.
  statement {
    sid    = "DenyEscapeHatches"
    effect = "Deny"

    actions = [
      # Would let a caller define a document running arbitrary commands
      # as root, bypassing every restriction above.
      "ssm:CreateDocument",
      "ssm:UpdateDocument",
      "ssm:DeleteDocument",
      "ssm:ModifyDocumentPermission",
      # Run Command is root on the node and is not session-logged.
      "ssm:SendCommand",
      "ssm:StartAutomationExecution",
      # Would let a caller rewrite the account's session preferences,
      # turning off logging for everyone.
      "ssm:UpdateServiceSetting",
      "ssm:ResetServiceSetting",
    ]
    resources = ["*"]
  }

  # The allowlist's teeth.
  #
  # Granting only the per-target documents restricts a team by
  # omission. This Deny restricts it by prohibition: even if a broader
  # Allow turns up elsewhere in the account, the AWS-provided generic
  # forwarding documents stay unusable, so the team cannot escape its
  # host/port allowlist by naming a different document. Skipped for
  # teams that have deliberately opted into unrestricted forwarding.
  dynamic "statement" {
    for_each = each.value.allow_unrestricted_forwarding ? [] : [1]

    content {
      sid       = "DenyGenericForwardingDocuments"
      effect    = "Deny"
      actions   = ["ssm:StartSession"]
      resources = ["arn:${local.partition}:ssm:*:*:document/AWS-StartPortForwarding*"]
    }
  }

  # Likewise for SSH-over-Session-Manager, which would bypass session
  # logging entirely and reintroduce key management. Teams needing real
  # SSH should use the eice module, which is explicit about the cost.
  dynamic "statement" {
    for_each = each.value.allow_unrestricted_forwarding ? [] : [1]

    content {
      sid       = "DenySshSessionDocument"
      effect    = "Deny"
      actions   = ["ssm:StartSession"]
      resources = ["arn:${local.partition}:ssm:*:*:document/AWS-StartSSHSession"]
    }
  }

  statement {
    sid    = "DenyEndingOtherPeoplesSessions"
    effect = "Deny"

    actions   = ["ssm:TerminateSession"]
    resources = ["arn:${local.partition}:ssm:*:*:session/*"]

    # Belt and braces alongside the scoped Allow: if a broader Allow
    # appears elsewhere, this still blocks ending anyone else's session.
    condition {
      test     = "StringNotLike"
      variable = "ssm:resourceTag/aws:ssmmessages:session-id"
      values   = ["$${aws:userid}*"]
    }
  }
}

resource "aws_iam_policy" "team" {
  for_each = var.teams

  name_prefix = "${var.name}-${each.key}-"
  description = "bastion-free-ami: Session Manager access for team ${each.key} (nodes tagged ${var.access_tag_key}=${each.value.access_tag_value})"
  policy      = data.aws_iam_policy_document.team[each.key].json

  tags = merge(local.tags, { Name = "${var.name}-${each.key}", Team = each.key })
}

# ---------------------------------------------------------------------
# Team roles.
#
# Skipped entirely when create_roles = false, which is the IAM Identity
# Center path: Identity Center owns its AWSReservedSSO_* roles and a
# module that created roles for it would fight the service. Attach
# policy_arns to a permission set instead.
# ---------------------------------------------------------------------
data "aws_iam_policy_document" "team_assume" {
  for_each = var.create_roles ? var.teams : {}

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = each.value.trusted_principal_arns
    }

    # MFA on the trust policy. Effective for IAM users and role
    # chaining; a no-op for principals that arrive already federated,
    # where the identity provider is responsible for MFA. Said plainly
    # here because "we require MFA" is a claim people rely on.
    dynamic "condition" {
      for_each = each.value.require_mfa ? [1] : []

      content {
        test     = "Bool"
        variable = "aws:MultiFactorAuthPresent"
        values   = ["true"]
      }
    }

    dynamic "condition" {
      for_each = each.value.max_mfa_age_seconds != null ? [1] : []

      content {
        test     = "NumericLessThan"
        variable = "aws:MultiFactorAuthAge"
        values   = [tostring(each.value.max_mfa_age_seconds)]
      }
    }
  }
}

resource "aws_iam_role" "team" {
  for_each = var.create_roles ? var.teams : {}

  name_prefix          = "${var.name}-${each.key}-"
  description          = "bastion-free-ami access role for team ${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.team_assume[each.key].json
  max_session_duration = each.value.max_session_duration

  tags = merge(
    local.tags,
    { Name = "${var.name}-${each.key}", Team = each.key },
    # Session Manager reads SSMSessionRunAs from the IAM entity's tags
    # and uses it in preference to the account-wide runAsDefaultUser.
    # This is the documented elevation path: a dedicated role tagged
    # with a privileged OS user, separately assumable and separately
    # visible in CloudTrail.
    each.value.session_run_as_user != "" ? { SSMSessionRunAs = each.value.session_run_as_user } : {}
  )
}

resource "aws_iam_role_policy_attachment" "team" {
  for_each = var.create_roles ? var.teams : {}

  role       = aws_iam_role.team[each.key].name
  policy_arn = aws_iam_policy.team[each.key].arn
}

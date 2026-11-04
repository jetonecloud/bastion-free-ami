# ---------------------------------------------------------------------
# Instance role.
#
# Everything granted here is available to anyone who gets a shell on the
# access node, and the whole point of the node is that a lot of people
# can. So this role is as small as Session Manager allows, and notably
# does NOT include AmazonSSMManagedInstanceCore -- that managed policy
# grants Run Command document access, Parameter Store reads, and S3
# access well beyond what an access node needs.
#
# Instead the five actions AWS documents as the minimum for Session
# Manager are granted explicitly, plus scoped logging permissions.
# ---------------------------------------------------------------------
resource "aws_iam_role" "access_node" {
  name_prefix = "${var.name}-"
  description = "bastion-free-ami access node instance role: Session Manager channel and scoped session logging only"

  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = merge(local.tags, { Name = "${var.name}-role" })
}

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_instance_profile" "access_node" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.access_node.name

  tags = merge(local.tags, { Name = "${var.name}-profile" })

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_iam_policy_document" "session_manager" {
  # The minimum set AWS documents for an instance to be reachable over
  # Session Manager.
  #
  # Resource "*" is unavoidable on these five actions and is not a
  # privilege wildcard. ssmmessages actions operate on the agent's own
  # control/data channel, which has no ARN to name, and
  # ssm:UpdateInstanceInformation writes the calling instance's own
  # registration record. AWS's documented minimal instance policy uses
  # "*" for exactly this reason. The actions themselves are tightly
  # bounded: none of them can read or write another resource.
  statement {
    sid    = "SessionManagerChannel"
    effect = "Allow"

    actions = [
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }

  # Session log delivery to CloudWatch Logs. Scoped to the one log group
  # rather than "*", which AWS's example policy uses.
  dynamic "statement" {
    for_each = var.session_log_group_name != "" ? [1] : []

    content {
      sid    = "SessionLogsToCloudWatch"
      effect = "Allow"

      actions = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
      ]
      resources = [
        "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${var.session_log_group_name}",
        "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${var.session_log_group_name}:*",
      ]
    }
  }

  # DescribeLogGroups cannot be scoped to a single group: it is a list
  # operation over the account's log groups and IAM offers no condition
  # key to narrow it. SSM Agent calls it to confirm the configured group
  # exists before streaming. It leaks log group names and nothing else.
  dynamic "statement" {
    for_each = var.session_log_group_name != "" ? [1] : []

    content {
      sid       = "SessionLogsDescribeGroups"
      effect    = "Allow"
      actions   = ["logs:DescribeLogGroups"]
      resources = ["*"]
    }
  }

  # Session log archive to S3, scoped to the configured prefix.
  dynamic "statement" {
    for_each = var.session_log_bucket_arn != "" ? [1] : []

    content {
      sid       = "SessionLogsToS3"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = ["${var.session_log_bucket_arn}/${var.session_log_bucket_prefix}*"]
    }
  }

  # SSM Agent reads the bucket's encryption configuration before
  # uploading so it can set the right SSE headers. The action is
  # bucket-level, hence the bucket ARN without a /*.
  dynamic "statement" {
    for_each = var.session_log_bucket_arn != "" ? [1] : []

    content {
      sid       = "SessionLogsReadBucketEncryption"
      effect    = "Allow"
      actions   = ["s3:GetEncryptionConfiguration"]
      resources = [var.session_log_bucket_arn]
    }
  }

  # KMS for session data encryption and for writing to the encrypted log
  # group and bucket. Scoped to the one key, unlike AWS's example which
  # uses "*" for GenerateDataKey.
  dynamic "statement" {
    for_each = var.session_kms_key_arn != "" ? [1] : []

    content {
      sid    = "SessionDataEncryption"
      effect = "Allow"

      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
      ]
      resources = [var.session_kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "session_manager" {
  name_prefix = "${var.name}-ssm-"
  role        = aws_iam_role.access_node.id
  policy      = data.aws_iam_policy_document.session_manager.json
}

# The CloudWatch Agent is baked into the AMI by the upstream logging
# role; this is the managed policy AWS publishes for it. It grants
# metric puts and log writes, which is more than the scoped grant above,
# so it is a variable rather than unconditional.
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  count = var.attach_cloudwatch_agent_policy ? 1 : 0

  role       = aws_iam_role.access_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "additional" {
  for_each = toset(var.additional_policy_arns)

  role       = aws_iam_role.access_node.name
  policy_arn = each.value
}

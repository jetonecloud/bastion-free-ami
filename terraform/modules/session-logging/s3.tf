# ---------------------------------------------------------------------
# Optional S3 archive for session logs.
#
# Every control here is unconditional when the bucket exists: public
# access blocked on all four dimensions, SSE-KMS with the session key,
# versioning on, TLS required, and a lifecycle policy. A bucket holding
# session transcripts is one of the more sensitive objects in an
# account.
# ---------------------------------------------------------------------
resource "aws_s3_bucket" "archive" {
  count = var.enable_s3_archive ? 1 : 0

  bucket = local.bucket_name

  tags = merge(local.tags, { Name = local.bucket_name })
}

# Not a variable. A bucket of session transcripts must never be public,
# and all four settings are needed: the two ACL settings stop a legacy
# ACL granting access, the two policy settings stop a bucket policy
# doing the same.
resource "aws_s3_bucket_public_access_block" "archive" {
  count = var.enable_s3_archive ? 1 : 0

  bucket = aws_s3_bucket.archive[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "archive" {
  count = var.enable_s3_archive ? 1 : 0

  bucket = aws_s3_bucket.archive[0].id

  rule {
    # Disables ACLs entirely; access is governed by policy alone.
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "archive" {
  count = var.enable_s3_archive ? 1 : 0

  bucket = aws_s3_bucket.archive[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.kms_key_arn
    }
    # Cuts KMS request costs substantially on a bucket receiving many
    # small objects, without weakening the encryption.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "archive" {
  count = var.enable_s3_archive ? 1 : 0

  bucket = aws_s3_bucket.archive[0].id

  versioning_configuration {
    # An audit archive where an object can be silently replaced is not
    # an audit archive.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  count = var.enable_s3_archive ? 1 : 0

  bucket = aws_s3_bucket.archive[0].id

  # Required by the provider when a bucket has versioning enabled.
  depends_on = [aws_s3_bucket_versioning.archive]

  rule {
    id     = "session-log-retention"
    status = "Enabled"

    filter {
      prefix = var.s3_key_prefix
    }

    dynamic "transition" {
      for_each = var.s3_transition_to_glacier_days > 0 ? [1] : []
      content {
        days          = var.s3_transition_to_glacier_days
        storage_class = "GLACIER_IR"
      }
    }

    dynamic "expiration" {
      for_each = var.s3_archive_retention_days > 0 ? [1] : []
      content {
        days = var.s3_archive_retention_days
      }
    }

    # Versioning is on, so non-current versions need their own rule or
    # they accumulate forever and the retention above becomes a fiction.
    dynamic "noncurrent_version_expiration" {
      for_each = var.s3_archive_retention_days > 0 ? [1] : []
      content {
        noncurrent_days = var.s3_archive_retention_days
      }
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "archive" {
  count = var.enable_s3_archive ? 1 : 0

  bucket = aws_s3_bucket.archive[0].id
  policy = data.aws_iam_policy_document.archive[0].json

  # A policy that denies unencrypted writes can lock out the bucket's
  # own configuration calls if it lands first.
  depends_on = [aws_s3_bucket_public_access_block.archive]
}

data "aws_iam_policy_document" "archive" {
  count = var.enable_s3_archive ? 1 : 0

  # Resource uses the bucket's own ARN and a /* on its objects; the /*
  # is the standard way to address object-level actions and is not a
  # privilege wildcard.
  statement {
    sid    = "DenyUnencryptedTransport"
    effect = "Deny"

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.archive[0].arn, "${aws_s3_bucket.archive[0].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "DenyWrongKmsKey"
    effect = "Deny"

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.archive[0].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    # Stops an object being written under a different key, which would
    # leave part of the archive outside the key's access controls and
    # rotation.
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [local.kms_key_arn]
    }
  }

  # NOTE on who writes here.
  #
  # There is deliberately no Allow statement for a service principal.
  # Session logs are uploaded by SSM Agent running ON the access node,
  # using the instance role -- not by the ssm.amazonaws.com service
  # principal acting on its own. AWS's documented instance-profile
  # policy is what grants s3:PutObject and s3:GetEncryptionConfiguration,
  # and terraform/modules/access-node attaches exactly that, scoped to
  # this bucket and prefix.
  #
  # Because the instance role lives in the same account as the bucket,
  # an identity-based Allow is sufficient and a bucket-policy Allow
  # would be redundant surface. The Deny statements above still apply to
  # it, which is the point: they constrain the instance role too.
  #
  # Cross-account archiving is NOT configured here. It additionally
  # requires s3:PutObjectAcl on the role, a bucket policy granting the
  # writing account, and a matching KMS key policy. Pass
  # kms_key_arn/s3_bucket_name and manage that bucket yourself if you
  # need it.
}

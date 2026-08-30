# Remote state backend for every other layer (persistent/, envs/staging/).
# This module itself intentionally uses local state - see README.md for the
# chicken-and-egg reasoning.

resource "aws_s3_bucket" "tfstate" {
  #checkov:skip=CKV_AWS_18:Bootstrap state bucket; versioning covers recovery, access logging would need a second bucket

  # NOTE: no AWS account ID in this name, deliberately. backend "s3" {} blocks
  # in every downstream layer (persistent/, envs/staging/) cannot interpolate
  # variables or data sources - the bucket name has to be a literal string
  # committed to a PUBLIC repo. An account-ID-derived name would mean hardcoding
  # the account ID in plaintext in git history. Do not "improve" this back to
  # an interpolated/account-scoped name later - it would leak the account ID.
  bucket = "chethanraj-${var.project}-tfstate"

  # Deliberately no force_destroy: this bucket holds Terraform state for every
  # other layer. It should never be destroyed as a side effect of a wider apply.
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    # Noncurrent versions only - current state objects must never expire.
    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "tfstate_tls_only" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate_tls_only.json
}

# State locking: Terraform 1.11+ can perform an atomic conditional PUT
# (If-None-Match) directly against this bucket to create/remove a `.tflock`
# object per state key. That capability shipped in S3 in Aug 2024 and
# Terraform 1.11 promoted `use_lockfile` to stable and deprecated
# `dynamodb_table`. A DynamoDB lock table only ever existed as a workaround
# for S3 lacking atomic put-if-absent - it would now be a second resource,
# a second bill and a second thing that can drift from the bucket it
# locks for. Every consumer of this bucket sets `use_lockfile = true` in its
# own backend "s3" block; nothing further is created here.

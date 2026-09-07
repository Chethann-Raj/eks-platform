# terraform/persistent/cloudfront.tf
#
# S3 (private) + CloudFront (OAC) static site for chethanraj.site.
# Holds the apex while envs/staging is torn down; releases it for the demo.
#
# Toggle contract:
#   demo_active = false  -> apex A/AAAA ALIAS CloudFront   (default, cluster down)
#   demo_active = true   -> apex A/AAAA absent             (ExternalDNS create-on-empty)
#
# The CloudFront *aliases* stay attached in both states. Only Route53 records move,
# so flipping the toggle is a ~5s change, not a ~5min distribution update.

# ---------------------------------------------------------------------------
# Provider alias — CloudFront-facing ACM must live in us-east-1.
# If terraform/persistent already has a providers.tf, move this block there.
# ---------------------------------------------------------------------------
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}


# ---------------------------------------------------------------------------
# Variables (move to variables.tf if you keep them separate)
# ---------------------------------------------------------------------------
variable "demo_active" {
  description = "true = release the apex to ExternalDNS/ALB; false = CloudFront holds the apex."
  type        = bool
  default     = false
}

variable "static_site_bucket_prefix" {
  description = "Bucket name prefix; account id is appended for global uniqueness."
  type        = string
  default     = "chethanraj-site-static"
}

variable "static_site_price_class" {
  description = "PriceClass_200 includes the Mumbai edge; PriceClass_100 does not."
  type        = string
  default     = "PriceClass_200"
}

locals {
  static_site_bucket  = "${var.static_site_bucket_prefix}-${data.aws_caller_identity.current.account_id}"
  static_site_aliases = ["chethanraj.site", "www.chethanraj.site"]
  cloudfront_zone_id  = "Z2FDTNDATAQYW2" # fixed, global, for CloudFront alias targets
  cf_cert_domain      = "chethanraj.site"
  cf_cert_sans        = ["*.chethanraj.site"]
}

# ---------------------------------------------------------------------------
# ACM certificate in us-east-1
# ---------------------------------------------------------------------------
resource "aws_acm_certificate" "cloudfront" {
  provider                  = aws.us_east_1
  domain_name               = local.cf_cert_domain
  subject_alternative_names = local.cf_cert_sans
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "chethanraj-site-cloudfront"
  }
}

resource "aws_acm_certificate_validation" "cloudfront" {
  provider        = aws.us_east_1
  certificate_arn = aws_acm_certificate.cloudfront.arn
  # ACM emits one validation CNAME per (account, domain). The records created for
  # aws_acm_certificate.wildcard already cover chethanraj.site and *.chethanraj.site,
  # so this cert validates off them. Both map to the same FQDN -> distinct().
  validation_record_fqdns = distinct([for r in aws_route53_record.cert_validation : r.fqdn])

  timeouts {
    create = "15m"
  }
}

# ---------------------------------------------------------------------------
# Private origin bucket
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "static_site" {
  bucket = local.static_site_bucket

  tags = {
    Name = "chethanraj-site-static"
  }
}

resource "aws_s3_bucket_public_access_block" "static_site" {
  bucket                  = aws_s3_bucket.static_site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "static_site" {
  bucket = aws_s3_bucket.static_site.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "static_site" {
  bucket = aws_s3_bucket.static_site.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "static_site" {
  bucket = aws_s3_bucket.static_site.id
  versioning_configuration {
    status = "Suspended"
  }
}

# ---------------------------------------------------------------------------
# CloudFront: OAC + distribution
# ---------------------------------------------------------------------------
resource "aws_cloudfront_origin_access_control" "static_site" {
  name                              = "chethanraj-site-oac"
  description                       = "OAC for the chethanraj.site static origin"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "static_site" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "chethanraj.site static site"
  default_root_object = "index.html"
  price_class         = var.static_site_price_class
  aliases             = local.static_site_aliases

  origin {
    domain_name              = aws_s3_bucket.static_site.bucket_regional_domain_name
    origin_id                = "s3-static-site"
    origin_access_control_id = aws_cloudfront_origin_access_control.static_site.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-static-site"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS managed policies: CachingOptimized + SecurityHeadersPolicy
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
  }

  # With OAC, a missing key returns 403 (not 404). Map both to the landing page.
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 60
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 60
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cloudfront.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Name = "chethanraj-site-static"
  }
}

# Bucket policy: only this distribution may read.
data "aws_iam_policy_document" "static_site" {
  statement {
    sid       = "AllowCloudFrontServicePrincipalReadOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.static_site.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.static_site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "static_site" {
  bucket = aws_s3_bucket.static_site.id
  policy = data.aws_iam_policy_document.static_site.json

  depends_on = [aws_s3_bucket_public_access_block.static_site]
}

# ---------------------------------------------------------------------------
# Route53 — the toggle
# ---------------------------------------------------------------------------
resource "aws_route53_record" "static_apex_a" {
  count   = var.demo_active ? 0 : 1
  zone_id = aws_route53_zone.primary.zone_id
  name    = "chethanraj.site"
  type    = "A"

  allow_overwrite = true

  alias {
    name                   = aws_cloudfront_distribution.static_site.domain_name
    zone_id                = local.cloudfront_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "static_apex_aaaa" {
  count   = var.demo_active ? 0 : 1
  zone_id = aws_route53_zone.primary.zone_id
  name    = "chethanraj.site"
  type    = "AAAA"

  allow_overwrite = true

  alias {
    name                   = aws_cloudfront_distribution.static_site.domain_name
    zone_id                = local.cloudfront_zone_id
    evaluate_target_health = false
  }
}

# www always points at CloudFront — ExternalDNS only ever claims the apex.
resource "aws_route53_record" "static_www_a" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "www.chethanraj.site"
  type    = "A"

  allow_overwrite = true

  alias {
    name                   = aws_cloudfront_distribution.static_site.domain_name
    zone_id                = local.cloudfront_zone_id
    evaluate_target_health = false
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "static_site_bucket" {
  value = aws_s3_bucket.static_site.id
}

output "static_site_distribution_id" {
  value = aws_cloudfront_distribution.static_site.id
}

output "static_site_domain_name" {
  value = aws_cloudfront_distribution.static_site.domain_name
}

output "apex_holder" {
  value = var.demo_active ? "released (ExternalDNS/ALB)" : "cloudfront"
}

# AWS-managed policies, resolved by name rather than hardcoded UUID.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "Managed-SecurityHeadersPolicy"
}

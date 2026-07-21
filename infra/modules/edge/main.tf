# Edge module - CloudFront distribution fronting the SPA (S3, via Origin
# Access Control) and the API (the api module's ALB). The WAF Web ACL
# itself lives in waf.tf, toggled by var.enable_waf; this file wires it
# into the distribution when present.
#
# Origin pinning: the CloudFront managed prefix list
# (com.amazonaws.global.cloudfront.origin-facing), which the api module's
# ALB security group is locked to, admits traffic from ANY CloudFront
# distribution in ANY AWS account, not just this one. random_password
# "origin_verify" is a secret only this distribution knows - CloudFront
# attaches it as a custom header on every request to the ALB origin, and
# the api module's :80 listener now defaults to a fixed 403 response,
# forwarding only when aws_lb_listener_rule.origin_verify's header
# condition matches. The secret is never an output - it lives in state
# only.

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

# --- Managed policies (looked up by name - account/region agnostic) -------

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# --- SPA origin (S3, private, OAC-only access) -----------------------------
# Bucket names are globally unique, so the random suffix keeps this
# account-agnostic without embedding an account id in the name.

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "spa" {
  bucket        = "${var.name_prefix}-spa-${random_id.bucket_suffix.hex}"
  force_destroy = true # demo teardown - the deploy workflow syncs objects in; `make destroy` must not be blocked by a non-empty bucket

  tags = {
    Name = "${var.name_prefix}-spa"
  }
}

resource "aws_s3_bucket_public_access_block" "spa" {
  bucket = aws_s3_bucket.spa.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "spa" {
  name                              = "${var.name_prefix}-spa"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# --- Origin pinning secret + ALB-side enforcement --------------------------
# The value lives in state only: it is never an output, and the listener
# rule condition and the ALB origin's custom_header below are its only
# two uses.

resource "random_password" "origin_verify" {
  length  = 32
  special = false
}

resource "aws_lb_listener_rule" "origin_verify" {
  listener_arn = var.listener_arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = var.target_group_arn
  }

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin_verify.result]
    }
  }
}

# --- Distribution ------------------------------------------------------

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  http_version        = "http2"
  web_acl_id          = var.enable_waf ? aws_wafv2_web_acl.edge[0].arn : null

  origin {
    origin_id                = "spa"
    domain_name              = aws_s3_bucket.spa.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.spa.id
  }

  origin {
    origin_id   = "api"
    domain_name = var.alb_dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # demo trade-off: the ALB has no certificate, so the CloudFront -> ALB hop is HTTP while viewer -> CloudFront is always HTTPS (viewer_protocol_policy below); tracked as an ADR at project close-out.
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify.result
    }
  }

  default_cache_behavior {
    target_origin_id       = "spa"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "api"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
  }

  # error_caching_min_ttl 0: never cache the SPA rewrite at the edge - cached
  # error pages otherwise mask API recovery for up to 5 minutes per POP.
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "${var.name_prefix}-edge"
  }
}

# --- SPA bucket policy (depends on the distribution's ARN) -----------------

data "aws_iam_policy_document" "spa_bucket" {
  statement {
    sid     = "AllowCloudFrontServicePrincipal"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    resources = ["${aws_s3_bucket.spa.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "spa" {
  bucket = aws_s3_bucket.spa.id
  policy = data.aws_iam_policy_document.spa_bucket.json
}

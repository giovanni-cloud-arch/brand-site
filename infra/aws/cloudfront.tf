# The value Cloudflare must send, and CloudFront checks. Generated here, never typed
# into GitHub. Rotate by changing var.origin_secret_rotation and applying both stacks.
resource "random_password" "origin_verify" {
  length  = 48
  special = false
  keepers = {
    rotation = var.origin_secret_rotation
  }
}

resource "aws_cloudfront_function" "viewer_request" {
  name    = "${var.project}-viewer-request"
  runtime = "cloudfront-js-2.0"
  comment = "Origin-secret check and directory index rewrite"
  publish = true
  code = templatefile("${path.module}/function.js.tftpl", {
    enforce = var.enforce_origin_secret
    secret  = random_password.origin_verify.result
  })

  lifecycle {
    precondition {
      condition     = !var.enforce_origin_secret || local.live
      error_message = "enforce_origin_secret can only be true when domain_stage = live (Cloudflare must already be in front)."
    }
  }
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.project}-site"
  description                       = "CloudFront signs its requests to the private site bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_response_headers_policy" "security" {
  name    = "${var.project}-security-headers"
  comment = "HSTS, CSP and friends, set once at the edge"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = false
      preload                    = false
      override                   = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
    content_security_policy {
      content_security_policy = var.csp
      override                = true
    }
  }

  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = "camera=(), microphone=(), geolocation=()"
      override = true
    }
  }
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  price_class         = "PriceClass_100"
  default_root_object = "index.html"
  comment             = "${var.project} static site"
  aliases             = local.live ? [var.domain_name, "www.${var.domain_name}"] : []

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "site-bucket"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id           = "site-bucket"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.viewer_request.arn
    }
  }

  # A private S3 bucket answers 403 (not 404) for a missing key, so map both to the 404 page.
  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }
  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = local.live ? null : true
    acm_certificate_arn            = local.live ? aws_acm_certificate_validation.site[0].certificate_arn : null
    ssl_support_method             = local.live ? "sni-only" : null
    minimum_protocol_version       = local.live ? "TLSv1.2_2021" : null
  }
}

# Requested when domain_stage is "cert" or "live". Validation happens by DNS: the records
# are exported as the acm_validation_records output and created by the Cloudflare stack.

resource "aws_acm_certificate" "site" {
  count    = local.cert_needed ? 1 : 0
  provider = aws.use1

  domain_name               = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Waits until the certificate is ISSUED. We do not pass validation_record_fqdns because the
# DNS records live in Cloudflare, outside this stack. If the Cloudflare stack has not been
# applied yet this times out, which is the correct failure.
resource "aws_acm_certificate_validation" "site" {
  count    = local.live ? 1 : 0
  provider = aws.use1

  certificate_arn = aws_acm_certificate.site[0].arn

  timeouts {
    create = "15m"
  }
}

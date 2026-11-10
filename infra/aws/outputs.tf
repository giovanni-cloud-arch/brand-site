output "site_bucket" {
  value = aws_s3_bucket.site.bucket
}

output "distribution_id" {
  description = "Set this as the CF_DISTRIBUTION_ID repository variable in GitHub."
  value       = aws_cloudfront_distribution.site.id
}

output "distribution_domain_name" {
  description = "Default CloudFront address. Works as soon as the first apply finishes."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "site_url_preview" {
  value = "https://${aws_cloudfront_distribution.site.domain_name}"
}

output "domain_stage" {
  value = var.domain_stage
}

output "domain_name" {
  value = var.domain_name
}

output "origin_verify_secret" {
  description = "Read by the Cloudflare stack through remote state. Not printed."
  value       = random_password.origin_verify.result
  sensitive   = true
}

output "acm_validation_records" {
  description = "DNS records the Cloudflare stack creates to validate the certificate."
  value = local.cert_needed ? {
    for o in aws_acm_certificate.site[0].domain_validation_options :
    o.domain_name => {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }
  } : {}
}

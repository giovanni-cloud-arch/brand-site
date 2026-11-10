variable "project" {
  description = "Prefix for all resource names. Must match the bootstrap stack."
  type        = string
  default     = "brand-site"
}

variable "region" {
  description = "Region for the S3 bucket."
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Apex domain, e.g. example.com. Ignored while domain_stage = none."
  type        = string
  default     = "example.com"
}

variable "domain_stage" {
  description = <<-EOT
    How far along the custom domain is:
      none - no domain yet. Site is served from the *.cloudfront.net address.
      cert - ACM certificate is requested; its DNS validation records are exported as outputs.
      live - certificate is validated, attached to CloudFront, and the domain aliases are active.
  EOT
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "cert", "live"], var.domain_stage)
    error_message = "domain_stage must be one of: none, cert, live."
  }
}

variable "enforce_origin_secret" {
  description = "When true, CloudFront rejects (403) any request that lacks the secret header Cloudflare adds. Only turn on after Cloudflare is already sending the header."
  type        = bool
  default     = false
}

variable "origin_secret_rotation" {
  description = "Change this value (e.g. 1 -> 2) to generate a new secret header value."
  type        = string
  default     = "1"
}

variable "csp" {
  description = "Content-Security-Policy header. Tune once the real site exists; unsafe-inline for scripts is deliberately NOT allowed."
  type        = string
  default     = "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; font-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
}

variable "budget_email" {
  description = "Email for the monthly cost alert. Empty string disables the budget."
  type        = string
  default     = ""
}

variable "budget_usd" {
  description = "Monthly budget in USD that triggers the alert at 80%."
  type        = number
  default     = 5
}

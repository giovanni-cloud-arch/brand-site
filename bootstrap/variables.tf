variable "region" {
  description = "AWS region for the state bucket and IAM calls."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Short name used as a prefix for every resource. Must match infra/aws/terraform.tfvars."
  type        = string
  default     = "brand-site"
}

variable "github_owner" {
  description = "GitHub user or organisation that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name."
  type        = string
}

variable "create_oidc_provider" {
  description = "Set to false if this AWS account already has the GitHub OIDC provider (only one is allowed per account)."
  type        = bool
  default     = true
}

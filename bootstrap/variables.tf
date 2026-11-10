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

variable "github_owner_id" {
  description = "Numeric GitHub ID of the owner: the number after the @ next to the owner name in the OIDC subject. Leave empty only for older repositories that still use the name-only subject."
  type        = string
  default     = ""
}

variable "github_repo_id" {
  description = "Numeric GitHub ID of the repository: the number after the @ next to the repo name in the OIDC subject. Leave empty only for older repositories that still use the name-only subject."
  type        = string
  default     = ""
}

variable "create_oidc_provider" {
  description = "Set to false if this AWS account already has the GitHub OIDC provider (only one is allowed per account)."
  type        = bool
  default     = true
}

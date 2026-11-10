# Bootstrap stack: run ONCE from your laptop with your own AWS admin credentials.
#
# It creates the things the pipeline itself depends on, so it cannot live in the pipeline:
#   - the S3 bucket that holds Terraform state for the other stacks
#   - the GitHub OIDC identity provider
#   - three IAM roles GitHub Actions can assume (no stored AWS keys anywhere)
#
# This stack keeps its own state in a local file (terraform.tfstate, git-ignored).
# Back that file up, or migrate it into the state bucket after the first apply (see README).

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  state_bucket = "${var.project}-tfstate-${local.account_id}"
  site_bucket  = "${var.project}-site-${local.account_id}" # must match infra/aws/s3.tf
  # GitHub's OIDC subject for repositories created after 2026-07-15 embeds immutable IDs:
  #   repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:refs/heads/main
  # Older repositories use repo:<owner>/<repo>:... . Set both IDs to get the new form.
  repo = var.github_owner_id != "" && var.github_repo_id != "" ? "${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}" : "${var.github_owner}/${var.github_repo}"
  oidc_arn     = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

# ---------------------------------------------------------------- Terraform state bucket

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Saved plans (plans/*) can contain secret values, so they are short-lived:
  # deleted by the apply job after use, and expired here if it never ran.
  rule {
    id     = "expire-saved-plans"
    status = "Enabled"
    filter {
      prefix = "plans/"
    }
    expiration {
      days = 7
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }
}

data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
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
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json
}

# ---------------------------------------------------------------- GitHub OIDC provider

# An account can only have ONE provider for this URL. If you already have one, set
# create_oidc_provider = false and it will be referenced by ARN instead.
resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# ---------------------------------------------------------------- Role 1: site-deploy
# Used by deploy-site.yml on pushes to main. Can only upload to the site bucket and
# invalidate CloudFront. Nothing else.

data "aws_iam_policy_document" "trust_site_deploy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "site_deploy" {
  name                 = "${var.project}-site-deploy"
  assume_role_policy   = data.aws_iam_policy_document.trust_site_deploy.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "site_deploy" {
  statement {
    sid       = "ListSiteBucket"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.site_bucket}"]
  }
  statement {
    sid       = "WriteSiteObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.site_bucket}/*"]
  }
  statement {
    sid       = "InvalidateCache"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = ["arn:aws:cloudfront::${local.account_id}:distribution/*"]
  }
}

resource "aws_iam_role_policy" "site_deploy" {
  name   = "site-deploy"
  role   = aws_iam_role.site_deploy.id
  policy = data.aws_iam_policy_document.site_deploy.json
}

# ---------------------------------------------------------------- Role 2: infra-plan
# Used on pull requests and for the plan job on main. Read-only for AWS resources, so it
# can never change infrastructure. In the state bucket it may only write the state LOCK
# file (needed to run plan) and the saved plan under plans/, never the state itself.

data "aws_iam_policy_document" "trust_infra_plan" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo}:pull_request", "repo:${local.repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "infra_plan" {
  name                 = "${var.project}-infra-plan"
  assume_role_policy   = data.aws_iam_policy_document.trust_infra_plan.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "infra_plan_readonly" {
  role       = aws_iam_role.infra_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "infra_plan" {
  statement {
    sid       = "ReadState"
    actions   = ["s3:ListBucket", "s3:GetObject"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
  }
  statement {
    sid       = "LockFileOnly"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*.tflock"]
  }
  statement {
    sid       = "SavePlan"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/plans/*"]
  }
}

resource "aws_iam_role_policy" "infra_plan" {
  name   = "state-lock"
  role   = aws_iam_role.infra_plan.id
  policy = data.aws_iam_policy_document.infra_plan.json
}

# ---------------------------------------------------------------- Role 3: infra-apply
# Used only by the apply job, which is gated by the GitHub Environment "production"
# (manual approval). The OIDC subject is "environment:production", so this role cannot
# be assumed from a branch, a PR, or an ungated job.

data "aws_iam_policy_document" "trust_infra_apply" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo}:environment:production"]
    }
  }
}

resource "aws_iam_role" "infra_apply" {
  name                 = "${var.project}-infra-apply"
  assume_role_policy   = data.aws_iam_policy_document.trust_infra_apply.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "infra_apply" {
  statement {
    sid     = "SiteBucket"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::${var.project}-site-*",
      "arn:aws:s3:::${var.project}-site-*/*",
    ]
  }
  statement {
    sid       = "EdgeAndCerts"
    actions   = ["cloudfront:*", "acm:*", "budgets:*"]
    resources = ["*"]
  }
  statement {
    sid       = "StateBucketAwsPrefix"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/aws/*"]
  }
  statement {
    sid       = "ReadAndRemoveSavedPlan"
    actions   = ["s3:GetObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/plans/*"]
  }
}

resource "aws_iam_role_policy" "infra_apply" {
  name   = "infra-apply"
  role   = aws_iam_role.infra_apply.id
  policy = data.aws_iam_policy_document.infra_apply.json
}

# ---------------------------------------------------------------- Outputs

output "github_repository_variables" {
  description = "Create these as repository VARIABLES in GitHub (Settings > Secrets and variables > Actions > Variables). They are not secrets."
  value = {
    AWS_REGION            = var.region
    TF_STATE_BUCKET       = local.state_bucket
    SITE_BUCKET           = local.site_bucket
    ROLE_SITE_DEPLOY_ARN  = aws_iam_role.site_deploy.arn
    ROLE_INFRA_PLAN_ARN   = aws_iam_role.infra_plan.arn
    ROLE_INFRA_APPLY_ARN  = aws_iam_role.infra_apply.arn
    CF_DISTRIBUTION_ID    = "(set after the first AWS stack apply: terraform output distribution_id)"
  }
}

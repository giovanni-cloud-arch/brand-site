# brand-site

Personal brand site: a static website on S3 + CloudFront, protected by Cloudflare, deployed by GitHub Actions, all infrastructure in Terraform.

```
bootstrap/        run once, from your laptop (local state)
infra/aws/        S3, CloudFront, ACM, budget   -> applied by GitHub Actions
infra/cloudflare/ DNS, TLS mode, secret header  -> applied from your laptop
site/             the website itself (built separately)
site/placeholder/ one-page stand-in used until site/package.json exists
.github/workflows infra.yml, deploy-site.yml
docs/             architecture.drawio (open at app.diagrams.net)
```

## Why three stacks

| Stack | Who applies it | Why |
|---|---|---|
| `bootstrap` | You, once | It creates the state bucket and the OIDC roles the pipeline needs, so the pipeline cannot create them itself. |
| `infra/aws` | GitHub Actions | Authenticates with OIDC: short-lived credentials, nothing stored. |
| `infra/cloudflare` | You, from your laptop | Cloudflare cannot trust GitHub's OIDC identity, so automating it would put a long-lived Cloudflare token in GitHub. Keeping it local means the pipeline holds no static secret. |

## Prerequisites

Terraform >= 1.10, AWS CLI with admin credentials for your account, a GitHub repo, and (later) a domain on Cloudflare.

## Phase 1: placeholder site on the CloudFront address (no domain needed)

1. **Bootstrap** (laptop):
   ```
   cd bootstrap
   cp terraform.tfvars.example terraform.tfvars   # set github_owner / github_repo
   terraform init && terraform apply
   terraform output github_repository_variables
   ```
2. **GitHub settings.** Repository variables (Settings > Secrets and variables > Actions > Variables): `AWS_REGION`, `TF_STATE_BUCKET`, `SITE_BUCKET`, `ROLE_SITE_DEPLOY_ARN`, `ROLE_INFRA_PLAN_ARN`, `ROLE_INFRA_APPLY_ARN`. These are not secrets.
   Create an Environment named `production` with yourself as **Required reviewer**. Turn on branch protection for `main` (require PR + passing checks).
3. **First AWS apply.** Easiest from your laptop the first time, to see it work:
   ```
   cd infra/aws
   terraform init -backend-config="bucket=<TF_STATE_BUCKET>" -backend-config="region=<AWS_REGION>"
   terraform apply
   terraform output distribution_id        # add as repo variable CF_DISTRIBUTION_ID
   terraform output site_url_preview       # the *.cloudfront.net address
   ```
   After this, infrastructure changes go through pull requests.
4. **Deploy the placeholder.** Push a change under `site/` to `main`. The workflow publishes `site/placeholder/`; open the preview URL and you should see "DEPLOY PIPELINE OK".
5. **When the real site is ready**, put it in `site/` (Astro, with `package.json` and `package-lock.json`). The same workflow builds it and publishes `site/dist`.

## Phase 2: your domain

Change `domain_name` / `domain_stage` in `infra/aws/terraform.tfvars` through a PR for each step. Domain must already be on Cloudflare (nameservers changed at your registrar).

1. `domain_stage = "cert"` -> merge, approve the apply. ACM certificate is requested and the validation records appear in `terraform output acm_validation_records`.
2. **Cloudflare stack** (laptop):
   ```
   export CLOUDFLARE_API_TOKEN=...      # token limited to ONE zone, see infra/cloudflare/main.tf
   cd infra/cloudflare
   terraform init -backend-config="bucket=<TF_STATE_BUCKET>" -backend-config="region=<AWS_REGION>"
   terraform apply -var state_bucket=<TF_STATE_BUCKET>
   ```
   This creates the validation records. Wait until the certificate shows **Issued** in ACM (usually a few minutes).
3. `domain_stage = "live"` -> merge, approve. CloudFront gets the certificate and aliases.
4. Run the Cloudflare stack **again**. Now it also creates the proxied DNS records, sets TLS to Full (strict), bypasses Cloudflare caching, and adds the `x-origin-verify` header.
5. Check your real domain in a browser. It must load.

## Phase 3: lock the back door (the secret header)

Only after step 5 above works:

1. `enforce_origin_secret = true` in `infra/aws/terraform.tfvars` -> PR -> merge -> approve.
2. Test: your domain still loads; `https://<id>.cloudfront.net` now returns **403**.

**Rotate** the secret: bump `origin_secret_rotation` ("1" -> "2"), apply the AWS stack, then apply the Cloudflare stack. There is a short window between the two where the site returns 403; do them back to back.

**Rollback if you lock yourself out:** set `enforce_origin_secret = false` and apply. The raw address works again.

## Day to day

- Change content: edit `site/`, open a PR (it builds and checks), merge (it deploys and invalidates the cache).
- Change infrastructure: edit `infra/aws/`, open a PR (fmt, validate, tflint, Checkov, plan posted as a comment), merge. On `main` a plan job saves the plan to the private state bucket (`plans/`) and shows it in the run summary; read it, then approve the `production` environment and the apply job runs that exact plan.
- Roll back: revert the commit on `main`. S3 versioning keeps old objects for 45 days.

## Security notes

- The site bucket is private. Only this account's CloudFront distribution can read it (OAC).
- Three IAM roles, none usable from a fork or an unapproved job: `site-deploy` (upload + invalidate only), `infra-plan` (read-only; PRs and the plan job on `main`), `infra-apply` (only from the approved `production` Environment).
- `infra-apply` is broad inside CloudFront, ACM, budgets, and `brand-site-site-*` buckets, because those services cannot be scoped much by resource. It cannot touch IAM, EC2, or anything else.
- The origin secret is visible to anyone with read access to your AWS account (it is inside the CloudFront Function). It stops people bypassing Cloudflare; it is not a vault.
- Bootstrap keeps local state. Back up `bootstrap/terraform.tfstate`, or migrate it: add `backend "s3" { key = "bootstrap/terraform.tfstate" ... }` and run `terraform init -migrate-state`.
- Pin third-party GitHub Actions to commit SHAs once you are comfortable; they are on major tags now for readability.

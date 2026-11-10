# Non-secret settings, committed on purpose: the pipeline reads this file.
# Change a value here in a pull request and the plan shows exactly what it does.

project = "brand-site"
region  = "us-east-1"

# Domain rollout. Order: none -> cert -> (Cloudflare stack) -> live. See README.
domain_name  = "example.com"
domain_stage = "none"

# Flip to true LAST, after the site works on your real domain.
enforce_origin_secret  = false
origin_secret_rotation = "1"

# Optional cost alert.
budget_email = ""
budget_usd   = 5

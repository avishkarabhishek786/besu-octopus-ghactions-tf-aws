# Partial S3 backend — values supplied at init (kept out of git). Use a DISTINCT
# key from the chain so the runner has its own state (C1):
#   terraform init \
#     -backend-config="bucket=<state-bucket>" \
#     -backend-config="key=besu/prod/runner.tfstate" \
#     -backend-config="region=<state-region>" \
#     -backend-config="use_lockfile=true"
terraform {
  backend "s3" {
    encrypt = true
  }
}

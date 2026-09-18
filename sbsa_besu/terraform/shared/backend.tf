# =============================================================================
# backend.tf — the `shared` root
# -----------------------------------------------------------------------------
# Partial S3 backend; values supplied at init and kept out of git:
#   terraform init \
#     -backend-config="bucket=<state-bucket>" \
#     -backend-config="key=besu/<env>/shared.tfstate" \   # <env> = sit | uat | prod
#     -backend-config="region=<state-region>" \
#     -backend-config="use_lockfile=true"
#
# WHY THIS IS ITS OWN STATE
#   Both clusters depend on these endpoints. If they lived in `chain`, tearing
#   down the ledger would delete the application cluster's route to KMS,
#   Secrets Manager and ECR — the app would keep running until its first token
#   refresh and then fail in a way that looks nothing like "someone destroyed
#   the chain". Endpoints outlive both clusters, so they get their own state.
# =============================================================================
terraform {
  backend "s3" {
    encrypt = true
  }
}

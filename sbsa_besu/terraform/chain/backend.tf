# =============================================================================
# backend.tf
# -----------------------------------------------------------------------------
# PURPOSE
#   Configures REMOTE STATE storage in S3 with S3-NATIVE state locking.
#
# WHY REMOTE STATE (and not the default local terraform.tfstate file)
#   * State is the source of truth Terraform uses to map your config to real
#     AWS resources. If it lives only on one laptop, you lose it when that
#     laptop dies, and two people can never run Terraform safely.
#   * S3 gives durable, versioned, encrypted storage of state.
#   * State LOCKING prevents two `terraform apply` runs from executing
#     simultaneously and corrupting state — critical when more than one
#     operator manages production.
#
# WHY use_lockfile (S3-native locking) INSTEAD OF a DynamoDB table
#   Recent Terraform / AWS provider versions support holding the lock as an
#   object IN THE STATE BUCKET ITSELF (`use_lockfile=true`), which is why the
#   bucket has versioning enabled. This removes the need for a separate
#   DynamoDB lock table (one fewer resource to create, tag, and clean up) and
#   avoids the now-deprecated `dynamodb_table` backend parameter. Supply
#   `use_lockfile=true` via -backend-config at init time (see below).
#
# WHY PER-REGION / PER-ENVIRONMENT STATE (important design decision)
#   We keep each ENVIRONMENT (prod, non-prod) and each REGION in a SEPARATE
#   state file via the `key` below (set through `-backend-config` at init time,
#   NOT hard-coded). This is deliberate so that:
#     * You can create or destroy one environment WITHOUT touching another.
#     * A mistake while operating one can never corrupt another's state.
#     * `terraform plan` for one scope is fast and isolated.
#
# BOOTSTRAPPING NOTE (chicken-and-egg)
#   The S3 bucket referenced here must EXIST before `terraform init` can use it.
#   It is created by a one-time bootstrap step documented in
#   docs/claude-code-setup.md. We intentionally do NOT manage the state bucket
#   with this same Terraform, to avoid the circular dependency of "Terraform
#   needs state to create the thing that stores its state".
#
# VALUES ARE PARTIAL ON PURPOSE
#   bucket / key / region / use_lockfile are supplied at init time:
#       terraform init -reconfigure \
#         -backend-config="bucket=<state-bucket>" \
#         -backend-config="key=besu/non-prod/main.tfstate" \
#         -backend-config="region=<state-region>" \
#         -backend-config="use_lockfile=true"
#   This keeps environment-specific values out of version control and lets the
#   SAME code initialise any environment/region by changing only the `key`.
# =============================================================================

terraform {
  backend "s3" {
    # All of bucket / key / region / use_lockfile are supplied via
    # -backend-config at `terraform init` time.
    #
    # `encrypt = true` is hard-coded because state may contain sensitive
    # values (e.g. resource attributes) and must never be stored unencrypted.
    encrypt = true
  }
}

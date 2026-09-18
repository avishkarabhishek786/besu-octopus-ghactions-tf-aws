#!/usr/bin/env bash
# =============================================================================
# scripts/runner/push-deploy-config.sh   (run from the LAPTOP)
# -----------------------------------------------------------------------------
# F16: the in-VPC runner receives its source as an S3 bundle (D-21,
# push-runner-bundle.sh) built with `git archive`, so the GITIGNORED env config is
# excluded by construction and must be delivered separately:
#   - terraform/environments/<env>/common.tfvars         (always — every root)
#   - terraform/environments/<env>/chain.tfvars          (always — the chain root)
#   - terraform/environments/<env>/app-identity.tfvars   (app runs only)
#   - terraform/network-handover.auto.tfvars              (always — B18)
#   - terraform/egress-handover.auto.tfvars               (once the egress ticket is answered)
#   - app/web/.env                                        (app runs only)
# This bundles whichever of those exist into a base64 .tar.gz and stores it in
# the Secrets Manager secret Terraform created (`<prefix>-runner-deploy-config`).
# The runner fetches + extracts it at boot (scripts/runner/fetch-deploy-config.sh).
#
# It stays in Secrets Manager rather than the S3 bundle ON PURPOSE: this is the one
# secret part of the delivery, and folding it into an object beside ordinary source
# is how a tfvars full of keys ends up somewhere nobody audits.
#
# Usage (after the laptop AWS-layer apply, before the runner boots/applies):
#   AWS_REGION=us-east-1 ENV=prod \
#     scripts/runner/push-deploy-config.sh [secret-name]
# secret-name defaults to the terraform output `runner_deploy_config_secret`.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

: "${ENV:=prod}"
need aws; need tar; need base64

SECRET="${1:-}"
if [ -z "$SECRET" ]; then
  # The secret is created by the CHAIN root (there is no root at terraform/ any
  # more — build finding B18).
  SECRET="$(terraform -chdir="${REPO_ROOT}/terraform/chain" output -raw runner_deploy_config_secret 2>/dev/null || true)"
fi
[ -n "$SECRET" ] || die "secret name not given and not found in terraform output (runner_deploy_config_secret). Pass it as arg 1."

# Collect the gitignored files that exist (paths are relative to the repo root so
# they extract straight into the runner's clone).
cd "$REPO_ROOT"
# The two HAND-OVER files ride along too (B18). They are *.auto.tfvars, which is
# gitignored, so `git archive` never ships them — yet every root needs the
# network one to plan at all, and the runner root + install-tentacle.sh read the
# egress one (CD-57/CD-60). fetch-deploy-config.sh recreates the per-root
# symlinks after extracting.
# B22: the tfvars are split per scope in this repo (common + chain, Phase D
# 2026-08-30) — the inherited single `primary.tfvars` never existed here, so the
# bundle silently shipped only the hand-overs and every in-VPC plan would have
# failed on missing variables.
CANDIDATES=(
  "terraform/environments/${ENV}/common.tfvars"
  "terraform/environments/${ENV}/chain.tfvars"
  "terraform/environments/${ENV}/hardening-validation.tfvars"
  "terraform/environments/${ENV}/app-identity.tfvars"
  "terraform/network-handover.auto.tfvars"
  "terraform/egress-handover.auto.tfvars"
  "app/web/.env"
)
FILES=()
for f in "${CANDIDATES[@]}"; do [ -f "$f" ] && FILES+=("$f"); done
[ "${#FILES[@]}" -gt 0 ] || die "none of the expected config files exist (looked for: ${CANDIDATES[*]})"

log "bundling ${#FILES[@]} file(s): ${FILES[*]}"
TARB64="$(tar czf - "${FILES[@]}" | base64 -w0)"
# Secrets Manager max is 64KB; these configs are a few KB.
[ "${#TARB64}" -lt 65000 ] || die "config bundle too large for Secrets Manager (${#TARB64}B). Use S3 instead."

sm_put "$SECRET" "$TARB64"
ok "pushed deploy-config bundle to ${SECRET}. The runner will extract it at boot (or run fetch-deploy-config.sh on it)."

#!/usr/bin/env bash
# =============================================================================
# octopus/steps/infra-terraform.sh <root>   — besu-infra, one Terraform root
# -----------------------------------------------------------------------------
# Runs on an Octopus HOSTED worker (public AWS APIs only — the AWS layer, CD-34
# §0.1), INSIDE the worker-tools execution container (the hosted Ubuntu worker
# has no AWS CLI — probed 2026-10-10, ServerTasks-1515), in the extracted
# platform package, with the per-environment AWS OIDC credentials Octopus put
# in the environment. One invocation = one root:
#   shared | chain | runner        (apply order, CLAUDE.md §2)
#
#   1. install the PINNED terraform from scripts/runner/runner-tools.manifest,
#      sha256-verified — the same build the runner uses (CD-23);
#   2. fetch the environment's deploy config (tfvars + hand-overs) from Secrets
#      Manager with the existing fetch-deploy-config.sh — never from Octopus
#      variables, so the values exist in exactly one place (D-21);
#   3. init with the environment's state key (besu/<env>/<root>.tfstate — the
#      <env> segment is load-bearing, CLAUDE.md §2);
#   4. plan -out, attach the plan as an Octopus ARTIFACT (the review record),
#      then apply THAT plan — never a fresh one.
#
# Environment (Octopus project variables, set by the step):
#   BESU_ENV                 sit | uat | prod  (from #{Octopus.Environment.Name})
#   BESU_STATE_BUCKET        BESU_STATE_REGION
#   BESU_DEPLOY_CONFIG       the env's deploy-config secret name
#   BESU_CHAIN_EXTRA_ARGS    optional extra -var args for chain (e.g. node counts)
#   AWS_REGION               the platform region
# =============================================================================
set -euo pipefail

ROOT="${1:?usage: infra-terraform.sh <shared|chain|runner>}"
case "$ROOT" in shared|chain|runner) ;; *) echo "unknown root: $ROOT" >&2; exit 2 ;; esac

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" # the extracted package = the sbsa_besu tree
: "${BESU_ENV:?}" "${BESU_STATE_BUCKET:?}" "${BESU_STATE_REGION:?}" "${BESU_DEPLOY_CONFIG:?}" "${AWS_REGION:?}"
ENV_LC="$(tr '[:upper:]' '[:lower:]' <<<"$BESU_ENV")"

# shellcheck source=../../scripts/lib/common.sh
source "$PKG/scripts/lib/common.sh"
# shellcheck source=lib.sh
source "$PKG/octopus/steps/lib.sh"

# --- 1. pinned terraform -----------------------------------------------------
install_pinned_terraform

# --- 2. the environment's config, from the one place it lives ----------------
DEPLOY_CONFIG_SECRET="$BESU_DEPLOY_CONFIG" bash "$PKG/scripts/runner/fetch-deploy-config.sh"
VARS=(-var-file="../environments/${ENV_LC}/common.tfvars")
case "$ROOT" in
  chain)  chain_tf_vars; VARS=("${CHAIN_VARS[@]}") ;; # shared with workloads-incluster.sh
  runner) VARS=(-var "region=${AWS_REGION}" -var "chain_state_bucket=${BESU_STATE_BUCKET}"
                -var "chain_state_key=besu/${ENV_LC}/chain.tfstate" -var "chain_state_region=${BESU_STATE_REGION}") ;;
esac

# --- 3. init on this environment's state -------------------------------------
init_root "$ROOT"
cd "$PKG/terraform/$ROOT"

# --- 4. plan, record, apply exactly what was recorded -------------------------
terraform plan -input=false -no-color "${VARS[@]}" -out="${ROOT}.plan" | tee "${ROOT}.plan.txt"
if command -v new_octopusartifact >/dev/null 2>&1; then
  new_octopusartifact "$PWD/${ROOT}.plan.txt" "${ROOT}-${ENV_LC}.plan.txt"
fi
terraform apply -input=false -no-color "${ROOT}.plan"

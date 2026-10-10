#!/usr/bin/env bash
# =============================================================================
# octopus/steps/runner-bundle.sh   — besu-infra, between `chain` and `runner`
# -----------------------------------------------------------------------------
# The In-VPC EC2 Runner boots with no internet and takes EVERYTHING from the
# artefacts bucket the chain root creates (D-21). Its bootstrap is FATAL when
# the bundle is absent — the fix it prints is "recreate the instance" — so the
# bundle must be in the bucket before `terraform: runner` creates the instance.
# By hand that was push-runner-bundle.sh + push-deploy-config.sh from the laptop,
# between the two applies (RUNBOOK E.1 step 4). This step does the same on the
# Octopus worker, which has internet, in the same position:
#
#   1. the toolchain — push-runner-bundle.sh: every artefact in
#      runner-tools.manifest downloaded HERE and sha256-verified (a mismatch is
#      a refusal), unpacked, uploaded as tools/tools.tar.gz;
#   2. the source — THIS release package (built from git by release.yml, so
#      committed files only), snapshotted BEFORE anything below writes into it,
#      uploaded as source/source.tar.gz;
#   3. the runner's own config — the chain root's runner_deploy_config_secret,
#      filled with push-deploy-config.sh from the environment's Octopus deploy
#      config (fetch-deploy-config.sh). Two secrets, one content: the runner
#      reads its own; Octopus reads the one aws-trust created.
#
# Environment: as infra-terraform.sh (BESU_ENV, BESU_STATE_BUCKET/REGION,
#              BESU_DEPLOY_CONFIG, AWS_REGION).
# =============================================================================
set -euo pipefail

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${BESU_ENV:?}" "${BESU_STATE_BUCKET:?}" "${BESU_STATE_REGION:?}" "${BESU_DEPLOY_CONFIG:?}" "${AWS_REGION:?}"
ENV_LC="$(tr '[:upper:]' '[:lower:]' <<<"$BESU_ENV")"

# shellcheck source=../../scripts/lib/common.sh
source "$PKG/scripts/lib/common.sh"
# shellcheck source=lib.sh
source "$PKG/octopus/steps/lib.sh"

# Snapshot FIRST: fetch-deploy-config extracts real tfvars into $PKG and init
# writes .terraform/ — neither may reach the source object.
SNAP="$(mktemp -d)"
trap 'rm -rf "$SNAP"' EXIT
cp -a "$PKG/." "$SNAP/"

install_pinned_terraform
init_root chain >/dev/null
BUCKET="$(terraform -chdir="$PKG/terraform/chain" output -raw runner_artifacts_bucket)"
RUNNER_SECRET="$(terraform -chdir="$PKG/terraform/chain" output -raw runner_deploy_config_secret)"
log "artefacts bucket: $BUCKET   runner config secret: $RUNNER_SECRET"

# 1 + 2
bash "$PKG/scripts/runner/push-runner-bundle.sh" --source-dir "$SNAP" "$BUCKET"

# 3
DEPLOY_CONFIG_SECRET="$BESU_DEPLOY_CONFIG" bash "$PKG/scripts/runner/fetch-deploy-config.sh"
ENV="$ENV_LC" bash "$PKG/scripts/runner/push-deploy-config.sh" "$RUNNER_SECRET"

ok "runner bundle and config in place — terraform: runner may now create the instance"

#!/usr/bin/env bash
# =============================================================================
# scripts/runner/fetch-deploy-config.sh   (runs ON THE RUNNER)
# -----------------------------------------------------------------------------
# F16: fetch the gitignored env-config bundle that the laptop pushed
# (scripts/runner/push-deploy-config.sh) from Secrets Manager and extract it into
# the source tree the runner unpacked from S3 (D-21), so
# `terraform apply -var-file=../environments/<env>/common.tfvars -var-file=../environments/<env>/chain.tfvars`
# can find its config. Idempotent + re-runnable: if the bundle isn't pushed yet,
# it logs and exits 0 so user-data does not fail the boot.
#
# Invoked by the runner user-data at boot with DEPLOY_CONFIG_SECRET + AWS_REGION;
# the operator can re-run it after pushing the config:
#   DEPLOY_CONFIG_SECRET=<prefix>-runner-deploy-config AWS_REGION=af-south-1 \
#     scripts/runner/fetch-deploy-config.sh
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

: "${DEPLOY_CONFIG_SECRET:?set DEPLOY_CONFIG_SECRET (the runner-deploy-config secret name)}"
need aws; need tar; need base64

B64="$(sm_get "$DEPLOY_CONFIG_SECRET")"
if [ -z "$B64" ] || [ "$B64" = "None" ]; then
  log "deploy-config bundle not present yet in ${DEPLOY_CONFIG_SECRET}; push it from the laptop, then re-run."
  exit 0
fi

echo "$B64" | base64 -d | tar xzf - -C "$REPO_ROOT"
ok "extracted deploy-config into ${REPO_ROOT}"

# Re-wire the hand-over symlinks (B14/B18): each root reads ONE shared file via
# a symlink that is itself gitignored, so a fresh source bundle has none of them.
#   network-handover -> shared, chain, app        egress-handover -> runner
for root in shared chain app; do
  [ -d "${REPO_ROOT}/terraform/${root}" ] && [ -f "${REPO_ROOT}/terraform/network-handover.auto.tfvars" ] \
    && ln -sfn ../network-handover.auto.tfvars "${REPO_ROOT}/terraform/${root}/network-handover.auto.tfvars" || true
done
[ -d "${REPO_ROOT}/terraform/runner" ] && [ -f "${REPO_ROOT}/terraform/egress-handover.auto.tfvars" ] \
  && ln -sfn ../egress-handover.auto.tfvars "${REPO_ROOT}/terraform/runner/egress-handover.auto.tfvars" || true
# tighten perms on any delivered keys/secrets
find "${REPO_ROOT}/terraform/environments" -maxdepth 2 -name '*.tfvars' -exec chmod 600 {} \; 2>/dev/null || true
[ -f "${REPO_ROOT}/app/web/.env" ] && chmod 600 "${REPO_ROOT}/app/web/.env" || true
ls -1 "${REPO_ROOT}"/terraform/environments/*/*.tfvars 2>/dev/null || true

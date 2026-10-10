#!/usr/bin/env bash
# =============================================================================
# octopus/steps/lib.sh — shared by the besu-infra step scripts (sourced)
# -----------------------------------------------------------------------------
# Expects PKG (the extracted package root) and scripts/lib/common.sh sourced.
# =============================================================================

# The PINNED terraform from scripts/runner/runner-tools.manifest, sha256-verified
# — the build CI and the In-VPC EC2 Runner use (CD-23). The worker-tools image
# ships its own terraform (1.15.x on 2026-10-10); state records the version that
# last wrote it, so a different one here is not cosmetic.
install_pinned_terraform() {
  local want have tmp
  want="$(tool_version terraform)"
  have="$(terraform version -json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || true)"
  if [[ "$have" != "$want" ]]; then
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/tf.zip" "$(tool_url terraform)"
    echo "$(tool_sha terraform)  $tmp/tf.zip" | sha256sum -c -
    (cd "$tmp" && python3 -c 'import zipfile;zipfile.ZipFile("tf.zip").extract("terraform")') # no unzip dependency
    install -m 0755 "$tmp/terraform" /usr/local/bin/terraform 2>/dev/null \
      || { mkdir -p "$HOME/.local/bin"; install -m 0755 "$tmp/terraform" "$HOME/.local/bin/terraform"; export PATH="$HOME/.local/bin:$PATH"; }
    hash -r
  fi
  # sed, not head: head exits after one line, terraform takes SIGPIPE writing
  # the rest, and under `set -o pipefail` the step dies with exit 141 — which
  # is exactly what the first besu-infra deployment did (ServerTasks-1516).
  terraform version | sed -n 1p
}

# init a root on this environment's state (besu/<env>/<root>.tfstate — the <env>
# segment is load-bearing, CLAUDE.md §2).
init_root() {
  terraform -chdir="$PKG/terraform/$1" init -input=false -no-color \
    -backend-config="bucket=${BESU_STATE_BUCKET}" \
    -backend-config="key=besu/${ENV_LC}/$1.tfstate" \
    -backend-config="region=${BESU_STATE_REGION}" \
    -backend-config="use_lockfile=true"
}

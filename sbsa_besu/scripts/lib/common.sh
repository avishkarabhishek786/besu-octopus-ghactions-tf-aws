#!/usr/bin/env bash
# =============================================================================
# scripts/lib/common.sh — shared helpers for the access/PKI/permissioning scripts.
# Source this at the top of each script. Provides timestamped logging, strict
# mode, and small Secrets Manager helpers.
# =============================================================================
set -euo pipefail

: "${AWS_REGION:=af-south-1}"

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { echo "[$(_ts)] INFO  $*"; }
ok()   { echo "[$(_ts)] OK    $*"; }
err()  { echo "[$(_ts)] ERROR $*" >&2; }
die()  { err "$*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# -----------------------------------------------------------------------------
# Pinned toolchain — ONE home for any version more than one host depends on.
# -----------------------------------------------------------------------------
# scripts/runner/runner-tools.manifest is the pin. It is read by
# push-runner-bundle.sh (which builds the In-VPC EC2 Runner's S3 bundle) and by the
# GitHub Actions workflows, so a version that has to agree across hosts cannot
# drift by being restated.
#
# THE RULE, so nobody consolidates this the wrong way:
#   - A version more than one host depends on lives in the MANIFEST.
#       terraform -- CI validates and plans with it, Octopus's execution
#                    container runs it, and the runner applies with it. State
#                    records the version that last wrote it, so a newer
#                    Terraform can refuse or rewrite state (CD-23). These MUST
#                    match; that is why it is not a preference.
#       helm      -- CI pulls and pushes charts, the runner installs them.
#       kubectl, corretto -- runner only today, but bundle members either way.
#   - A version exactly ONE host depends on stays with that host.
#       crane     -- CI only; the runner never mirrors. Pinned in the workflow.
#                    Do not add it to the manifest: it would ship in the runner's
#                    S3 bundle for nothing.
# -----------------------------------------------------------------------------
: "${TOOL_MANIFEST:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../runner" 2>/dev/null && pwd)/runner-tools.manifest}"

# tool_field <name> <column> — column 2=version 3=url 4=sha256
tool_field() {
  local name="${1:?tool name}" field="${2:?column}" out
  [[ -f "$TOOL_MANIFEST" ]] || die "tool manifest not found: $TOOL_MANIFEST"
  out=$(awk -F'\t' -v n="$name" -v f="$field" \
          '/^[^#]/ && NF >= 4 && $1 == n { print $f; exit }' "$TOOL_MANIFEST")
  # An empty result must be fatal, not silent: an unset version interpolated
  # into a download URL fetches a 404 page and the failure surfaces three steps
  # later as a corrupt archive.
  [[ -n "$out" ]] || die "tool '$name' has no column $field in $TOOL_MANIFEST"
  printf '%s\n' "$out"
}
tool_version() { tool_field "$1" 2; }
tool_url()     { tool_field "$1" 3; }
tool_sha()     { tool_field "$1" 4; }

# sm_get <secret-name> -> SecretString on stdout (empty if unset/missing).
sm_get() {
  aws secretsmanager get-secret-value --region "$AWS_REGION" \
    --secret-id "$1" --query SecretString --output text 2>/dev/null || true
}

# sm_put <secret-name> <value> : store/overwrite a secret value.
# H17: pass the value via a 0600 temp file (--secret-string file://), NOT on the
# `aws` process argv — otherwise the secret is visible in /proc/<pid>/cmdline to any
# local user (this path carries the GitHub PAT tarball via push-deploy-config.sh).
sm_put() {
  local _f _rc
  _f="$(mktemp)"
  chmod 600 "$_f"
  printf '%s' "$2" >"$_f"
  # H17: GUARANTEE the 0600 temp file is removed even if put-secret-value fails — capture the rc
  # so `set -e` cannot abort before cleanup and leave the secret sitting in $TMPDIR.
  aws secretsmanager put-secret-value --region "$AWS_REGION" \
    --secret-id "$1" --secret-string "file://$_f" >/dev/null && _rc=0 || _rc=$?
  rm -f "$_f"
  [ "${_rc:-1}" -eq 0 ] || die "put-secret-value failed for $1 (rc=${_rc:-?})"
  ok "wrote secret $1"
}

# sm_put_file <secret-name> <file> : store a file's contents as the secret value.
sm_put_file() {
  aws secretsmanager put-secret-value --region "$AWS_REGION" \
    --secret-id "$1" --secret-string "fileb://$2" >/dev/null 2>&1 \
    || aws secretsmanager put-secret-value --region "$AWS_REGION" \
       --secret-id "$1" --secret-string "$(cat "$2")" >/dev/null
  ok "wrote secret $1 from $2"
}

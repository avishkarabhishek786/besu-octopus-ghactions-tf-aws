#!/usr/bin/env bash
# =============================================================================
# scripts/runner/push-runner-bundle.sh   (run from the LAPTOP / a CI runner)
# -----------------------------------------------------------------------------
# D-21: deliver the In-VPC EC2 Runner's TOOLCHAIN and SOURCE through S3, so the
# runner needs no package manager, no internet and no GitHub token.
#
# THE PROBLEM THIS SOLVES
#   The runner boots in a VPC with NO egress. The old bootstrap ran `dnf install`,
#   curl'd dl.k8s.io / raw.githubusercontent.com / rpm.releases.hashicorp.com /
#   awscli.amazonaws.com, and `git clone`d GitHub -- five internet dependencies,
#   every one of which HANGS until timeout in the real VPC rather than failing.
#   The runner is the only path to the private EKS API, so that blocks everything.
#
# WHAT THIS DOES
#   Downloads the pinned toolchain (runner-tools.manifest) HERE, where there is
#   internet, verifies each digest, and uploads two objects to the artefact
#   bucket the chain root created:
#       s3://<bucket>/tools/tools.tar.gz     bin/{kubectl,helm,terraform} + jvm/ + tentacle/
#       s3://<bucket>/source/source.tar.gz   this repo at HEAD (git archive)
#   The runner fetches both at boot over the S3 GATEWAY endpoint -- free, and
#   already required for ECR image layers, so no new network path is needed.
#
#   Archives are unpacked HERE, not on the runner: it ships a flat tarball, so
#   the runner needs no `unzip` and no package installs at all. AL2023 ships
#   AWS CLI v2, tar and gzip in the base AMI -- that is the entire dependency set.
#
# USAGE
#   AWS_REGION=af-south-1 scripts/runner/push-runner-bundle.sh [bucket]
#   AWS_REGION=af-south-1 scripts/runner/push-runner-bundle.sh --record   # pin digests
#
#   bucket defaults to the chain root's `runner_artifacts_bucket` output.
#   Run it AFTER the chain AWS-layer apply and BEFORE applying terraform/runner.
#
# FLAGS
#   --record        resolve each artefact's sha256 and write it back into the
#                   manifest, then exit. Run once, review, commit the digests.
#   --tools-only    skip the source archive
#   --source-only   skip the toolchain (much faster; source changes far more often)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MANIFEST="${SCRIPT_DIR}/runner-tools.manifest"

need aws; need tar; need curl; need sha256sum; need git

RECORD=false; DO_TOOLS=true; DO_SOURCE=true; BUCKET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --record)      RECORD=true ;;
    --tools-only)  DO_SOURCE=false ;;
    --source-only) DO_TOOLS=false ;;
    -*) die "unknown flag: $1" ;;
    *)  BUCKET="$1" ;;
  esac
  shift
done

if [ "$RECORD" = false ]; then
  if [ -z "$BUCKET" ]; then
    BUCKET="$(terraform -chdir="${REPO_ROOT}/terraform/chain" output -raw runner_artifacts_bucket 2>/dev/null || true)"
  fi
  [ -n "$BUCKET" ] || die "bucket not given and not found in terraform output (runner_artifacts_bucket). Apply the chain root first, or pass the name as arg 1."
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# -----------------------------------------------------------------------------
# TOOLCHAIN
# -----------------------------------------------------------------------------
# Each artefact is downloaded, digest-checked against the manifest pin, then
# unpacked into a common layout. Verification is a REFUSAL, not a warning: a
# toolchain that runs `terraform apply` against a payment ledger is not a place
# to accept "probably the right bytes".
if [ "$DO_TOOLS" = true ]; then
  log "building the toolchain bundle from $(basename "$MANIFEST")"
  mkdir -p "$WORK/tools/bin" "$WORK/tools/jvm"
  RECORDED=""

  while IFS=$'\t' read -r name version url pinned; do
    case "$name" in ''|\#*) continue ;; esac
    log "  ${name} ${version}"
    art="$WORK/$(basename "$url")"
    curl -fsSL --retry 3 -o "$art" "$url" || die "download failed: $url"

    got="$(sha256sum "$art" | cut -d' ' -f1)"
    if [ "$pinned" = "-" ]; then
      if [ "$RECORD" = false ]; then
        log "    WARNING: ${name} is UNPINNED in the manifest (sha256 = '-')."
        log "             Run with --record once, review, and commit the digests."
      fi
    elif [ "$got" != "$pinned" ]; then
      err "    digest MISMATCH for ${name} ${version}"
      err "      manifest: ${pinned}"
      err "      download: ${got}"
      die "refusing to ship unverified bytes. Either the upstream artefact changed (investigate) or the pin is stale (update it deliberately)."
    else
      ok "    digest verified"
    fi
    RECORDED="${RECORDED}${name}\t${version}\t${url}\t${got}\n"

    # Unpack HERE so the runner needs no unzip and no package installs.
    case "$name" in
      kubectl)   install -m 0755 "$art" "$WORK/tools/bin/kubectl" ;;
      helm)      tar xzf "$art" -C "$WORK" && install -m 0755 "$WORK"/linux-amd64/helm "$WORK/tools/bin/helm" ;;
      terraform) need unzip; unzip -qo "$art" -d "$WORK/tf" && install -m 0755 "$WORK/tf/terraform" "$WORK/tools/bin/terraform" ;;
      corretto)  tar xzf "$art" -C "$WORK/tools/jvm" --strip-components=1 ;;
      # The tarball's top-level directory is `tentacle/`, so this lands at
      # tools/tentacle/Tentacle — where install-tentacle.sh expects it (CD-57).
      tentacle)  tar xzf "$art" -C "$WORK/tools" && [ -x "$WORK/tools/tentacle/Tentacle" ] || die "tentacle tarball did not contain tentacle/Tentacle" ;;
      *)         die "no unpack rule for '${name}' -- add one before adding it to the manifest." ;;
    esac
  done < "$MANIFEST"

  if [ "$RECORD" = true ]; then
    # Rewrite the manifest in place, preserving the comment header verbatim.
    tmp="$WORK/manifest.new"
    grep -E '^(#|$)' "$MANIFEST" > "$tmp"
    printf "%b" "$RECORDED" >> "$tmp"
    mv "$tmp" "$MANIFEST"
    ok "digests recorded in $(basename "$MANIFEST"). Review the diff and commit it."
    exit 0
  fi

  {
    echo "# runner toolchain bundle -- built $(_ts) from runner-tools.manifest"
    printf "%b" "$RECORDED"
  } > "$WORK/tools/MANIFEST.txt"

  tar czf "$WORK/tools.tar.gz" -C "$WORK/tools" .
  log "uploading tools.tar.gz ($(du -h "$WORK/tools.tar.gz" | cut -f1)) -> s3://${BUCKET}/tools/"
  aws s3 cp "$WORK/tools.tar.gz" "s3://${BUCKET}/tools/tools.tar.gz" --only-show-errors
  ok "toolchain uploaded"
fi

# -----------------------------------------------------------------------------
# SOURCE
# -----------------------------------------------------------------------------
# `git archive` exports the committed tree at HEAD: no .git directory, and
# gitignored files are excluded by construction. The gitignored ENV CONFIG
# (primary.tfvars et al) is delivered separately and deliberately, through
# Secrets Manager, by push-deploy-config.sh -- it must never land in an S3
# object alongside the source.
if [ "$DO_SOURCE" = true ]; then
  REF="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
  if ! git -C "$REPO_ROOT" diff-index --quiet HEAD -- 2>/dev/null; then
    log "WARNING: the working tree is DIRTY. git archive ships HEAD (${REF}), not your"
    log "         uncommitted changes. Commit them first or the runner deploys older code."
  fi
  log "archiving source at ${BRANCH}@${REF}"
  git -C "$REPO_ROOT" archive --format=tar.gz -o "$WORK/source.tar.gz" HEAD
  log "uploading source.tar.gz ($(du -h "$WORK/source.tar.gz" | cut -f1)) -> s3://${BUCKET}/source/"
  aws s3 cp "$WORK/source.tar.gz" "s3://${BUCKET}/source/source.tar.gz" \
    --metadata "git-ref=${REF},git-branch=${BRANCH}" --only-show-errors
  ok "source uploaded (${BRANCH}@${REF})"
fi

ok "done. Now apply terraform/runner; the instance fetches both objects at boot."

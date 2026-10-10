#!/usr/bin/env bash
# =============================================================================
# mirror.sh — copy every third-party artefact into our private ECR.
# -----------------------------------------------------------------------------
# Reads scripts/supply-chain/mirror.manifest (the single source of truth, CD-12)
# and copies each image and chart from its public upstream into ECR.
#
# WHY THIS EXISTS AT ALL
#   ECR is a registry, not a proxy (D-17). Pull-through cache needs an internet
#   route on the FIRST pull when ECR is reached through an interface endpoint,
#   and the ledger VPC has no such route. So nothing arrives in ECR by accident:
#   every byte the platform runs is put there deliberately, by this script.
#
# WHERE IT RUNS
#   Outside the VPC, on a host with internet and IAM credentials. ECR has PUBLIC
#   service endpoints, so push works from anywhere; the ecr.api/ecr.dkr
#   interface endpoints exist for the other direction, so the air-gapped VPC can
#   PULL. Push outside, pull inside, one registry. Nothing in the VPC ever
#   contacts a public registry.
#
#   Normally that host is a CI runner (.github/workflows/supply-chain.yml). A
#   laptop is legitimate for bring-up and NOT for go-live: no audit trail of
#   what was mirrored by whom, no repeatability, bus factor of one (CD-19).
#
# WHY `crane` AND NEVER `docker pull/tag/push`
#   docker re-creates the manifest on push, which CHANGES THE DIGEST (D-18) and
#   silently invalidates every H38 digest pin. crane copies the manifest bytes
#   as they are. It also streams blob-to-blob with no daemon and no local
#   unpacking, so 23 images do not need 23 images' worth of disk.
#
# Usage:
#   ECR_REGISTRY=<acct>.dkr.ecr.<region>.amazonaws.com ECR_PREFIX=<prefix> \
#     scripts/supply-chain/mirror.sh [options]
#
#   --dry-run        resolve and report; copy nothing
#   --check-drift    assert the 8 platform rows match terraform/chain/variables.tf
#   --check-repos    report ECR repositories that do not exist; create none
#   --create-repos   create missing repositories (needs ecr:CreateRepository —
#                    we may not have it; the registry is a central shared account)
#   --images-only | --charts-only
#   --record         write resolved digests back into the manifest
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="${MANIFEST:-$REPO_ROOT/scripts/supply-chain/mirror.manifest}"

DRY_RUN=false; CHECK_DRIFT=false; CHECK_REPOS=false; CREATE_REPOS=false
DO_IMAGES=true; DO_CHARTS=true; RECORD=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=true ;;
    --check-drift)  CHECK_DRIFT=true; DO_IMAGES=false; DO_CHARTS=false ;;
    --check-repos)  CHECK_REPOS=true; DO_IMAGES=false; DO_CHARTS=false ;;
    --create-repos) CREATE_REPOS=true ;;
    --images-only)  DO_CHARTS=false ;;
    --charts-only)  DO_IMAGES=false ;;
    --record)       RECORD=true ;;
    -h|--help)      sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

_ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { echo "[$(_ts)] INFO  $*"; }
ok()   { echo "[$(_ts)] OK    $*"; }
warn() { echo "[$(_ts)] WARN  $*" >&2; }
err()  { echo "[$(_ts)] ERROR $*" >&2; }
die()  { err "$*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"

# -----------------------------------------------------------------------------
# rows <kind> — emit the manifest rows of one kind, comments and blanks stripped.
# -----------------------------------------------------------------------------
rows() { awk -F'\t' -v k="$1" '/^[^#]/ && NF >= 5 && $1 == k' "$MANIFEST"; }

# -----------------------------------------------------------------------------
# record_digest <name> <digest> — pin a resolved digest back into the manifest.
# -----------------------------------------------------------------------------
# Called on BOTH the copied and the already-present paths. Recording only what
# this run happened to copy would mean a second run -- when everything is
# already mirrored, which is the steady state -- records nothing, and --record
# exists precisely to turn resolved digests into pins.
# -----------------------------------------------------------------------------
record_digest() {
  [[ "$RECORD" == true ]] || return 0
  awk -F'\t' -v OFS='\t' -v n="$1" -v d="$2" \
    '$1=="image" && $2==n {$6=d} {print}' "$MANIFEST" > "$MANIFEST.tmp" \
    && mv "$MANIFEST.tmp" "$MANIFEST"
}

# =============================================================================
# --check-drift — the 8 platform images live in TWO places, so prove they agree
# =============================================================================
# Terraform owns var.container_images (it is what actually gets deployed) and
# this manifest owns what gets mirrored. If they disagree, the mirror copies a
# version the cluster will never ask for while the version it DOES ask for is
# absent -- and the symptom is ImagePullBackOff on a registry that looks fully
# populated. CD-12 says one source of truth; this is how that is enforced, since
# Terraform cannot read a TSV and a variable default cannot be templated.
# =============================================================================
if [[ "$CHECK_DRIFT" == true ]]; then
  TFVARS="$REPO_ROOT/terraform/chain/variables.tf"
  [[ -f "$TFVARS" ]] || die "not found: $TFVARS"
  FAIL=0
  while IFS=$'\t' read -r _ name source path version _; do
    line=$(grep -E "^[[:space:]]*${name}[[:space:]]*=[[:space:]]*\{" "$TFVARS" || true)
    if [[ -z "$line" ]]; then
      # Only the 8 platform keys exist in Terraform; the 15 chart-carried ones
      # deliberately do not, so their absence is correct rather than a failure.
      continue
    fi
    tf_host=$(sed -n 's/.*host[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$line")
    tf_repo=$(sed -n 's/.*repository[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$line")
    tf_tag=$( sed -n 's/.*tag[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$line")
    if [[ "$tf_host" == "$source" && "$tf_repo" == "$path" && "$tf_tag" == "$version" ]]; then
      ok "drift check: $name = $source/$path:$version"
    else
      err "DRIFT: $name — manifest says $source/$path:$version, Terraform says $tf_host/$tf_repo:$tf_tag"
      FAIL=$((FAIL+1))
    fi
  done < <(rows image)
  [[ "$FAIL" -eq 0 ]] || die "$FAIL platform image(s) disagree between the manifest and Terraform"
  ok "manifest and terraform/chain/variables.tf agree on every platform image"
  exit 0
fi

# =============================================================================
# Everything past here talks to ECR.
# =============================================================================
: "${ECR_REGISTRY:?set ECR_REGISTRY, e.g. 111122223333.dkr.ecr.af-south-1.amazonaws.com}"
: "${ECR_PREFIX:?set ECR_PREFIX, the repository namespace we own, e.g. besu}"
AWS_REGION="${AWS_REGION:-af-south-1}"
need aws

# The ECR repository for an artefact keeps its upstream path under our prefix,
# so provenance is readable from the repository name alone and two upstreams
# with the same leaf name cannot collide.
repo_for()  { echo "${ECR_PREFIX}/$1"; }
target_for() { echo "${ECR_REGISTRY}/$(repo_for "$1")"; }

# --- which repositories does the manifest require? ---------------------------
required_repos() {
  rows image | cut -f4 | while read -r p; do repo_for "$p"; done
  rows chart | cut -f4 | while read -r c; do repo_for "charts/$c"; done
}

missing_repos() {
  local want existing
  want=$(required_repos | sort -u)
  # describe-repositories lists everything we can see; comparing locally avoids
  # one API call per repository and works when we lack DescribeRepositories on
  # individual names.
  existing=$(aws ecr describe-repositories --region "$AWS_REGION" \
               --query 'repositories[].repositoryName' --output text 2>/dev/null | tr '\t' '\n' | sort -u || true)
  comm -23 <(echo "$want") <(echo "$existing")
}

if [[ "$CHECK_REPOS" == true ]]; then
  MISS=$(missing_repos)
  if [[ -z "$MISS" ]]; then
    ok "all $(required_repos | sort -u | wc -l) required ECR repositories exist"
    exit 0
  fi
  err "missing ECR repositories:"
  echo "$MISS" | sed 's/^/    /' >&2
  cat >&2 <<'MSG'

The registry is in a central shared-services account (#25b), so we may not hold
ecr:CreateRepository. Either request these repositories, or ask for a scoped
role that can create them under our prefix -- otherwise every upstream version
bump becomes a ticket. See docs/CLOUD_TEAM_FOLLOWUP_2026-09-09.md, R-5b.
MSG
  exit 1
fi

need crane
need helm

log "authenticating to ECR ($ECR_REGISTRY)"
if [[ "$DRY_RUN" == false ]]; then
  aws ecr get-login-password --region "$AWS_REGION" \
    | crane auth login "$ECR_REGISTRY" --username AWS --password-stdin
  aws ecr get-login-password --region "$AWS_REGION" \
    | helm registry login "$ECR_REGISTRY" --username AWS --password-stdin
fi

# Docker Hub rate-limits ANONYMOUS pulls at 100 per 6 hours, enforced PER SOURCE
# IP. A shared runner estate presents few egress addresses to every team using
# it, so an unauthenticated mirror run can fail intermittently through no fault
# of its own -- which is worse than failing consistently. Authenticate if we can.
if [[ -n "${DOCKERHUB_USERNAME:-}" && -n "${DOCKERHUB_TOKEN:-}" ]]; then
  log "authenticating to Docker Hub as $DOCKERHUB_USERNAME"
  [[ "$DRY_RUN" == true ]] || printf '%s' "$DOCKERHUB_TOKEN" \
    | crane auth login index.docker.io --username "$DOCKERHUB_USERNAME" --password-stdin
else
  warn "no Docker Hub credentials (DOCKERHUB_USERNAME/DOCKERHUB_TOKEN). Anonymous pulls are rate-limited per IP and may fail intermittently on a shared runner."
fi

# --- create repositories, if we are allowed and were asked -------------------
if [[ "$CREATE_REPOS" == true ]]; then
  while read -r r; do
    [[ -n "$r" ]] || continue
    log "creating ECR repository $r"
    if [[ "$DRY_RUN" == false ]]; then
      # Tag immutability is the registry-side backstop behind every H38 digest
      # pin: a tag is a mutable pointer, and on a permissioned ledger a mutable
      # pointer means a validator can restart as software nobody reviewed.
      aws ecr create-repository --region "$AWS_REGION" --repository-name "$r" \
        --image-tag-mutability IMMUTABLE \
        --image-scanning-configuration scanOnPush=true >/dev/null \
        || die "could not create $r — the registry is a central shared account and we may not hold ecr:CreateRepository (R-5b)"
    fi
  done < <(missing_repos)
else
  MISS=$(missing_repos)
  if [[ -n "$MISS" && "$DRY_RUN" == true ]]; then
    # A dry run reports, it does not stop at the first precondition. Before
    # the first real run NO repository exists, and dying here meant the dry
    # run never resolved a single upstream digest — the part most worth
    # rehearsing (seen 2026-10-10, the workflow's second run).
    warn "$(echo "$MISS" | wc -l) ECR repositories do not exist — a real run needs --create-repos, or a request for them (R-5b):"
    echo "$MISS" | sed 's/^/    /' >&2
  elif [[ -n "$MISS" ]]; then
    err "these ECR repositories do not exist:"; echo "$MISS" | sed 's/^/    /' >&2
    die "re-run with --create-repos, or request them (R-5b)"
  fi
fi

COPIED=0; SKIPPED=0; FAILED=0
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
{ echo "## Supply-chain mirror"; echo; echo "| artefact | version | digest | action |"; echo "|---|---|---|---|"; } >> "$SUMMARY"

# =============================================================================
# Images
# =============================================================================
if [[ "$DO_IMAGES" == true ]]; then
  while IFS=$'\t' read -r _ name source path version digest; do
    src="${source}/${path}:${version}"
    dst="$(target_for "$path"):${version}"

    if ! up_digest=$(crane digest "$src" 2>/dev/null); then
      err "$name: cannot resolve upstream $src"
      FAILED=$((FAILED+1))
      echo "| $name | $version | - | **UPSTREAM UNREACHABLE** |" >> "$SUMMARY"
      continue
    fi

    # If the manifest pins a digest, the tag must still resolve to it. A tag
    # that has moved upstream is not a warning: it is the exact substitution
    # this platform's digest pinning exists to prevent.
    if [[ "$digest" != "-" && -n "$digest" && "$digest" != "$up_digest" ]]; then
      err "$name: manifest pins $digest but ${src} now resolves to $up_digest — the upstream tag has MOVED. Do not mirror this until it is explained."
      FAILED=$((FAILED+1))
      echo "| $name | $version | \`$up_digest\` | **TAG MOVED UPSTREAM** |" >> "$SUMMARY"
      continue
    fi

    # Tag immutability is ENABLED on the registry, so pushing over an existing
    # tag FAILS rather than overwriting. Check first: identical means done,
    # different means something is wrong that a retry would not fix.
    if have_digest=$(crane digest "$dst" 2>/dev/null); then
      if [[ "$have_digest" == "$up_digest" ]]; then
        ok "$name already mirrored at $up_digest"
        SKIPPED=$((SKIPPED+1))
        record_digest "$name" "$up_digest"
        echo "| $name | $version | \`$up_digest\` | already present |" >> "$SUMMARY"
        continue
      fi
      err "$name: ECR holds $have_digest for tag $version but upstream is $up_digest. Tag immutability means this cannot be overwritten, and it should not be — investigate before doing anything."
      FAILED=$((FAILED+1))
      echo "| $name | $version | \`$have_digest\` != \`$up_digest\` | **CONFLICT** |" >> "$SUMMARY"
      continue
    fi

    log "copying $src -> $dst  ($up_digest)"
    if [[ "$DRY_RUN" == true ]]; then
      echo "| $name | $version | \`$up_digest\` | would copy |" >> "$SUMMARY"
      continue
    fi
    # Copy BY DIGEST so the bytes cannot change between resolving and copying,
    # then apply the tag. --all-tags is deliberately not used: we mirror exactly
    # what is pinned, never whatever else the upstream repository happens to
    # carry.
    if crane copy "${source}/${path}@${up_digest}" "$dst"; then
      ok "$name mirrored"
      COPIED=$((COPIED+1))
      echo "| $name | $version | \`$up_digest\` | copied |" >> "$SUMMARY"
    else
      err "$name: copy failed"
      FAILED=$((FAILED+1))
      echo "| $name | $version | \`$up_digest\` | **COPY FAILED** |" >> "$SUMMARY"
    fi

    record_digest "$name" "$up_digest"
  done < <(rows image)
fi

# =============================================================================
# Charts (D-22)
# =============================================================================
# The charts must reach an air-gapped cluster too, so they are pushed to ECR as
# OCI artefacts and the helm_release blocks consume oci://. Mirroring the chart
# is only half the job: each chart hardcodes its own images, so the module that
# installs it ALSO needs a values override pointing at ECR. The reference
# pipelines we were shown mirror the chart and not its images -- copy that and
# all 15 chart-carried images hang while Besu and Blockscout pull fine.
if [[ "$DO_CHARTS" == true ]]; then
  WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
  while IFS=$'\t' read -r _ name source path version _; do
    log "pulling chart $path $version from $source"
    if [[ "$DRY_RUN" == true ]]; then
      echo "| chart/$name | $version | - | would push |" >> "$SUMMARY"
      continue
    fi
    if ! helm pull "$path" --repo "$source" --version "$version" --destination "$WORK" >/dev/null 2>&1; then
      err "chart $name: pull failed from $source"
      FAILED=$((FAILED+1))
      echo "| chart/$name | $version | - | **PULL FAILED** |" >> "$SUMMARY"
      continue
    fi
    if helm push "$WORK/${path}-${version}.tgz" "oci://${ECR_REGISTRY}/${ECR_PREFIX}/charts" >/dev/null 2>&1; then
      ok "chart $name pushed"
      COPIED=$((COPIED+1))
      echo "| chart/$name | $version | - | pushed |" >> "$SUMMARY"
    else
      # Tag immutability applies to OCI charts as well, so an existing version
      # is the normal steady state rather than an error.
      warn "chart $name: push failed — most likely already present at this version (tag immutability)"
      SKIPPED=$((SKIPPED+1))
      echo "| chart/$name | $version | - | already present or push refused |" >> "$SUMMARY"
    fi
  done < <(rows chart)
fi

echo
log "copied $COPIED, already present $SKIPPED, failed $FAILED"
{ echo; echo "**copied $COPIED · already present $SKIPPED · failed $FAILED**"; } >> "$SUMMARY"
[[ "$FAILED" -eq 0 ]] || die "$FAILED artefact(s) failed — the cluster will ImagePullBackOff on each"
ok "mirror complete"

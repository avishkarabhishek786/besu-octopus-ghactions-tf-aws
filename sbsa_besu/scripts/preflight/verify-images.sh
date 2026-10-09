#!/usr/bin/env bash
# =============================================================================
# verify-images.sh — prove every image is pullable BEFORE the cluster needs it.
# -----------------------------------------------------------------------------
# WHY THIS EXISTS
#   The production VPC has no egress. An image that is not in the registry does not
#   fail cleanly: the pull routes to a public IP with no path out and HANGS
#   until timeout, surfacing as ImagePullBackOff with nothing in any log naming
#   the registry as the cause. That is expensive to debug with a half-built
#   cluster billing by the hour, and trivial to rule out beforehand.
#
#   Run this from somewhere that can reach the registry -- the In-VPC EC2 Runner is ideal,
#   since it proves reachability from where the pulls will actually happen.
#
# WHAT IT DOES **NOT** PROVE -- READ THIS BEFORE TRUSTING AN EXIT 0  (D-38, #38)
#   It authenticates as ITSELF: REGISTRY_USER/REGISTRY_PASS below, or the ambient
#   credentials of whoever runs it. Under CT-5 the pull that actually matters is
#   kubelet's, performed with the CLOUD TEAM'S NODE ROLE via the ECR credential
#   provider -- a different principal, evaluated against the repository policy
#   plus that role's own identity policy, neither of which this script touches.
#
#   So this script exits 0 whether or not the cluster can pull. The sentence
#   above ("the In-VPC EC2 Runner is ideal") understated it: the RUNNER passes while
#   the cluster still cannot pull. A check that cannot fail is worse than no
#   check, because it is trusted (CICD design notes 11.3).
#
#   Its exit 0 means: "the images exist in the registry at these digests, and
#   this host can reach them." Nothing more. #38 is closed by three other things:
#     - the node role ARN present in each repository policy with
#       ecr:BatchGetImage / GetDownloadUrlForLayer / BatchCheckLayerAvailability
#       (asserted at plan time by modules/cluster-contract);
#     - ecr:GetAuthorizationToken in that role's IDENTITY policy -- no repository
#       policy can grant it, and one scoped to their own registry account refuses
#       ours;
#     - verify-pull-canary.sh -- one pod, one small image, in our namespace. The
#       only authoritative proof, because it is the only one that pulls as them.
#
# WHAT IT DOES
#   Resolves the image list from Terraform itself (so it can never disagree with
#   what will be deployed), then for each one asks the registry for the manifest
#   and prints the digest. Digests are what you paste into container_images to
#   pin by content (H38).
#
# Usage:
#   scripts/preflight/verify-images.sh [-e sit|uat|prod]
#
# Auth (optional):  REGISTRY_USER / REGISTRY_PASS
# =============================================================================
set -euo pipefail

# No default. Three environments now (sit|uat|prod), each with its OWN CIDR
# allocation and hand-over -- so a defaulted environment would resolve the image
# list from one environment's tfvars while the operator believed they were
# checking another. Make the caller say which.
ENV_NAME=""
while getopts "e:h" opt; do
  case "$opt" in
    e) ENV_NAME="$OPTARG" ;;
    h) sed -n '2,48p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHAIN_DIR="$REPO_ROOT/terraform/chain"
case "$ENV_NAME" in
  sit|uat|prod) ;;
  "") echo "usage: verify-images.sh -e sit|uat|prod" >&2; exit 2 ;;
  *)  echo "unknown environment '$ENV_NAME' (expected sit|uat|prod)" >&2; exit 2 ;;
esac
ENV_DIR="$REPO_ROOT/terraform/environments/$ENV_NAME"

log()  { printf '[%s] %s\n'      "$(date -u +%H:%M:%S)" "$*"; }
ok()   { printf '[%s] PASS  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
bad()  { printf '[%s] FAIL  %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required."
[[ -d "$CHAIN_DIR" ]] || die "chain root not found at $CHAIN_DIR"
[[ -f "$ENV_DIR/common.tfvars" ]] || die "missing $ENV_DIR/common.tfvars"
[[ -f "$ENV_DIR/chain.tfvars"  ]] || die "missing $ENV_DIR/chain.tfvars"

# -----------------------------------------------------------------------------
# Resolve the image list from Terraform rather than restating it here. A second
# copy of the list is a copy that can drift, and the whole point is to test what
# will actually be deployed.
# -----------------------------------------------------------------------------
log "resolving image references from Terraform ($ENV_NAME)"
REFS_JSON="$(
  echo 'jsonencode(local.image_ref)' \
    | terraform -chdir="$CHAIN_DIR" console \
        -var-file="$ENV_DIR/common.tfvars" \
        -var-file="$ENV_DIR/chain.tfvars" 2>/dev/null \
    | jq -r . 2>/dev/null
)" || die "could not evaluate local.image_ref -- has 'terraform init' been run in $CHAIN_DIR?"

[[ -n "$REFS_JSON" && "$REFS_JSON" != "null" ]] || die "Terraform returned no image references."

COUNT="$(jq -r 'length' <<<"$REFS_JSON")"
log "$COUNT image(s) to verify"
echo

# -----------------------------------------------------------------------------
# Prefer a real OCI client. crane and skopeo both understand digests, auth and
# multi-arch indexes; the curl path is a fallback and only handles simple cases.
# -----------------------------------------------------------------------------
TOOL=""
for t in crane skopeo docker; do command -v "$t" >/dev/null && { TOOL="$t"; break; }; done
[[ -n "$TOOL" ]] || die "need one of: crane, skopeo, docker."
log "using $TOOL"

digest_of() {
  local ref="$1"
  case "$TOOL" in
    crane)
      if [[ -n "${REGISTRY_USER:-}" ]]; then
        crane auth login "${ref%%/*}" -u "$REGISTRY_USER" -p "${REGISTRY_PASS:-}" >/dev/null 2>&1 || true
      fi
      crane digest "$ref" 2>/dev/null
      ;;
    skopeo)
      local creds=()
      [[ -n "${REGISTRY_USER:-}" ]] && creds=(--creds "$REGISTRY_USER:${REGISTRY_PASS:-}")
      skopeo inspect "${creds[@]}" "docker://$ref" 2>/dev/null | jq -r '.Digest // empty'
      ;;
    docker)
      docker manifest inspect -v "$ref" 2>/dev/null | jq -r '(.Descriptor.digest // .descriptor.digest) // empty'
      ;;
  esac
}

PASS=0; FAIL=0
declare -a RESOLVED=()

while IFS=$'\t' read -r name ref; do
  if d="$(digest_of "$ref")" && [[ -n "$d" ]]; then
    ok "$(printf '%-11s %s' "$name" "$ref")"
    printf '                  digest %s\n' "$d"
    RESOLVED+=("    $name = { ... , digest = \"$d\" }")
    PASS=$((PASS + 1))
  else
    bad "$(printf '%-11s %s' "$name" "$ref")"
    printf '                  NOT PULLABLE. In the real VPC this is a HANG, not an error.\n' >&2
    FAIL=$((FAIL + 1))
  fi
done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$REFS_JSON")

echo
log "verified: $PASS pulled, $FAIL failed"

if (( FAIL > 0 )); then
  echo
  die "$FAIL image(s) are not pullable. Mirror them into the registry before applying — a missing image is discovered as a hung pod on a cluster that is already billing."
fi

# -----------------------------------------------------------------------------
# Digest pinning (H38). Print them so they can be pasted straight into
# container_images, then set require_image_digests = true.
# -----------------------------------------------------------------------------
echo
log "digests for container_images (pin these, then set require_image_digests = true):"
printf '%s\n' "${RESOLVED[@]}"

# D-38: say the limit out loud at the point of success, not only in the header.
# An operator reading "PASS" at 2am does not scroll up 40 lines to find the caveat.
cat <<'SCOPE'

NOTE (#38): this proved the images exist at these digests and that THIS HOST can
pull them. It did NOT prove the cluster can. Under CT-5 the pull is kubelet's,
with the cloud team's node role against the repository policy -- a different
principal this script never exercises. Before the first deploy, run:

    scripts/preflight/verify-pull-canary.sh -n <our-namespace> -i <one image ref>

SCOPE

#!/bin/bash
# =============================================================================
# runner-user-data.sh — boot script for the In-VPC EC2 Runner (P6 of the manual build)
# -----------------------------------------------------------------------------
# Hand-written copy of terraform/modules/runner (user_data), minus Terraform and the
# deploy-config secret. The VPC has NO egress, so nothing is installed from the
# internet: the toolchain and this repo arrive as two S3 objects over the S3
# gateway endpoint, pushed from the laptop by scripts/runner/push-runner-bundle.sh.
# AL2023 already has aws, tar and gzip — that is the whole dependency set (D-21).
#
# Placeholders replaced by `sed` at launch (see the guide, P6):
#   __BUCKET__  the runner artefacts bucket   __REGION__  the AWS region
# =============================================================================
set -euxo pipefail

BUNDLE_S3="s3://__BUCKET__"
TOOLS_DIR=/usr/local/besu-tools
STATUS_FILE=/opt/besu-deploy/BOOTSTRAP_STATUS
mkdir -p /opt/besu-deploy "$TOOLS_DIR"

# fail LOUDLY: a runner that looks healthy with an empty /opt/besu-deploy costs an afternoon (F28)
fatal() { echo "FAILED: $1" > "$STATUS_FILE"; echo "[bootstrap] FATAL: $1"; exit 1; }

# --- toolchain: kubectl, helm, a Corretto JRE (keytool, for issue-server-cert.sh), the Tentacle
aws s3 cp "$BUNDLE_S3/tools/tools.tar.gz" /tmp/tools.tar.gz --region __REGION__ \
  || fatal "could not fetch tools.tar.gz (run push-runner-bundle.sh from the laptop, then recreate this instance)"
tar xzf /tmp/tools.tar.gz -C "$TOOLS_DIR" || fatal "tools.tar.gz is corrupt"
rm -f /tmp/tools.tar.gz

cat > /etc/profile.d/besu-tools.sh <<'PROFILE'
export JAVA_HOME=/usr/local/besu-tools/jvm
export PATH="/usr/local/besu-tools/bin:$JAVA_HOME/bin:$PATH"
PROFILE
chmod 0644 /etc/profile.d/besu-tools.sh
export JAVA_HOME="$TOOLS_DIR/jvm" PATH="$TOOLS_DIR/bin:$TOOLS_DIR/jvm/bin:$PATH"
for t in kubectl helm keytool; do
  command -v "$t" >/dev/null 2>&1 || fatal "$t missing after unpacking the bundle — rebuild it with push-runner-bundle.sh"
done

# --- source: `git archive` of the branch — committed files only, no .git
SRC=/opt/besu-deploy/sbsa_besu
mkdir -p "$SRC"
aws s3 cp "$BUNDLE_S3/source/source.tar.gz" /tmp/source.tar.gz --region __REGION__ \
  || fatal "could not fetch source.tar.gz (push it with push-runner-bundle.sh)"
tar xzf /tmp/source.tar.gz -C "$SRC" || fatal "source.tar.gz is corrupt"
rm -f /tmp/source.tar.gz
SRC_REF="$(aws s3api head-object --bucket __BUCKET__ --key source/source.tar.gz --region __REGION__ \
  --query 'Metadata."git-ref"' --output text 2>/dev/null || echo unknown)"

echo "OK: tools=$(grep -c $'\t' $TOOLS_DIR/MANIFEST.txt 2>/dev/null || echo '?') source=$SRC_REF" > "$STATUS_FILE"
echo "[bootstrap] ready. source=$SRC_REF"

#!/usr/bin/env bash
# =============================================================================
# scripts/permissioning/reload-permissions.sh
# -----------------------------------------------------------------------------
# Propagate the CURRENT besu-account-allowlist ConfigMap to the running enforcing
# nodes WITHOUT changing it (backlog C6). Use this after a `terraform apply` that
# regenerated the ConfigMap from tfvars (a ConfigMap change alone does NOT restart
# a StatefulSet, so the pods keep their old in-memory allowlist until reloaded).
#
#   scripts/permissioning/reload-permissions.sh            # PROPAGATE=restart (default, safe)
#   PROPAGATE=hot scripts/permissioning/reload-permissions.sh   # reload via ops listener (no bounce)
#
# RUN FROM the In-VPC EC2 Runner (private EKS endpoint). See _perm-lib.sh header.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_perm-lib.sh"

cm_require
log "current allowlist ($(cm_addrs | wc -l | tr -d ' ') account(s)):"
cm_addrs | sed 's/^/    /'
[ "$PROPAGATE" != "none" ] || die "PROPAGATE=none is a no-op here — pick restart or hot"
propagate
ok "reload-permissions complete (PROPAGATE=$PROPAGATE)"

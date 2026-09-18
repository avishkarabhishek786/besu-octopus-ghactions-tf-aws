#!/usr/bin/env bash
# =============================================================================
# scripts/runner/install-tentacle.sh   (run ON THE RUNNER, over SSM, as root)
# -----------------------------------------------------------------------------
# Turns the in-VPC runner into an Octopus POLLING TENTACLE WORKER that reaches
# Octopus Cloud through the bank's egress proxy — CICD_DESIGN_NOTES CD-57, the
# mechanism behind CD-55 (R-9 closed on option 1). Idempotent: re-running on a
# configured host changes nothing; `--reregister` forces a fresh registration.
#
# WHAT IT DOES, IN ORDER — and why each step is the way it is
#   0  Runs scripts/preflight/verify-egress-proxy.sh and REFUSES to continue if
#      it fails. A Tentacle registered through a proxy that decrypts TLS can
#      never connect (CD-58); find out before creating anything.
#   1  A dedicated system user. The Tentacle runs as `tentacle`, never root —
#      Octopus Cloud will execute scripts on this host (CD-62), and the blast
#      radius of that is the user it runs as.
#   2  create-instance / new-certificate / configure --noListen. Polling only:
#      no listening port, nothing inbound (CD-33's shape, kept).
#   3  POLLING-PROXY ON, WEB-REQUEST PROXY OFF. Two different settings:
#        `polling-proxy` — the Halibut channel to Octopus. Goes via the bank.
#        `proxy`         — Tentacle EXPORTS this one to every step as
#                          http_proxy/https_proxy. Enabled, it would send
#                          terraform/aws/kubectl/helm at the bank proxy instead
#                          of the VPC endpoints and the private EKS endpoint.
#      It is set to false EXPLICITLY, so nobody has to know the default.
#   4  register-worker — the ONE REST call. On Linux it ignores the polling
#      proxy (Octopus support #26246), so it gets https_proxy in ITS OWN
#      environment and nothing else on this host ever does. Registers as a
#      WORKER in a per-environment pool; the Kubernetes target is bound to that
#      pool in Octopus, which is how a hosted control plane reaches a private
#      endpoint (CD-57). Address: `polling.<instance>.octopus.app` on 443, no
#      --server-comms-port (CD-59).
#   5  Our own systemd unit (User=tentacle, no proxy variables, PATH to the S3
#      toolchain so steps find kubectl/helm/terraform/keytool). Written here
#      rather than by `Tentacle service` so the user, the environment and the
#      absence of proxy variables are all in one reviewable place.
#   6  CD-61: if TENTACLE_CERT_SECRET is set, the Tentacle's certificate is kept
#      in Secrets Manager — generated-and-exported ONCE (new-certificate
#      --export-pfx; there is no later export command), imported on this and on
#      every rebuilt host — so a recreated instance keeps its identity instead
#      of leaving a dead registration behind. Stop/start needs none of this.
#
# INPUTS (env)
#   OCTOPUS_INSTANCE        the <instance> in https://<instance>.octopus.app   (required)
#   OCTOPUS_SPACE           Octopus Space name                                 (required)
#   OCTOPUS_WORKER_POOL     worker pool, e.g. sit-ledger-workers               (required)
#   OCTOPUS_API_KEY_SECRET  Secrets Manager secret NAME holding an API key that
#                           may register workers (or OCTOPUS_API_KEY directly —
#                           discouraged; it lands in shell history)            (one required)
#   EGRESS_PROXY_HOST/PORT  default: parsed from terraform/egress-handover.auto.tfvars
#   EXPECTED_POLLING_CERT_SHA256  baseline for probe 7 (strongly recommended)
#   TENTACLE_CERT_SECRET    optional Secrets Manager secret NAME for CD-61
#   WORKER_NAME             default: <hostname>
#   TOOLS_DIR               default: /usr/local/besu-tools (the S3 bundle)
#   TENTACLE_HOME           default: /opt/octopus/tentacle-home
#   SOURCE_DIR              default: /opt/besu-deploy/sbsa_besu
#
# FLAGS   --reregister   re-run registration even if the marker exists
#         --skip-probe   skip step 0 (deploy-test convenience only; NEVER in the bank)
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# common.sh defaults AWS_REGION to af-south-1 when unset. On the runner the truth
# is the instance's own region (a us-east-1 deploy-test must not write af-south-1
# into the service unit), so remember whether the caller set it, and if not,
# take it from IMDSv2 after sourcing.
_PRESET_REGION="${AWS_REGION:-}"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
if [ -z "$_PRESET_REGION" ]; then
  _tok="$(curl -sS -m 3 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  _r="$(curl -sS -m 3 -H "X-aws-ec2-metadata-token: ${_tok}" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)"
  [ -n "$_r" ] && export AWS_REGION="$_r"
fi
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

[ "$(id -u)" -eq 0 ] || die "run as root (sudo): this creates a system user and a systemd unit."

REREGISTER=false; SKIP_PROBE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --reregister) REREGISTER=true ;;
    --skip-probe) SKIP_PROBE=true ;;
    *) die "unknown flag: $1" ;;
  esac
  shift
done

: "${TOOLS_DIR:=/usr/local/besu-tools}"
: "${TENTACLE_HOME:=/opt/octopus/tentacle-home}"
: "${SOURCE_DIR:=/opt/besu-deploy/sbsa_besu}"
: "${WORKER_NAME:=$(hostname -s)}"
: "${TENTACLE_USER:=tentacle}"
: "${TENTACLE_INSTANCE:=besu-worker}"
: "${TENTACLE_CERT_SECRET:=}"
: "${EXPECTED_POLLING_CERT_SHA256:=}"
TENTACLE="${TOOLS_DIR}/tentacle/Tentacle"
HANDOVER="${REPO_ROOT}/terraform/egress-handover.auto.tfvars"

[ -x "$TENTACLE" ] || die "Tentacle not found at ${TENTACLE}. It ships in the S3 toolchain bundle — add/keep the 'tentacle' row in runner-tools.manifest, re-run push-runner-bundle.sh, and recreate or re-bootstrap the runner."

# Proxy coordinates: env wins; otherwise the hand-over file the operator pushed
# (the runner root reads the same file for runner_private_ip — one source).
hv() { awk -F'=' -v k="$1" '$1 ~ "^[[:space:]]*"k"[[:space:]]*$" { gsub(/[[:space:]"]/, "", $2); print $2; exit }' "$HANDOVER" 2>/dev/null || true; }
: "${EGRESS_PROXY_HOST:=$(hv egress_proxy_host)}"
: "${EGRESS_PROXY_PORT:=$(hv egress_proxy_port)}"
[ -n "$EGRESS_PROXY_HOST" ] && [ -n "$EGRESS_PROXY_PORT" ] || die "EGRESS_PROXY_HOST/PORT not set and not found in ${HANDOVER}. Push egress-handover.auto.tfvars with push-deploy-config.sh, or export them."

: "${OCTOPUS_INSTANCE:?set OCTOPUS_INSTANCE}"
: "${OCTOPUS_SPACE:?set OCTOPUS_SPACE}"
: "${OCTOPUS_WORKER_POOL:?set OCTOPUS_WORKER_POOL}"
SERVER="https://${OCTOPUS_INSTANCE}.octopus.app"
POLLING="https://polling.${OCTOPUS_INSTANCE}.octopus.app"   # 443; CD-59
PROXY_URL="http://${EGRESS_PROXY_HOST}:${EGRESS_PROXY_PORT}"

need aws; need curl; need openssl; need systemctl; need jq; need base64

# -----------------------------------------------------------------------------
# 0. The egress probe. Refuse to build on a broken or decrypting path.
# -----------------------------------------------------------------------------
if [ "$SKIP_PROBE" = true ]; then
  log "WARNING: --skip-probe given; not verifying the egress path (deploy-test only)."
else
  log "step 0: verifying the egress path (verify-egress-proxy.sh)"
  EGRESS_PROXY_HOST="$EGRESS_PROXY_HOST" EGRESS_PROXY_PORT="$EGRESS_PROXY_PORT" \
  OCTOPUS_INSTANCE="$OCTOPUS_INSTANCE" EXPECTED_POLLING_CERT_SHA256="$EXPECTED_POLLING_CERT_SHA256" \
    bash "${SCRIPT_DIR}/../preflight/verify-egress-proxy.sh" \
    || die "egress probe FAILED — not registering a Tentacle that cannot connect. Fix the path (or the R-10 ticket) first."
  [ -n "$EXPECTED_POLLING_CERT_SHA256" ] || log "WARNING: no EXPECTED_POLLING_CERT_SHA256 — probe 7 could not prove the tunnel is uninspected. Compare the printed fingerprint by hand before trusting this registration."
fi

# -----------------------------------------------------------------------------
# 1. The service user, and the directories it owns.
# -----------------------------------------------------------------------------
if ! id "$TENTACLE_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$TENTACLE_HOME" --shell /sbin/nologin "$TENTACLE_USER"
  ok "created system user ${TENTACLE_USER}"
fi
mkdir -p "$TENTACLE_HOME" "$TENTACLE_HOME/applications"
chown -R "$TENTACLE_USER:$TENTACLE_USER" "$TENTACLE_HOME"
# Steps run as the tentacle user and need the source tree (terraform writes
# .terraform/ into it) and the toolchain (read/exec only).
[ -d "$SOURCE_DIR" ] && chown -R "$TENTACLE_USER:$TENTACLE_USER" "$SOURCE_DIR"
chmod -R a+rX "$TOOLS_DIR"
# B24: Tentacle on Linux keeps its INSTANCE INDEX machine-wide, under
# /etc/octopus (Tentacle/instances/<name>.config -> our tentacle.config), not
# under $HOME. `create-instance` as the unprivileged service user died with
# "Access to the path '/etc/octopus' is denied" on the first live run. The
# directory is created here, root-owned parent semantics kept, writable by the
# service user only — it holds a pointer file, no secrets.
install -d -m 0755 -o "$TENTACLE_USER" -g "$TENTACLE_USER" /etc/octopus

CONFIG="$TENTACLE_HOME/tentacle.config"
MARKER="$TENTACLE_HOME/REGISTERED"
# Every Tentacle command runs as the service user, WITH its home (-H): the
# instance index under /etc/octopus points at $CONFIG, and the systemd unit
# runs as the same user with the same HOME, so the service finds what the CLI
# created.
T=(sudo -H -u "$TENTACLE_USER" "$TENTACLE")

# -----------------------------------------------------------------------------
# 2. Instance, certificate (CD-61: restore it if we have one), polling-only.
# -----------------------------------------------------------------------------
# The INDEX is the source of truth for "instance exists", not the config file:
# a create-instance that dies on the index (B24) has already written a full
# config skeleton, so `[ -f "$CONFIG" ]` would skip this step on every re-run
# and step 3 would fail with "has not been configured on this machine".
# Checked two format-agnostic ways so a change in either does not break it.
instance_registered() {
  [ -f "/etc/octopus/Tentacle/instances/${TENTACLE_INSTANCE}.config" ] && return 0
  "${T[@]}" list-instances 2>/dev/null | grep -q "${TENTACLE_INSTANCE}"
}
if ! instance_registered; then
  if [ -f "$CONFIG" ]; then
    log "step 2: ${CONFIG} exists but the instance is not in Tentacle's index — residue of a failed create-instance; removing it"
    rm -f "$CONFIG"
  fi
  log "step 2: creating Tentacle instance ${TENTACLE_INSTANCE}"
  "${T[@]}" create-instance --instance "$TENTACLE_INSTANCE" --config "$CONFIG" --home "$TENTACLE_HOME"

  # The certificate IS the worker's identity (Octopus pins its thumbprint).
  # There is no export command; a certificate can only be exported at the
  # moment it is generated (new-certificate --export-pfx), so CD-61 works like
  # this: generate-and-export once, keep the PFX + password in Secrets Manager,
  # import on this and every rebuilt host. Without TENTACLE_CERT_SECRET the
  # identity lives and dies with the instance (stop/start still keeps it).
  if [ -n "$TENTACLE_CERT_SECRET" ]; then
    stored="$(sm_get "$TENTACLE_CERT_SECRET")"
    pfx="$(mktemp)"; chmod 600 "$pfx"; chown "$TENTACLE_USER" "$pfx"
    if [ -n "$stored" ] && [ "$stored" != "None" ]; then
      pw="$(printf '%s' "$stored" | jq -r .password)"
      printf '%s' "$stored" | jq -r .pfx_b64 | base64 -d > "$pfx"
      "${T[@]}" import-certificate --instance "$TENTACLE_INSTANCE" --from-file "$pfx" --pfx-password "$pw"
      ok "imported the Tentacle certificate from ${TENTACLE_CERT_SECRET} — a rebuilt host keeps its registered identity (CD-61)"
    else
      pw="$(openssl rand -hex 24)"
      "${T[@]}" new-certificate --instance "$TENTACLE_INSTANCE" --export-pfx "$pfx" --pfx-password "$pw"
      "${T[@]}" import-certificate --instance "$TENTACLE_INSTANCE" --from-file "$pfx" --pfx-password "$pw"
      sm_put "$TENTACLE_CERT_SECRET" "$(jq -cn --arg p "$pw" --arg b "$(base64 -w0 "$pfx")" '{password:$p, pfx_b64:$b}')"
      ok "generated the Tentacle certificate and stored it in ${TENTACLE_CERT_SECRET} (CD-61)"
    fi
    rm -f "$pfx"; unset pw stored
  else
    "${T[@]}" new-certificate --instance "$TENTACLE_INSTANCE" --if-blank
    log "no TENTACLE_CERT_SECRET: the identity is not backed up — a recreated instance will need --reregister under a new thumbprint (CD-61 fallback not enabled)"
  fi
  "${T[@]}" configure --instance "$TENTACLE_INSTANCE" --noListen True --reset-trust --app "$TENTACLE_HOME/applications"
  ok "instance created: polling only, no listening port"
else
  log "step 2: instance ${TENTACLE_INSTANCE} is registered (${CONFIG}) — keeping it"
fi

# -----------------------------------------------------------------------------
# 3. Proxies: polling ON (via the bank), web-request OFF (steps talk to VPC
#    endpoints and the private EKS endpoint directly). Idempotent by nature.
# -----------------------------------------------------------------------------
log "step 3: polling-proxy -> ${PROXY_URL}; web-request proxy -> OFF (CD-57)"
"${T[@]}" polling-proxy --instance "$TENTACLE_INSTANCE" --proxyEnable=true --proxyHost="$EGRESS_PROXY_HOST" --proxyPort="$EGRESS_PROXY_PORT"
"${T[@]}" proxy         --instance "$TENTACLE_INSTANCE" --proxyEnable=false

# -----------------------------------------------------------------------------
# 4. Register as a worker. The API key comes from Secrets Manager and is used
#    once, in this process; the polling channel authenticates by certificate.
# -----------------------------------------------------------------------------
if [ -f "$MARKER" ] && [ "$REREGISTER" = false ]; then
  log "step 4: already registered ($(cat "$MARKER")) — pass --reregister to redo"
else
  if [ -z "${OCTOPUS_API_KEY:-}" ]; then
    : "${OCTOPUS_API_KEY_SECRET:?set OCTOPUS_API_KEY_SECRET (or OCTOPUS_API_KEY)}"
    OCTOPUS_API_KEY="$(sm_get "$OCTOPUS_API_KEY_SECRET")"
    [ -n "$OCTOPUS_API_KEY" ] && [ "$OCTOPUS_API_KEY" != "None" ] || die "no API key in ${OCTOPUS_API_KEY_SECRET}"
  fi
  log "step 4: register-worker '${WORKER_NAME}' -> ${SERVER} (space ${OCTOPUS_SPACE}, pool ${OCTOPUS_WORKER_POOL}), comms ${POLLING}"
  # https_proxy is scoped to THIS command only — the one REST call that needs it.
  sudo -H -u "$TENTACLE_USER" env https_proxy="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" \
    "$TENTACLE" register-worker --instance "$TENTACLE_INSTANCE" \
      --server "$SERVER" --server-comms-address "$POLLING" --comms-style TentacleActive \
      --apiKey "$OCTOPUS_API_KEY" --space "$OCTOPUS_SPACE" \
      --name "$WORKER_NAME" --workerpool "$OCTOPUS_WORKER_POOL" --force \
    || die "register-worker failed. Check: the API key's permissions, the Space/pool names, and that BOTH hostnames are allowlisted (probe 2 and 3)."
  unset OCTOPUS_API_KEY
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${WORKER_NAME} -> ${SERVER} pool=${OCTOPUS_WORKER_POOL}" > "$MARKER"
  ok "registered"
fi

# -----------------------------------------------------------------------------
# 5. The service. Ours, not `Tentacle service`: the user, the PATH and the
#    deliberate ABSENCE of proxy variables are reviewable in one file.
# -----------------------------------------------------------------------------
ICU_ENV=""
ldconfig -p 2>/dev/null | grep -q libicu || ICU_ENV="Environment=DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1"
cat > /etc/systemd/system/tentacle.service <<UNIT
# Octopus polling Tentacle worker (sbsa_besu runner) — written by install-tentacle.sh.
# No http_proxy/https_proxy here ON PURPOSE (CD-57): only the Halibut channel is
# proxied, via the Tentacle's own polling-proxy setting.
[Unit]
Description=Octopus Tentacle worker (${TENTACLE_INSTANCE})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TENTACLE_USER}
Group=${TENTACLE_USER}
WorkingDirectory=${TENTACLE_HOME}
Environment=HOME=${TENTACLE_HOME}
Environment=JAVA_HOME=${TOOLS_DIR}/jvm
Environment=PATH=${TOOLS_DIR}/bin:${TOOLS_DIR}/jvm/bin:/usr/local/bin:/usr/bin:/bin
Environment=AWS_REGION=${AWS_REGION}
${ICU_ENV}
ExecStart=${TENTACLE} run --instance=${TENTACLE_INSTANCE} --noninteractive
Restart=always
RestartSec=5
KillSignal=SIGINT
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now tentacle.service
sleep 3
systemctl is-active --quiet tentacle.service || die "tentacle.service is not active — journalctl -u tentacle.service"
ok "tentacle.service running as ${TENTACLE_USER}; polling ${POLLING} via ${PROXY_URL}"
log "In Octopus: Infrastructure -> Workers -> ${WORKER_NAME} should go healthy within a minute. Bind the Kubernetes target to pool ${OCTOPUS_WORKER_POOL}."

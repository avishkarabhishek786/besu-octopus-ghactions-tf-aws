#!/bin/bash
# =============================================================================
# proxy-user-data.sh — boot script for the egress proxy EC2 (P3 of the manual build)
# -----------------------------------------------------------------------------
# Hand-written copy of mimic_egress/terraform/modules/proxy (user_data + squid.conf.tftpl).
# The proxy mimics the bank's shared egress: an EXPLICIT Squid forward proxy that
# allows CONNECT to 443 only, from the runner's /32 only, to the two Octopus
# hostnames only. No TLS interception (no ssl_bump) — Octopus rejects an
# interrupted tunnel (CD-58).
#
# Placeholders replaced by `sed` at launch (see the guide, P3):
#   __OCTO__       Octopus Cloud instance name (<instance>.octopus.app)
#   __RUNNER_IP__  the runner's pinned private IP
# This VPC has an internet gateway (the bank's edge), so `dnf install` is fine here.
# =============================================================================
set -euo pipefail
STATUS=/var/lib/egress-proxy/BOOTSTRAP_STATUS
mkdir -p /var/lib/egress-proxy
fatal() { echo "FAILED: $1" > "$STATUS"; echo "[proxy-bootstrap] FATAL: $1"; exit 1; }

dnf install -y -q squid || fatal "dnf install squid failed (no internet route from the egress subnet?)"

cat > /etc/squid/squid.conf <<'SQUID'
http_port 3128
visible_hostname sbsa-besu-sit-egress-proxy

acl runner   src       __RUNNER_IP__/32
acl octopus  dstdomain __OCTO__.octopus.app
acl octopus  dstdomain polling.__OCTO__.octopus.app
acl SSL_ports port     443
acl CONNECT  method    CONNECT

# first match wins
http_access deny  CONNECT !SSL_ports
http_access deny  !CONNECT
http_access allow runner octopus
http_access deny  all

# tunnels only: nothing cached, nothing added to what the client sends
cache deny all
via off
forwarded_for delete

access_log daemon:/var/log/squid/access.log squid
cache_log  /var/log/squid/cache.log
coredump_dir /var/spool/squid
shutdown_lifetime 3 seconds
SQUID

# a bad ACL must fail loudly, not leave Squid up on its (much wider) default config
squid -k parse || fatal "squid.conf failed to parse — see /var/log/squid/cache.log"
systemctl enable --now squid || fatal "squid failed to start"
sleep 2
systemctl is-active --quiet squid || fatal "squid is not active after start"
echo "OK: squid listening on 3128; source=__RUNNER_IP__/32; destinations=__OCTO__.octopus.app,polling.__OCTO__.octopus.app" > "$STATUS"

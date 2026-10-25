#!/usr/bin/env bash
set -euo pipefail
# Puppet's exec path is /usr/bin:/bin; restorecon lives in /usr/sbin. The
# 'command not found' only surfaced once a real promotion ran after it was added.
export PATH="/usr/sbin:/usr/bin:/bin:${PATH}"
rsync -a --delete --exclude='.services-checksum' /etc/caddy/conf.d.openvox-staging/ /etc/caddy/conf.d/
cp /etc/caddy/Caddyfile.openvox-staging /etc/caddy/Caddyfile
chown -R caddy:caddy /etc/caddy/conf.d /etc/caddy/Caddyfile
# A root-run validate can leave root-owned log files that caddy then cannot open.
chown -R caddy:caddy /var/log/caddy
# Files created before the httpd_log_t fcontext rule existed keep var_log_t,
# which httpd_t (caddy) may not open on a fresh host.
restorecon -R /var/log/caddy /etc/caddy
if ! systemctl reload caddy 2>/dev/null; then
  systemctl status caddy.service --no-pager || true
  journalctl -xeu caddy.service -n 50 --no-pager || true
  echo "FAILED: caddy did not reload after config promotion" >&2
  exit 1
fi
echo "Caddy config promoted and reloaded"

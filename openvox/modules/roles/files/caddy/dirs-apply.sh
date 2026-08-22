#!/usr/bin/env bash
set -euo pipefail
install -d -m 0755 -o caddy -g caddy /opt/caddy /opt/caddy/site /etc/caddy/conf.d
install -d -m 2755 -o caddy -g caddy /var/log/caddy
setfacl -R -m u:caddy:rwx,m:rwx /var/log/caddy
setfacl -R -d -m u:caddy:rwx,m:rwx /var/log/caddy
chown -R caddy:caddy /var/log/caddy
echo "caddy directories created/fixed"

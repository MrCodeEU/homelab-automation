#!/usr/bin/env bash
# Installs the custom Caddy build (CrowdSec bouncer + AppSec, built by
# .github/workflows/caddy-build.yml) from its GitHub release. The SHA-256 comes
# from hiera, so a changed or tampered release asset is refused, not installed.
# Env: CADDY_CUSTOM_BIN (destination), CADDY_CUSTOM_TAG, CADDY_CUSTOM_SHA256,
# CADDY_CUSTOM_ZITI (true: the build must have the ziti transport).
set -euo pipefail
bin=${CADDY_CUSTOM_BIN:?}
tag=${CADDY_CUSTOM_TAG:?}
want=${CADDY_CUSTOM_SHA256:?}
ziti=${CADDY_CUSTOM_ZITI:-false}
repo=MrCodeEU/homelab-automation

tmp=$(mktemp -d /var/tmp/caddy-custom.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

# 5xx from github.com can last minutes (2026-11-08): retry for up to 2 min.
curl -fsSL --retry 5 --retry-delay 15 --retry-max-time 120 --max-time 300 -o "$tmp/caddy" \
  "https://github.com/${repo}/releases/download/${tag}/caddy-linux-amd64"
got=$(sha256sum "$tmp/caddy" | cut -d' ' -f1)
if [ "$got" != "$want" ]; then
  echo "FAILED: checksum mismatch for ${tag}: got ${got}, hiera pins ${want}" >&2
  exit 1
fi
chmod 755 "$tmp/caddy"
# Refuse a binary that cannot run here or lacks the plugins.
"$tmp/caddy" version >/dev/null
modules=$("$tmp/caddy" list-modules)
grep -qx http.handlers.appsec <<<"$modules"
if [ "$ziti" = true ]; then
  grep -qx http.reverse_proxy.transport.ziti <<<"$modules"
fi

install -m 755 -o root -g root "$tmp/caddy" "${bin}.new"
mv -f "${bin}.new" "$bin"
# Same type as the packaged /usr/bin/caddy, so systemd starts it as httpd_t.
semanage fcontext -a -t httpd_exec_t "$bin" 2>/dev/null || \
  semanage fcontext -m -t httpd_exec_t "$bin"
restorecon -v "$bin"
echo "installed custom caddy ${tag} at ${bin}"

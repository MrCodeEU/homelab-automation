#!/usr/bin/env bash
# Install the opkssh client on this laptop (docs/ZERO_TRUST_PLAN.md C14):
# the pinned release binary to ~/.local/bin and a client config that signs
# in at Authelia. No root, no rpm-ostree layering.
#
#   scripts/opkssh-laptop.sh
#   opkssh login              # browser: Authelia, two factors
#   ssh root@nuc              # the short-lived key in ~/.ssh/id_ecdsa
#
# Version and digest must match roles::opkssh.
set -euo pipefail

VERSION=v0.19.2
SHA256=e799b780d5477e8d986a2e6784773ebb2451d860dd842d23e271baf88aee2da3
BIN="$HOME/.local/bin/opkssh"
CFG="$HOME/.opk/config.yml"

if [ "$(sha256sum "$BIN" 2>/dev/null | cut -d' ' -f1)" != "$SHA256" ]; then
  t=$(mktemp)
  trap 'rm -f "$t"' EXIT
  curl -fsSL -o "$t" "https://github.com/openpubkey/opkssh/releases/download/$VERSION/opkssh-linux-amd64"
  echo "$SHA256  $t" | sha256sum -c --quiet
  install -D -m 0755 "$t" "$BIN"
  echo "installed $BIN ($VERSION)"
fi

install -d -m 0700 "$HOME/.opk"
umask 077
cat >| "$CFG" <<'YAML'
# Written by scripts/opkssh-laptop.sh
---
default_provider: authelia
providers:
  - alias: authelia
    issuer: https://auth.mljr.eu
    client_id: opkssh
    scopes: openid email profile
    redirect_uris:
      - http://localhost:3000/login-callback
      - http://localhost:10001/login-callback
      - http://localhost:11110/login-callback
YAML
echo "wrote $CFG; next: opkssh login"

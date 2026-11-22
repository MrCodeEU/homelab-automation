#!/usr/bin/env bash
# Exits 0 (no work needed) if nas has the same ziti-tcp-proxy binary as nuc.
set -euo pipefail
TARGET="nas-mgmt"
SRC=/usr/local/libexec/ziti-tcp-proxy/ziti-tcp-proxy
DEST=/mnt/user/appdata/homelab/ziti-tcp-proxy/ziti-tcp-proxy

want=$(sha256sum "$SRC" | cut -d' ' -f1)
have=$(ssh -o BatchMode=yes "$TARGET" "sha256sum $DEST 2>/dev/null | cut -d' ' -f1")
[ "$want" = "$have" ]

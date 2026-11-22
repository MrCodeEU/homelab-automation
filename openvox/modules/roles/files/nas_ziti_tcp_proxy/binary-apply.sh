#!/usr/bin/env bash
# Copies nuc's ziti-tcp-proxy binary to nas, then restarts the sidecars
# there that run it (label homelab.ziti-tcp-proxy): a running container
# keeps executing the binary it started with.
set -euo pipefail
TARGET="nas-mgmt"
SRC=/usr/local/libexec/ziti-tcp-proxy/ziti-tcp-proxy
DIR=/mnt/user/appdata/homelab/ziti-tcp-proxy

ssh -o BatchMode=yes "$TARGET" "install -d -m 0755 $DIR"
scp -q -o BatchMode=yes "$SRC" "$TARGET:$DIR/ziti-tcp-proxy.new"
ssh -o BatchMode=yes "$TARGET" "set -e
  chmod 0755 $DIR/ziti-tcp-proxy.new
  mv $DIR/ziti-tcp-proxy.new $DIR/ziti-tcp-proxy
  docker ps -q --filter label=homelab.ziti-tcp-proxy=true | xargs -r docker restart"
echo "installed ziti-tcp-proxy on nas"

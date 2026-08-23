#!/usr/bin/env bash
# Updates node_exporter on wd-mycloud to the latest stable release.
# Logic port of ansible/roles/wd-mycloud-node-exporter (already validated
# live via migration/spot's own wd-mycloud-node-exporter.yml) - same
# device paths, same download/checksum/swap/restart sequence.
#
# Unlike roles::wd_mycloud_proxy's tailscale update, this can run
# synchronously in one `ssh ... bash -s` session: node_exporter is not
# the SSH transport, so killing and restarting it mid-script does not
# tear down the connection running the script. No nohup/disown/poll
# dance needed.
set -euo pipefail
TARGET="root@wd-mycloud.tail33930.ts.net"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" bash -s <<'REMOTE'
set -e
BASE=/mnt/HD/HD_a2/node_exporter
PORT=9100

LATEST_JSON=$(curl -fsSL https://api.github.com/repos/prometheus/node_exporter/releases/latest)
LATEST_VERSION=$(echo "$LATEST_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'].lstrip('v'))")
ASSET_INFO=$(echo "$LATEST_JSON" | python3 -c "
import json,sys
data = json.load(sys.stdin)
for a in data['assets']:
    if a['name'].endswith('linux-armv7.tar.gz'):
        print(a['name'])
        print(a['browser_download_url'])
        print(a['digest'])
        break
")
LATEST_TARBALL=$(echo "$ASSET_INFO" | sed -n '1p')
LATEST_URL=$(echo "$ASSET_INFO" | sed -n '2p')
LATEST_DIGEST=$(echo "$ASSET_INFO" | sed -n '3p' | sed 's/^sha256://')

mkdir -p "$BASE/releases"
NEWDIR="$BASE/releases/node_exporter-${LATEST_VERSION}.linux-armv7"
if [ ! -d "$NEWDIR" ]; then
  curl -fsSL "$LATEST_URL" -o "/tmp/$LATEST_TARBALL"
  # No sha256sum applet on this busybox build (confirmed live 2026-08-19 -
  # only md5sum/sha3sum exist) - python3 is already relied on above for
  # JSON parsing, so use its hashlib instead.
  ACTUAL_SHA=$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "/tmp/$LATEST_TARBALL")
  if [ "$ACTUAL_SHA" != "$LATEST_DIGEST" ]; then
    echo "checksum mismatch for $LATEST_TARBALL: got $ACTUAL_SHA, expected $LATEST_DIGEST - refusing to extract" >&2
    rm -f "/tmp/$LATEST_TARBALL"
    exit 1
  fi
  tar xzf "/tmp/$LATEST_TARBALL" -C "$BASE/releases"
  rm -f "/tmp/$LATEST_TARBALL"
fi

pkill -f "node_exporter --web.listen-address" || true
sleep 2
ln -sfn "$NEWDIR" "$BASE/current"
cd "$BASE/current"
nohup ./node_exporter --web.listen-address=100.100.10.5:$PORT >>"$BASE/node_exporter.log" 2>&1 &
disown

for d in "$BASE"/releases/*/; do
  d="${d%/}"
  [ "$d" = "$NEWDIR" ] || rm -rf "$d"
done

echo "node_exporter updated to $LATEST_VERSION"
REMOTE

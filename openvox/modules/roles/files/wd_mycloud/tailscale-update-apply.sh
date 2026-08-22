#!/usr/bin/env bash
# Updates tailscale on wd-mycloud to the latest stable release. Logic port
# of spot/playbooks/wd-mycloud-tailscale.yml's "update tailscale binary"
# command (migration/spot, already validated live in production) - same
# device paths, same kill/swap/restart sequence, same best-effort
# reconnect if the update itself fails partway through.
#
# Real bug found and fixed live (2026-08-22): the update kills tailscaled,
# which is what provides Tailscale SSH on this device in the first place -
# so a naive `ssh ... bash -s <<REMOTE ... REMOTE` running the whole
# sequence in one foreground session gets its own transport torn down
# mid-script the instant `pkill tailscaled` runs. The remote script
# actually keeps running to completion in that case (confirmed live: the
# device ended up correctly updated and healthy), but the local ssh
# client sees "Connection closed by remote host" / exit 255 and reports a
# false failure. Fixed by having the remote side background its own
# entire body with nohup+disown and return immediately (one short-lived
# connection that completes before pkill runs), then polling with fresh
# connections afterward - exactly the shape Ansible's own per-task
# separate-connection model got "for free" and a single persistent
# session does not.
set -euo pipefail
TARGET="root@wd-mycloud.tail33930.ts.net"
BASE="/mnt/HD/HD_a2/tailscale"

LATEST_JSON=$(curl -s "https://pkgs.tailscale.com/stable/?mode=json")
LATEST_VERSION=$(echo "$LATEST_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['TarballsVersion'])")
LATEST_TARBALL=$(echo "$LATEST_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['Tarballs']['arm'])")

ssh -o BatchMode=yes "$TARGET" bash -s -- "$LATEST_VERSION" "$LATEST_TARBALL" <<'REMOTE'
export LATEST_VERSION="$1"
export LATEST_TARBALL="$2"
export BASE=/mnt/HD/HD_a2/tailscale

nohup bash -c '
set -e
NEWDIR="$BASE/releases/tailscale_${LATEST_VERSION}_arm"

mkdir -p "$BASE/releases"
if [ ! -d "$NEWDIR" ]; then
  curl -sL -o "$BASE/$LATEST_TARBALL" "https://pkgs.tailscale.com/stable/$LATEST_TARBALL"
  tar xzf "$BASE/$LATEST_TARBALL" -C "$BASE/releases"
  rm -f "$BASE/$LATEST_TARBALL"
fi

pkill -f "tailscaled --statedir" || true
sleep 3
ln -sfn "$NEWDIR" "$BASE/current"
cd "$BASE/current"
nohup ./tailscaled --statedir="$BASE/tailscale_lib" >>"$BASE/tailscaled.log" 2>&1 &
disown
sleep 4

if ! ./tailscale up --hostname=wd-mycloud --accept-dns=false --ssh; then
  sleep 2
  ./tailscale up --hostname=wd-mycloud --accept-dns=false --ssh || true
fi

for d in "$BASE"/releases/*/; do
  d="${d%/}"
  [ "$d" = "$NEWDIR" ] || rm -rf "$d"
done
' >>"$BASE/update.log" 2>&1 &
disown
echo "update backgrounded, will reconnect once tailscaled restarts"
REMOTE

# The command above returns as soon as the remote background job is
# launched, before pkill runs - now poll fresh connections until the
# device is back and confirmed on the target version.
for i in $(seq 1 24); do
  sleep 5
  CURRENT=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$TARGET" \
    "[ -x $BASE/current/tailscale ] && $BASE/current/tailscale version | head -1 || echo none" 2>/dev/null || echo unreachable)
  if [ "$CURRENT" = "$LATEST_VERSION" ]; then
    echo "tailscale updated to $LATEST_VERSION, device reachable"
    exit 0
  fi
done

echo "timed out waiting for wd-mycloud to come back on $LATEST_VERSION (last seen: ${CURRENT:-unknown}) - check manually" >&2
exit 1

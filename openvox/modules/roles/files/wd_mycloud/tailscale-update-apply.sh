#!/usr/bin/env bash
# Updates tailscale on wd-mycloud to the latest stable release. Logic port
# of spot/playbooks/wd-mycloud-tailscale.yml's "update tailscale binary"
# command (migration/spot, already validated live in production) - same
# device paths, same kill/swap/restart sequence, same best-effort
# reconnect if the update itself fails partway through.
#
# Real bug found live (2026-08-22, thought fixed; recurred and actually
# diagnosed 2026-09-17): the update kills tailscaled, which is what
# provides Tailscale SSH on this device in the first place. The first fix
# attempt backgrounded the remote payload with nohup+disown so the *shell
# session* tearing down wouldn't take it with it - that part works. What
# doesn't survive is the payload's *process ancestry*: it was spawned by
# `tailscaled be-child ssh ...`, i.e. tailscaled is its literal parent, not
# just its terminal. nohup/disown only protect against SIGHUP from a
# departing shell; they do nothing when the parent process itself is the
# one being killed and tears down its own child tree on shutdown - which
# is exactly what happened live on 2026-09-17 (confirmed via
# tailscaled.log: pkill logged, "shutting down" logged, then nothing -
# current symlink never swapped, tailscaled never restarted, device
# stayed dark until manually recovered over the device's own LAN sshd).
#
# Fix: don't background the restart under this SSH session's process tree
# at all. Write it to a script on the persistent data partition and have
# BusyBox `crond` (a real system daemon, not a tailscaled child - `at`
# isn't available on this device) fire it within the next minute via a
# self-removing crontab entry. crond's process tree is completely
# independent of tailscaled, so killing tailscaled can't touch it.
set -euo pipefail
TARGET="root@wd-mycloud.tail33930.ts.net"
BASE="/mnt/HD/HD_a2/tailscale"

LATEST_JSON=$(curl -s "https://pkgs.tailscale.com/stable/?mode=json")
LATEST_VERSION=$(echo "$LATEST_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['TarballsVersion'])")
LATEST_TARBALL=$(echo "$LATEST_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['Tarballs']['arm'])")

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" bash -s -- "$LATEST_VERSION" "$LATEST_TARBALL" <<'REMOTE'
export LATEST_VERSION="$1"
export LATEST_TARBALL="$2"
export BASE=/mnt/HD/HD_a2/tailscale
NEWDIR="$BASE/releases/tailscale_${LATEST_VERSION}_arm"

mkdir -p "$BASE/releases"
if [ ! -d "$NEWDIR" ]; then
  curl -sL -o "$BASE/$LATEST_TARBALL" "https://pkgs.tailscale.com/stable/$LATEST_TARBALL"
  tar xzf "$BASE/$LATEST_TARBALL" -C "$BASE/releases"
  rm -f "$BASE/$LATEST_TARBALL"
fi

# The swap+restart itself must NOT run as a child of this SSH session -
# this session IS tailscaled (Tailscale SSH), and it's about to kill
# tailscaled. A cron one-shot runs under crond instead, which has no
# relation to tailscaled and survives it being killed. Self-removes from
# crontab as its last step so it fires exactly once.
# Keep the release current is about to move away from too - a one-step
# rollback (swap $BASE/current back to it by hand) if the new one turns
# out bad, without keeping every old release around forever.
OLDDIR="$(readlink -f "$BASE/current" 2>/dev/null || true)"

cat > "$BASE/restart-oneshot.sh" <<EOF
#!/bin/sh
set -e
pkill -f "tailscaled --statedir" || true
sleep 3
ln -sfn "$NEWDIR" "$BASE/current"
cd "$BASE/current"
nohup ./tailscaled --statedir="$BASE/tailscale_lib" >>"$BASE/tailscaled.log" 2>&1 &
sleep 4
if ! ./tailscale up --hostname=wd-mycloud --accept-dns=false --ssh; then
  sleep 2
  ./tailscale up --hostname=wd-mycloud --accept-dns=false --ssh || true
fi
for d in "$BASE"/releases/*/; do
  d="\${d%/}"
  [ "\$d" = "$NEWDIR" ] || [ "\$d" = "$OLDDIR" ] || rm -rf "\$d"
done
crontab -l 2>/dev/null | grep -v restart-oneshot.sh | crontab -
EOF
chmod +x "$BASE/restart-oneshot.sh"
(crontab -l 2>/dev/null; echo "* * * * * $BASE/restart-oneshot.sh >>$BASE/update.log 2>&1") | crontab -
echo "restart scheduled via crond, will reconnect once tailscaled restarts"
REMOTE

# The command above returns as soon as the cron job is scheduled, before
# it fires - now poll fresh connections until the device is back and
# confirmed on the target version.
for _ in $(seq 1 24); do
  sleep 5
  CURRENT=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "$TARGET" \
    "[ -x $BASE/current/tailscale ] && $BASE/current/tailscale version | head -1 || echo none" 2>/dev/null || echo unreachable)
  if [ "$CURRENT" = "$LATEST_VERSION" ]; then
    echo "tailscale updated to $LATEST_VERSION, device reachable"
    exit 0
  fi
done

echo "timed out waiting for wd-mycloud to come back on $LATEST_VERSION (last seen: ${CURRENT:-unknown}) - check manually" >&2
exit 1

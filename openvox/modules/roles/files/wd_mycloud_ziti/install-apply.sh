#!/usr/bin/env bash
# Installs the pinned ziti-edge-tunnel release ($1, zip sha256 $2) on
# wd-mycloud (docs/ZERO_TRUST_PLAN.md C7: the armv7 build runs unmodified,
# v1.20.0 rechecked 2026-11-22) and restarts it when it was running.
#
# Two device traps: /tmp is noexec, and the zip does not keep the exec
# bit - so download, unpack and chmod on the data partition. No sha256sum
# applet in this busybox; python3's hashlib instead (same as node_exporter).
#
# The restart is detached (nohup) from this SSH session: once SSH to the
# device runs over Ziti, killing the tunneler drops the connection running
# this script. Unlike the Tailscale update, sshd (not the tunneler) is the
# session's parent, so a nohup'd child survives it.
set -euo pipefail
TARGET="root@wd-mycloud.tail33930.ts.net"
VERSION="$1"
SHA256="$2"
URL="https://github.com/openziti/ziti-tunnel-sdk-c/releases/download/${VERSION}/ziti-edge-tunnel-Linux_arm.zip"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" bash -s -- "$VERSION" "$SHA256" "$URL" <<'REMOTE'
set -e
VERSION="$1"
SHA256="$2"
URL="$3"
BASE=/mnt/HD/HD_a2/ziti
NEWDIR="$BASE/releases/$VERSION"
mkdir -p "$BASE/releases" "$BASE/identity"
chmod 0700 "$BASE/identity"
if [ ! -x "$NEWDIR/ziti-edge-tunnel" ]; then
  TMP="$BASE/.download"
  rm -rf "$TMP"
  mkdir -p "$TMP"
  curl -fsSL "$URL" -o "$TMP/z.zip"
  ACTUAL=$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$TMP/z.zip")
  if [ "$ACTUAL" != "$SHA256" ]; then
    echo "checksum mismatch for $URL: got $ACTUAL, expected $SHA256 - refusing to install" >&2
    rm -rf "$TMP"
    exit 1
  fi
  unzip -o -q "$TMP/z.zip" -d "$TMP"
  chmod 0755 "$TMP/ziti-edge-tunnel"
  rm -rf "$NEWDIR"
  mkdir -p "$NEWDIR"
  mv "$TMP/ziti-edge-tunnel" "$NEWDIR/"
  rm -rf "$TMP"
fi
"$NEWDIR/ziti-edge-tunnel" version
OLDDIR="$(readlink -f "$BASE/current" 2>/dev/null || true)"
ln -sfn "$NEWDIR" "$BASE/current"
# Keep the previous release for a one-step rollback, drop the rest.
for d in "$BASE"/releases/*/; do
  d="${d%/}"
  [ "$d" = "$NEWDIR" ] || [ "$d" = "$OLDDIR" ] || rm -rf "$d"
done
if pgrep -f "ziti-edge-tunnel run-host" >/dev/null 2>&1; then
  nohup sh -c "sleep 2; pkill -f 'ziti-edge-tunnel run-host'; sleep 3; sh $BASE/watchdog.sh" </dev/null >/dev/null 2>&1 &
  echo "ziti-edge-tunnel $VERSION installed, restart scheduled"
else
  echo "ziti-edge-tunnel $VERSION installed"
fi
REMOTE

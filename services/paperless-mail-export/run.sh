#!/usr/bin/env bash
# Export new mail attachments from mail-archiver, then push the outbox into
# paperless' consume dir on nas. Called by the systemd units:
#   run.sh incremental     daily
#   run.sh sweep           weekly, and by hand for the first full backfill
#
# The two steps are decoupled on purpose: the exporter marks files as done as
# soon as they are in the outbox, and the rsync step moves whatever is there,
# so a failed push is simply retried by the next run.
set -uo pipefail

MODE="${1:-incremental}"
SERVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTBOX=/var/lib/paperless-mail-export/outbox
TARGET="root@nas.tail33930.ts.net:/mnt/user/appdata/paperless/consume/"

exec 9>/var/lock/paperless-mail-export.lock
flock -n 9 || { echo "another run holds the lock, exiting"; exit 0; }

notify() {
  curl -s -X POST "https://ntfy.mljr.eu/backup" \
    -H "Title: paperless mail export" -H "Priority: high" -H "Tags: warning,email" \
    -d "$1" >/dev/null 2>&1 || true
}

cd "$SERVICE_DIR" || exit 1
rc=0

docker compose run --rm paperless-mail-export --mode "$MODE" || rc=$?

# Push even after a partial export failure: whatever reached the outbox is
# valid. .dl-* are in-flight downloads of a run that is no longer active.
rsync -rt --remove-source-files --chown=1000:1000 --chmod=D755,F644 \
  --exclude '.dl-*' "$OUTBOX/" "$TARGET" || { rc=$?; echo "rsync to nas failed"; }
find "$OUTBOX" -mindepth 1 -type d -empty -delete 2>/dev/null || true

if [ "$rc" -ne 0 ]; then
  notify "paperless mail export ($MODE) failed with exit $rc on $(hostname); see journalctl -u homelab-paperless-mail-export-$MODE"
fi
exit "$rc"

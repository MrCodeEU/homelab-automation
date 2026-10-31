#!/usr/bin/env bash
# Build the exporter image and install its systemd timers. Nothing runs at
# deploy time; the first full backfill is started by hand:
#   systemctl start homelab-paperless-mail-export-sweep
set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_ROOT=/var/lib/paperless-mail-export

cd "$SERVICE_DIR"
chmod +x run.sh

echo "==> building exporter image"
docker compose build paperless-mail-export

# uid 10001 matches the unprivileged user in the Dockerfile.
install -d -o 10001 -g 10001 -m 0755 "$STATE_ROOT" "$STATE_ROOT/state" "$STATE_ROOT/outbox"

# unit <mode> <description> <OnCalendar>; the mode (incremental|sweep) is also
# the unit name suffix and the argument run.sh receives.
unit() {
  local name="homelab-paperless-mail-export-$1"
  cat > "/etc/systemd/system/${name}.service" <<UNIT
[Unit]
Description=$2
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${SERVICE_DIR}/run.sh $1
# A full sweep is rate limited to ~100 requests/min; the first backfill of
# every mail takes hours.
TimeoutStartSec=12h
UNIT
  cat > "/etc/systemd/system/${name}.timer" <<TIMER
[Unit]
Description=$2 (timer)

[Timer]
OnCalendar=$3
RandomizedDelaySec=5min
# Catch up after the host was down at the scheduled time.
Persistent=true

[Install]
WantedBy=timers.target
TIMER
}

# After the 03:00 TutaBridge export and its mail-archiver import.
unit incremental "Export new mail attachments to paperless" "*-*-* 04:30:00"
unit sweep "Full sweep of mail attachments for paperless" "Sun *-*-* 05:30:00"

systemctl daemon-reload
systemctl enable --now homelab-paperless-mail-export-incremental.timer homelab-paperless-mail-export-sweep.timer
systemctl list-timers 'homelab-paperless-mail-export-*' --no-pager || true

#!/usr/bin/env bash
# Build the report image and install the systemd timer that runs it.
#
# The container is one-shot and lives behind the "cron" compose profile, so
# nothing starts at deploy time. systemd (not an in-container scheduler) owns
# the schedule, which gives Persistent=true catch-up after downtime and
# matches roles/backup and roles/homepage-data-sync.
set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_NAME="homelab-healthreport"
SCHEDULE="${HEALTHREPORT_SCHEDULE:-*-*-* 06:00:00}"

cd "$SERVICE_DIR"

echo "==> building health report image"
docker compose build healthreport

# Owned by the ansible role; created here too so a manual `docker compose run`
# works on a host that has not had a full play run yet. uid 10001 matches the
# unprivileged user in the Dockerfile.
install -d -o 10001 -g 10001 -m 0755 /var/lib/healthreport/state
install -d -o 10001 -g 10001 -m 0700 /var/lib/healthreport/ssh

cat > /etc/systemd/system/${UNIT_NAME}.service <<EOF
[Unit]
Description=Homelab daily health report
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${SERVICE_DIR}
# The compose default command is --noop, so --send must be explicit here.
# `run --rm` gives a fresh transient container instead of restarting the
# deploy-time one.
ExecStart=/usr/bin/docker compose run --rm healthreport --send
TimeoutStartSec=1800
EOF

cat > /etc/systemd/system/${UNIT_NAME}.timer <<EOF
[Unit]
Description=Daily homelab health report

[Timer]
OnCalendar=${SCHEDULE}
RandomizedDelaySec=5min
# Catch up after the host was down at the scheduled time.
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ${UNIT_NAME}.timer

echo "==> ${UNIT_NAME}.timer active; next run:"
systemctl list-timers ${UNIT_NAME}.timer --no-pager || true

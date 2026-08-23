#!/usr/bin/env bash
# HIGH-RISK, should not fire under normal operation - see
# roles::tutabridge_cli's own class doc. Only runs when
# /opt/tutabridge/.first-login-done is absent. $TUTA_EMAIL/$TUTA_PASSWORD
# come from the calling exec's own `environment => [...]`, never as argv
# (would otherwise appear in `ps`).
set -euo pipefail
MARKER=/opt/tutabridge/.first-login-done
command -v expect >/dev/null 2>&1 || dnf install -y expect
XDG_RUNTIME_DIR=/run/user/0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus \
  expect -c '
    set timeout 3600
    spawn /opt/tutabridge/tutabridge-cli backup /data/tuta-export
    expect "Tuta email address:"
    send "$env(TUTA_EMAIL)\r"
    expect -re {Password for.*:}
    send "$env(TUTA_PASSWORD)\r"
    expect eof
  '
touch "$MARKER"
chmod 600 "$MARKER"
echo "completed TutaBridge first login and initial backup"

#!/usr/bin/env bash
# HIGH-RISK, should not fire under normal operation - see
# roles::tutabridge_cli's own class doc. Only runs when
# /opt/tutabridge/.first-login-done is absent. $TUTA_EMAIL/$TUTA_PASSWORD
# come from the calling exec's own `environment => [...]`, never as argv
# (would otherwise appear in `ps`).
set -euo pipefail
MARKER=/opt/tutabridge/.first-login-done
command -v expect >/dev/null 2>&1 || dnf install -y expect
# The Expect program must receive its own $variables literally.
#
# Alternation, not two sequential `expect`s: confirmed live 2026-09-20
# that whether the email prompt appears at all depends on prior state -
# tutabridge-cli skipped straight to "Password for <email>:" once an
# earlier (even failed) run had already cached the account, so a plain
# `expect "Tuta email address:"` then blocked forever waiting for text
# that was never going to print, hanging the whole Puppet run until
# manually killed. Handling both shapes here means this doesn't care
# which one shows up.
# shellcheck disable=SC2016
XDG_RUNTIME_DIR=/run/user/0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus \
  expect -c '
    set timeout 3600
    spawn /opt/tutabridge/tutabridge-cli backup /data/tuta-export
    expect {
      "Tuta email address:" {
        send "$env(TUTA_EMAIL)\r"
        exp_continue
      }
      -re {Password for.*:} {
        send "$env(TUTA_PASSWORD)\r"
      }
    }
    expect eof
  '
touch "$MARKER"
chmod 600 "$MARKER"
echo "completed TutaBridge first login and initial backup"

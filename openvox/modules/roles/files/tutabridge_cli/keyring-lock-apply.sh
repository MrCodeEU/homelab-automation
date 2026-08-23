#!/usr/bin/env bash
set -euo pipefail
echo "WARNING: the TutaBridge login keyring is locked - resetting and forcing re-login" >&2
systemctl stop gnome-keyring-daemon.service
rm -f /root/.local/share/keyrings/login.keyring /root/.local/share/keyrings/user.keystore
rm -f /opt/tutabridge/.first-login-done
systemctl start gnome-keyring-daemon.service
echo "reset the locked TutaBridge keyring"

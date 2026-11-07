#!/bin/bash
# Managed by OpenVox (roles::opkssh). Compiles and loads opkssh's SELinux
# module, the same way opkssh's install-linux.sh does: newer policies run
# AuthorizedKeysCommand in sshd_session_t, older ones in sshd_t, so the
# sshd_session_t variant is tried first and the original is the fallback.
set -euo pipefail
te=/usr/local/libexec/opkssh/opkssh.te
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
build() {
  checkmodule -M -m -o "$tmp/opkssh.mod" "$1" >/dev/null &&
    semodule_package -o "$tmp/opkssh.pp" -m "$tmp/opkssh.mod" &&
    semodule -i "$tmp/opkssh.pp"
}
sed 's/sshd_t/sshd_session_t/g' "$te" > "$tmp/session.te"
if build "$tmp/session.te" 2>/dev/null; then
  echo "opkssh SELinux module loaded (sshd_session_t)"
else
  build "$te"
  echo "opkssh SELinux module loaded (sshd_t)"
fi

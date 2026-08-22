#!/usr/bin/env bash
set -euo pipefail
semanage fcontext -a -t httpd_log_t "/var/log/caddy(/.*)?" 2>/dev/null || true
restorecon -Rv /var/log/caddy >/dev/null
if ! semodule -l | grep -qx caddy_logrotate; then
  dnf install -y checkpolicy policycoreutils-python-utils
  cat > /tmp/caddy_logrotate.te <<'TEEOF'
module caddy_logrotate 1.0;

require {
  type httpd_t;
  type httpd_log_t;
  class dir { add_name remove_name search write };
  class file { create getattr open read rename setattr unlink write };
}

allow httpd_t httpd_log_t:dir { add_name remove_name search write };
allow httpd_t httpd_log_t:file { create getattr open read rename setattr unlink write };
TEEOF
  checkmodule -M -m -o /tmp/caddy_logrotate.mod /tmp/caddy_logrotate.te
  semodule_package -o /tmp/caddy_logrotate.pp -m /tmp/caddy_logrotate.mod
  semodule -i /tmp/caddy_logrotate.pp
fi
echo "SELinux policy/context applied"

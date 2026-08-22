# Live production mail server (mljr only). Port of ansible/roles/mailcow,
# cross-checked against migration/spot's own mailcow.yml
# (spot/playbooks/mailcow.yml, commit 5478d5a) - already fully deployed
# and applied to this exact host on 2026-08-21, so this port reproduces
# ITS logic (proven against the real running mail server), not a fresh
# re-derivation from the Ansible source alone.
#
# DELIBERATE BEHAVIOR CHANGE #1 (already user-approved 2026-08-21, carried
# over from spot's port): the Ansible role's own
# mailcow_run_update_on_deploy: true default runs `update.sh --force`
# (pulls new images, restarts the whole mail stack, up to 30 min) on
# EVERY deploy, on top of the role's own separate weekly systemd timer
# that already does this on a schedule. This port drops the on-deploy
# update entirely - only the weekly timer (Sun 04:00) runs updates. A
# real apply of this class never risks an unplanned mail-stack
# restart just from an unrelated config change elsewhere.
#
# DELIBERATE BEHAVIOR CHANGE #2 (already fixed in production
# 2026-08-21, real bug, see below): HTTP_PORT is 8092, not the 8081
# still sitting in ansible/inventory/group_vars/all/all.yml as of this
# port (2026-08-22) - that value drifted out of sync with the role's own
# defaults/main.yml (which was corrected to 8092) and was never fixed in
# all.yml. 8081 collides with mailcow's own hardcoded internal rspamd
# dynmaps nginx vhost regardless of what HTTP_PORT is set to, confirmed
# live 2026-08-14 (rspamd settings-map fetches silently redirected to
# HTTPS, watchdog reported bogus low scores). Not proxied by Caddy either
# way (Caddy only ever references HTTPS_PORT 8443) - isolated to
# mailcow's own internal listener used for the health check.
#
# Heredoc note: cert-sync.sh/update.sh's own content is real shell full
# of bash $ variables that must NOT be Puppet-interpolated - unlike
# authelia/base's heredocs, these use an UNQUOTED tag (@(TAG), no
# quotes) rather than a quoted one. Puppet's heredoc interpolation is
# controlled by whether the tag is quoted, not by the escapes flags
# alone (confirmed by reading heredoc_support.rb/lexer2.rb directly,
# after the authelia port's opposite assumption caused a real bug):
# quoted tag = interpolated (dqstring-style); UNQUOTED tag = fully
# literal, zero interpolation, zero escaping needed for embedded $.
class roles::mailcow (
  String $install_path     = '/opt/mailcow-dockerized',
  String $hostname         = 'mail.mljr.eu',
  String $timezone         = 'Europe/Vienna',
  String $http_port        = '8092',
  String $http_bind        = '127.0.0.1',
  String $https_port       = '8443',
  String $skip_clamd       = 'y',
  String $caddy_data_dir   = '/var/lib/caddy/.local/share/caddy',
) {
  $work_dir = '/usr/local/libexec/openvox-mailcow'

  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/mailcow',
  }

  Exec {
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
  }

  # git/curl are already ensured present by roles::base on every rocky
  # host - not re-declared here to avoid a duplicate-resource conflict.
  stdlib::ensure_packages(['git', 'curl'], { 'ensure' => 'installed' })

  file { $install_path:
    ensure => directory,
    mode   => '0755',
  }

  exec { 'mailcow-clone':
    command => "${work_dir}/clone-apply.sh",
    unless  => "${work_dir}/clone-check.sh",
    timeout => 300,
    require => [File[$install_path], Package['git']],
  }

  exec { 'mailcow-pull-fresh':
    command     => "${work_dir}/pull-fresh-apply.sh",
    timeout     => 600,
    refreshonly => true,
    subscribe   => Exec['mailcow-clone'],
  }

  exec { 'mailcow-genconf':
    command     => "${work_dir}/genconf-apply.sh",
    unless      => "${work_dir}/genconf-check.sh",
    environment => ["MAILCOW_HOSTNAME=${hostname}", "MAILCOW_TIMEZONE=${timezone}"],
    require     => Exec['mailcow-clone'],
  }

  exec { 'mailcow-secrets-sanity':
    command => "${work_dir}/secrets-sanity-check.sh",
    unless  => 'false',
    require => Exec['mailcow-genconf'],
  }

  $conf_env = [
    "MAILCOW_HTTP_PORT=${http_port}",
    "MAILCOW_HTTP_BIND=${http_bind}",
    "MAILCOW_HTTPS_PORT=${https_port}",
    "MAILCOW_SKIP_CLAMD=${skip_clamd}",
  ]

  exec { 'mailcow-reverse-proxy-conf':
    command     => "${work_dir}/reverse-proxy-conf-apply.sh",
    unless      => "${work_dir}/reverse-proxy-conf-check.sh",
    environment => $conf_env,
    require     => Exec['mailcow-genconf'],
    notify      => Exec['mailcow-services-up'],
  }

  exec { 'mailcow-env-sync':
    command => "${work_dir}/env-sync-apply.sh",
    unless  => "${work_dir}/env-sync-check.sh",
    require => Exec['mailcow-reverse-proxy-conf'],
    notify  => Exec['mailcow-services-up'],
  }

  file { "${install_path}/docker-compose.override.yml":
    ensure  => file,
    mode    => '0644',
    content => "# Mailcow Docker Compose Override\n# Managed by OpenVox - do not edit manually\n#\n# Note: Port configuration is handled via mailcow.conf:\n#   HTTP_PORT=${http_port}, HTTP_BIND=${http_bind}\n#   HTTPS_PORT=${https_port}, HTTPS_BIND=${http_bind}\n\nservices:\n  nginx-mailcow:\n    environment:\n      - SKIP_LETS_ENCRYPT=y\n      - SKIP_HTTP_VERIFICATION=y\n      - ADDITIONAL_SERVER_NAMES=${hostname}\n",
    require => Exec['mailcow-clone'],
    notify  => Exec['mailcow-services-up'],
  }

  file { '/usr/local/bin/mailcow-cert-sync.sh':
    ensure  => file,
    mode    => '0755',
    content => @(CERTSYNC),
      #!/bin/bash
      # Sync Caddy's Let's Encrypt certificates to mailcow
      # Ensures SMTP/IMAP services present publicly-trusted certificates
      # Managed by OpenVox - do not edit manually

      set -euo pipefail

      CADDY_DATA_DIR="/var/lib/caddy/.local/share/caddy"
      DOMAIN="mail.mljr.eu"
      MAILCOW_SSL_DIR="/opt/mailcow-dockerized/data/assets/ssl"
      MAILCOW_DIR="/opt/mailcow-dockerized"
      CERT_SEARCH_DIR="$CADDY_DATA_DIR/certificates"

      if [[ ! -d "$CERT_SEARCH_DIR" ]]; then
          echo "WARNING: Caddy certificates directory does not exist: ${CERT_SEARCH_DIR}"
          echo "Caddy may not have obtained certs yet. Will retry on next timer run."
          exit 0
      fi

      CADDY_CERT=$(find "$CERT_SEARCH_DIR" -path "*/${DOMAIN}/${DOMAIN}.crt" -type f | head -1)
      CADDY_KEY=$(find "$CERT_SEARCH_DIR" -path "*/${DOMAIN}/${DOMAIN}.key" -type f | head -1)

      if [[ -z "$CADDY_CERT" ]] || [[ -z "$CADDY_KEY" ]]; then
          echo "WARNING: Caddy certificates not found for ${DOMAIN}"
          echo "Caddy may not have obtained certs yet. Will retry on next timer run."
          exit 0
      fi

      mkdir -p "$MAILCOW_SSL_DIR"

      MAILCOW_CERT="${MAILCOW_SSL_DIR}/cert.pem"
      MAILCOW_KEY="${MAILCOW_SSL_DIR}/key.pem"

      if diff -q "$CADDY_CERT" "$MAILCOW_CERT" &>/dev/null && diff -q "$CADDY_KEY" "$MAILCOW_KEY" &>/dev/null; then
          echo "Certificates unchanged, nothing to do"
          exit 0
      fi

      echo "Certificates changed, syncing..."
      install -m 644 "$CADDY_CERT" "$MAILCOW_CERT"
      install -m 600 "$CADDY_KEY" "$MAILCOW_KEY"

      echo "Restarting postfix and dovecot..."
      cd "$MAILCOW_DIR"
      if docker compose restart postfix-mailcow dovecot-mailcow; then
          echo "Certificate sync complete"
      else
          echo "ERROR: Container restart failed. Removing synced certs to force retry on next run." >&2
          rm -f "$MAILCOW_CERT" "$MAILCOW_KEY"
          exit 1
      fi
      | CERTSYNC
  }

  file { '/etc/systemd/system/mailcow-cert-sync.service':
    ensure  => file,
    mode    => '0644',
    content => "# Managed by OpenVox - do not edit manually\n[Unit]\nDescription=Sync Caddy Let's Encrypt certificates to mailcow\nRequires=docker.service\nAfter=docker.service network-online.target\n\n[Service]\nType=oneshot\nWorkingDirectory=${install_path}\nExecStart=/usr/local/bin/mailcow-cert-sync.sh\n",
    notify  => Exec['mailcow-systemd-reload'],
  }

  file { '/etc/systemd/system/mailcow-cert-sync.timer':
    ensure  => file,
    mode    => '0644',
    content => "# Managed by OpenVox - do not edit manually\n[Unit]\nDescription=Sync Caddy certificates to mailcow twice daily\n\n[Timer]\nOnCalendar=*-*-* 03,15:00:00\nRandomizedDelaySec=3600\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n",
    notify  => Exec['mailcow-systemd-reload'],
  }

  file { '/usr/local/bin/mailcow-update.sh':
    ensure  => file,
    mode    => '0755',
    content => @(UPDATESH),
      #!/bin/bash
      # Automated mailcow update using the official update.sh script
      # Managed by OpenVox - do not edit manually

      set -euo pipefail

      MAILCOW_DIR="/opt/mailcow-dockerized"
      LOG_FILE="/var/log/mailcow-update.log"

      cd "$MAILCOW_DIR"

      if ./update.sh --check 2>"$LOG_FILE"; then
          echo "Updates available, running update..." | tee -a "$LOG_FILE"
          ./update.sh --force 2>&1 | tee -a "$LOG_FILE"
          echo "Mailcow update complete" | tee -a "$LOG_FILE"
      else
          echo "Mailcow is already up to date"
      fi
      | UPDATESH
  }

  file { '/etc/systemd/system/mailcow-update.service':
    ensure  => file,
    mode    => '0644',
    content => "# Managed by OpenVox - do not edit manually\n[Unit]\nDescription=Automated mailcow update\nRequires=docker.service\nAfter=docker.service network-online.target\n\n[Service]\nType=oneshot\nWorkingDirectory=${install_path}\nExecStart=/usr/local/bin/mailcow-update.sh\nTimeoutStartSec=1800\nStandardOutput=journal\nStandardError=journal\nSyslogIdentifier=mailcow-update\n",
    notify  => Exec['mailcow-systemd-reload'],
  }

  file { '/etc/systemd/system/mailcow-update.timer':
    ensure  => file,
    mode    => '0644',
    content => "# Managed by OpenVox - do not edit manually\n[Unit]\nDescription=Weekly mailcow update check\n\n[Timer]\nOnCalendar=Sun *-*-* 04:00:00\nRandomizedDelaySec=3600\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n",
    notify  => Exec['mailcow-systemd-reload'],
  }

  exec { 'mailcow-systemd-reload':
    command     => 'systemctl daemon-reload',
    refreshonly => true,
  }

  service { 'mailcow-cert-sync.timer':
    ensure  => running,
    enable  => true,
    require => [
      File['/etc/systemd/system/mailcow-cert-sync.service'],
      File['/etc/systemd/system/mailcow-cert-sync.timer'],
    ],
  }

  service { 'mailcow-update.timer':
    ensure  => running,
    enable  => true,
    require => [
      File['/etc/systemd/system/mailcow-update.service'],
      File['/etc/systemd/system/mailcow-update.timer'],
    ],
  }

  $dockerhub_user = lookup('vault_dockerhub_username', { 'default_value' => '' })
  $dockerhub_pass = Sensitive(lookup('vault_dockerhub_token', { 'default_value' => '' }))

  exec { 'mailcow-dockerhub-login':
    command     => "${work_dir}/dockerhub-login-apply.sh",
    environment => ["DOCKERHUB_USER=${dockerhub_user}", "DOCKERHUB_PASS=${dockerhub_pass.unwrap}"],
    logoutput   => false,
    require     => Exec['mailcow-clone'],
  }

  exec { 'mailcow-services-up':
    command => "${work_dir}/services-up-apply.sh",
    timeout => 300,
    require => [
      File["${install_path}/docker-compose.override.yml"],
      Exec['mailcow-env-sync'],
      Exec['mailcow-dockerhub-login'],
    ],
  }

  exec { 'mailcow-cert-sync-initial':
    command => "${work_dir}/cert-sync-initial-apply.sh",
    require => [Exec['mailcow-services-up'], File['/usr/local/bin/mailcow-cert-sync.sh']],
  }

  exec { 'mailcow-health-check':
    command     => "${work_dir}/health-check-apply.sh",
    environment => ["MAILCOW_HTTP_PORT=${http_port}"],
    require     => Exec['mailcow-cert-sync-initial'],
  }
}

# Host-local backup role - rclone to pCloud (primary) plus best-effort
# on-prem (ugreen) and semi-offsite push-only (WD MyCloud) legs. Logic-
# ported from ansible/roles/backup; no already-applied spot reference
# exists for this role (spot only ported backup-remote-key and
# backup-dashboard, not the host-local backup role itself), so this was
# derived directly from the Ansible role per the user's standing
# instruction to treat ansible/ as the source of truth.
#
# Scope decisions vs. the Ansible role (both deliberate, both discussed
# with the user as part of this port):
#   - ntfy push notifications are not ported: secrets.ntfy is not
#     currently defined in the vault either, so Ansible's own
#     send_notification() already falls back to log-only on every real
#     host today. Wiring a second notification channel with zero live
#     config to validate against isn't worth the added surface; the
#     log-only path here matches current production behavior exactly.
#   - The Docker-volume auto-detect task (`detected_volumes`) is dropped:
#     in the Ansible role it only ever feeds one cosmetic debug line, it
#     never drives which volumes actually get backed up (that's always
#     backup_host_service_configs), so it has no behavioral effect to
#     preserve.
#   - "auto-restore on fresh install" is not ported: both hosts this role
#     targets (mljr, nuc) are long-running and already carry
#     .homelab-initialized, so that branch is dead code on every real
#     target today and isn't safely testable without staging an actual
#     fresh host. restore.sh itself is still fully deployed and callable
#     by hand for disaster recovery - see the DR runbook - only the
#     automatic trigger-on-first-boot path is out of scope here.
#   - The backup-to-ugreen SSH keypair (ansible/roles/backup-remote-key)
#     is not re-generated here - it already exists on disk on every real
#     target (Ansible deployed it there already, `regenerate: never`) and
#     this role only ever reads it. Same reasoning as
#     roles::unraid_backup_proxy's identical note.
#
# $services selects the subset of $backup_service_configs this host
# backs up (mirrors Ansible's per-host filter over the `services` list -
# see site.pp for each host's actual set).
class roles::backup (
  Array[String] $services       = [],
  String        $local_path     = '/opt/backups',
  String        $base_path      = '/opt',
  String        $rclone_config_path = '/root/.config/rclone',
  String        $remote_name    = 'pcloud',
  # Role default in ansible/roles/backup is "homelab-backup/{{ inventory_hostname }}"
  # (per-host); real production overrides this globally in
  # ansible/inventory/group_vars/all/all.yml to one shared flat path
  # across every host - matching that live value here, not the dormant
  # role default, per the same "match reality, not the stale role
  # default" precedent as roles::mailcow's http_port.
  String        $remote_path    = 'homelab-backups',
  String        $backup_schedule = '*-*-* 03:00:00',
  String        $verification_integrity_schedule = 'Sun *-*-* 04:30:00',
  String        $verification_restore_schedule = 'Sun *-*-01..07 08:30:00',
  Boolean       $history_enabled = false,
  String        $history_remote_path = 'homelab-backups-history',
  Integer       $history_daily = 14,
  Integer       $history_weekly = 8,
  Integer       $history_monthly = 12,
  String        $ntfy_url = 'https://ntfy.mljr.eu/homelab-health',
  String        $verification_ntfy_url = 'https://ntfy.mljr.eu/homelab-health',
  Integer       $retention_days = 30,
  String        $item_timeout   = '40m',
  Integer       $transfers      = 8,
  Integer       $checkers       = 16,
  String        $bwlimit        = '',
  String        $cpu_quota      = '',
  # This is only ever used for the UGREEN_REMOTE path segment (the
  # directory backup-remote-target already authorized on ugreen for this
  # host - see ansible/roles/backup-remote-key). It must match Ansible's
  # inventory_hostname exactly ('mljr', 'nuc'), NOT the box's real OS
  # hostname: mljr's actual $facts['networking']['hostname'] is its VPS
  # provider's default ('vmi2945702'), which would silently start writing
  # the on-prem leg to a brand new, never-authorized ugreen directory
  # instead of the one Ansible has used all along. Caught by diffing this
  # role's noop-rendered backup.sh against the real deployed one before
  # ever applying for real - see the migration memory for the full story.
  String        $hostname       = $facts['networking']['hostname'],
) {

  $pcloud_token      = Sensitive(lookup('vault_pcloud_token', { 'default_value' => '' }))
  $wd_cloud_user     = Sensitive(lookup('vault_wd_cloud_user', { 'default_value' => 'admin' }))
  $wd_cloud_password = Sensitive(lookup('vault_wd_cloud_password', { 'default_value' => '' }))

  # ==========================================================================
  # Per-service backup definitions - mirrors ansible/roles/backup's
  # backup_service_configs default exactly (defaults/main.yml). Hook
  # scripts use unquoted heredocs (@(TAG), no quotes around the tag) so
  # their bash $VAR / ${VAR} reads pass through completely literally -
  # see the authelia role's commit history for why that distinction
  # matters (a quoted tag is interpolating and silently eats bare $2-style
  # tokens).
  # ==========================================================================
  $mailcow_pre_hook = @(MAILCOW_PRE)
    cd /opt/mailcow-dockerized && \
    set -a && . ./mailcow.conf && set +a && \
    mkdir -p /opt/backups/mailcow-dumps && \
    docker compose exec -T mysql-mailcow mysqldump -u"$DBUSER" -p"$DBPASS" "$DBNAME" > /opt/backups/mailcow-dumps/mailcow.sql
    | MAILCOW_PRE

  $forgejo_pre_hook = @(FORGEJO_PRE)
    mkdir -p /opt/backups/forgejo-dumps && \
    docker exec forgejo-db sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' \
      > /opt/backups/forgejo-dumps/forgejo.sql
    | FORGEJO_PRE

  $forgejo_restore_hook = @(FORGEJO_RESTORE)
    for i in $(seq 1 30); do
      docker exec forgejo-db pg_isready > /dev/null 2>&1 && break
      sleep 2
    done
    docker exec -i forgejo-db sh -c 'psql -U "$POSTGRES_USER" "$POSTGRES_DB"' \
      < /opt/backups/forgejo-dumps/forgejo.sql
    | FORGEJO_RESTORE

  $mailarchiver_pre_hook = @(MAILARCHIVER_PRE)
    mkdir -p /opt/backups/mail-archiver-dumps && \
    docker exec mail-archiver-db sh -c 'pg_dump -U mailuser MailArchiver' \
      > /opt/backups/mail-archiver-dumps/mail-archiver.sql
    | MAILARCHIVER_PRE

  $mailarchiver_restore_hook = @(MAILARCHIVER_RESTORE)
    for i in $(seq 1 30); do
      docker exec mail-archiver-db pg_isready > /dev/null 2>&1 && break
      sleep 2
    done
    docker exec -i mail-archiver-db psql -U mailuser MailArchiver \
      < /opt/backups/mail-archiver-dumps/mail-archiver.sql
    | MAILARCHIVER_RESTORE

  $umami_pre_hook = @(UMAMI_PRE)
    mkdir -p /opt/backups/umami-dumps && \
    docker exec umami-db sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' \
      > /opt/backups/umami-dumps/umami.sql
    | UMAMI_PRE

  $umami_restore_hook = @(UMAMI_RESTORE)
    for i in $(seq 1 30); do
      docker exec umami-db pg_isready > /dev/null 2>&1 && break
      sleep 2
    done
    docker exec -i umami-db sh -c 'psql -U "$POSTGRES_USER" "$POSTGRES_DB"' \
      < /opt/backups/umami-dumps/umami.sql
    | UMAMI_RESTORE

  $nocturne_pre_hook = @(NOCTURNE_PRE)
    mkdir -p /opt/backups/nocturne-dumps && \
    docker exec nocturne-postgres sh -c \
      'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' \
      > /opt/backups/nocturne-dumps/nocturne.sql
    | NOCTURNE_PRE

  $nocturne_restore_hook = @(NOCTURNE_RESTORE)
    for i in $(seq 1 30); do
      docker exec nocturne-postgres pg_isready > /dev/null 2>&1 && break
      sleep 2
    done
    docker exec -i nocturne-postgres sh -c \
      'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" "$POSTGRES_DB"' \
      < /opt/backups/nocturne-dumps/nocturne.sql
    | NOCTURNE_RESTORE

  $backup_service_configs = {
    'authelia' => {
      'paths'    => ['/opt/authelia'],
      'volumes'  => ['authelia_redis_data'],
      'critical' => true,
      'history_paths' => [{'label' => 'config', 'path' => '/opt/authelia'}],
    },
    'mailcow' => {
      'volumes'  => ['mailcowdockerized_vmail-vol-1', 'mailcowdockerized_mysql-vol-1'],
      'pre_hook' => $mailcow_pre_hook,
      'post_hook' => 'rm -rf /opt/backups/mailcow-dumps',
      'paths'    => ['/opt/backups/mailcow-dumps', '/opt/mailcow-dockerized/data'],
      'critical' => true,
      'history_paths' => [
        {'label' => 'database-dump', 'path' => '/opt/backups/mailcow-dumps'},
        {'label' => 'mailcow.conf', 'path' => '/opt/mailcow-dockerized/mailcow.conf'},
      ],
    },
    'kuma' => {
      'volumes'  => ['kuma_uptime-kuma-data'],
      'critical' => false,
    },
    'ntfy' => {
      'volumes'  => ['ntfy_ntfy-data', 'ntfy_ntfy-cache'],
      'critical' => false,
    },
    'forgejo' => {
      'volumes'           => ['forgejo-data', 'forgejo-db-data'],
      'pre_hook'          => $forgejo_pre_hook,
      'paths'             => ['/opt/backups/forgejo-dumps'],
      'post_hook'         => 'rm -rf /opt/backups/forgejo-dumps',
      'restore_post_hook' => $forgejo_restore_hook,
      'critical'          => true,
      'history_paths'     => [
        {'label' => 'database-dump', 'path' => '/opt/backups/forgejo-dumps'},
        {'label' => 'docker-compose.yml', 'path' => '/opt/forgejo/docker-compose.yml'},
        {'label' => '.env', 'path' => '/opt/forgejo/.env'},
      ],
    },
    'mail-archiver' => {
      'volumes'           => ['mail-archiver_mail-archiver-dp-keys'],
      'pre_hook'          => $mailarchiver_pre_hook,
      'paths'             => ['/opt/backups/mail-archiver-dumps'],
      'post_hook'         => 'rm -rf /opt/backups/mail-archiver-dumps',
      'restore_post_hook' => $mailarchiver_restore_hook,
      'critical'          => true,
      'history_paths'     => [
        {'label' => 'database-dump', 'path' => '/opt/backups/mail-archiver-dumps'},
        {'label' => 'service-config', 'path' => '/opt/mail-archiver'},
      ],
      'history_volumes'   => ['mail-archiver_mail-archiver-dp-keys'],
    },
    'umami' => {
      'volumes'           => ['umami_umami-db-data'],
      'pre_hook'          => $umami_pre_hook,
      'paths'             => ['/opt/backups/umami-dumps'],
      'post_hook'         => 'rm -rf /opt/backups/umami-dumps',
      'restore_post_hook' => $umami_restore_hook,
      'critical'          => false,
    },
    'grafana' => {
      'volumes'  => ['grafana-data', 'victoriametrics-data', 'loki-data'],
      'critical' => false,
    },
    'nocturne' => {
      'volumes'           => ['nocturne_nocturne-postgres-data'],
      'pre_hook'          => $nocturne_pre_hook,
      'paths'             => ['/opt/backups/nocturne-dumps'],
      'post_hook'         => 'rm -rf /opt/backups/nocturne-dumps',
      'restore_post_hook' => $nocturne_restore_hook,
      'critical'          => false,
    },
    'newsletter' => {
      'volumes'  => ['newsletter_newsletter-data'],
      'critical' => true,
      'history_paths' => [{'label' => 'service-config', 'path' => '/opt/newsletter'}],
      'history_volumes' => ['newsletter_newsletter-data'],
    },
    'goaccess' => {
      'volumes'  => ['goaccess_goaccess-data', 'goaccess_goaccess-report'],
      'critical' => false,
    },
    'crowdsec' => {
      'volumes'  => ['crowdsec-config', 'crowdsec-data', 'crowdsec-web-ui-data'],
      'critical' => false,
    },
  }

  $host_configs = $backup_service_configs.filter |$k, $v| { $k in $services }

  # backup.sh / restore.sh are rendered from real EPP templates
  # (templates/backup/{backup,restore}.sh.epp) instead of the
  # Puppet-`+`-is-arithmetic-only workaround this role used to need
  # (`[...].join('')` chains built up by hand) - EPP's own control-flow
  # tags (`<% %>`/`<%= %>`) replace what used to be `.reduce`/`.map`/
  # `.join('')` gymnastics over $host_configs, and don't collide with
  # bash's own `$VAR`/`${VAR}` syntax the way naive string interpolation
  # would, so no quoting workaround is needed there either.
  $backup_sh_content = epp('roles/backup/backup.sh.epp', {
    'host_configs'    => $host_configs,
    'remote_name'     => $remote_name,
    'remote_path'     => $remote_path,
    'local_path'      => $local_path,
    'hostname'        => $hostname,
    'retention_days'  => $retention_days,
    'item_timeout'    => $item_timeout,
    'transfers'       => $transfers,
    'checkers'        => $checkers,
    'bwlimit'         => $bwlimit,
    'history_enabled' => $history_enabled,
    'history_remote_path' => $history_remote_path,
    'history_daily'   => $history_daily,
    'history_weekly'  => $history_weekly,
    'history_monthly' => $history_monthly,
    'ntfy_url'        => $ntfy_url,
  })

  $restore_sh_content = epp('roles/backup/restore.sh.epp', {
    'host_configs' => $host_configs,
    'remote_name'  => $remote_name,
    'remote_path'  => $remote_path,
    'local_path'   => $local_path,
  })

  $verify_sh_content = epp('roles/backup/verify.sh.epp', {
    'remote_name' => $remote_name,
    'remote_path' => $remote_path,
    'local_path'  => $local_path,
    'hostname'    => $hostname,
    'ntfy_url'    => $verification_ntfy_url,
    'host_configs' => $host_configs,
  })

  # ==========================================================================
  # Filesystem layout, rclone, generated scripts, systemd timer
  # ==========================================================================
  package { 'rclone':
    ensure => installed,
  }

  file { [$local_path, "${local_path}/volumes", "${local_path}/scripts", "${local_path}/logs", "${local_path}/verification", $rclone_config_path]:
    ensure => directory,
    mode   => '0700',
  }

  $wd_cloud_block = $wd_cloud_password.unwrap ? {
    ''      => '',
    default => "\n[wd-cloud]\ntype = smb\nhost = 192.168.50.176\nuser = ${wd_cloud_user.unwrap}\npass = ${wd_cloud_password.unwrap}\n",
  }

  $rclone_conf_content = Sensitive(
    "# rclone configuration for pCloud\n# Managed by OpenVox - do not edit manually\n\n[${remote_name}]\ntype = pcloud\nhostname = eapi.pcloud.com\ntoken = ${pcloud_token.unwrap}\n\n[ugreen]\ntype = sftp\nhost = 100.100.10.4\nuser = rclone-backup\nkey_file = /opt/backup-remote/ssh/id_ed25519\nshell_type = unix\nmd5sum_command = none\nsha1sum_command = none\n${wd_cloud_block}"
  )

  file { "${rclone_config_path}/rclone.conf":
    ensure  => file,
    mode    => '0600',
    content => $rclone_conf_content,
    require => File[$rclone_config_path],
  }

  file { "${local_path}/scripts/backup.sh":
    ensure  => file,
    mode    => '0700',
    content => $backup_sh_content,
    require => File["${local_path}/scripts"],
  }

  file { "${local_path}/scripts/restore.sh":
    ensure  => file,
    mode    => '0700',
    content => $restore_sh_content,
    require => File["${local_path}/scripts"],
  }

  file { "${local_path}/scripts/verify.sh":
    ensure  => file,
    mode    => '0700',
    content => $verify_sh_content,
    require => File["${local_path}/scripts"],
  }

  file { '/etc/systemd/system/homelab-backup-verify@.service':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=Homelab backup verification (%i)\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=oneshot\nExecStart=${local_path}/scripts/verify.sh %i\nTimeoutStartSec=21600\nNice=19\nIOSchedulingClass=idle\n",
    notify  => Exec['backup-systemd-reload'],
  }

  file { '/etc/systemd/system/homelab-backup-verify-integrity.timer':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=Weekly homelab backup integrity verification\n\n[Timer]\nOnCalendar=${verification_integrity_schedule}\nPersistent=true\nRandomizedDelaySec=15min\nUnit=homelab-backup-verify@integrity.service\n\n[Install]\nWantedBy=timers.target\n",
    notify  => Exec['backup-systemd-reload'],
  }

  file { '/etc/systemd/system/homelab-backup-verify-restore.timer':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=Monthly homelab backup disposable restore verification\n\n[Timer]\nOnCalendar=${verification_restore_schedule}\nPersistent=true\nRandomizedDelaySec=15min\nUnit=homelab-backup-verify@restore.service\n\n[Install]\nWantedBy=timers.target\n",
    notify  => Exec['backup-systemd-reload'],
  }

  $cpu_quota_line = $cpu_quota ? {
    ''      => '',
    default => ['CPUQuota=', $cpu_quota, "\n"].join(''),
  }

  file { '/etc/systemd/system/homelab-backup.service':
    ensure  => file,
    mode    => '0644',
    content => ["[Unit]\nDescription=Homelab Backup Service\nAfter=network-online.target docker.service\nWants=network-online.target\n\n[Service]\nType=oneshot\nExecStart=${local_path}/scripts/backup.sh\nStandardOutput=journal\nStandardError=journal\nTimeoutStartSec=10800\nNice=19\nIOSchedulingClass=idle\n", $cpu_quota_line, "\n[Install]\nWantedBy=multi-user.target\n"].join(''),
    notify  => Exec['backup-systemd-reload'],
  }

  file { '/etc/systemd/system/homelab-backup.timer':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=Homelab Backup Timer\n\n[Timer]\nOnCalendar=${backup_schedule}\nPersistent=true\nRandomizedDelaySec=15min\nUnit=homelab-backup.service\n\n[Install]\nWantedBy=timers.target\n",
    notify  => Exec['backup-systemd-reload'],
  }

  exec { 'backup-systemd-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
  }

  service { 'homelab-backup.timer':
    ensure  => running,
    enable  => true,
    require => [File['/etc/systemd/system/homelab-backup.timer'], Exec['backup-systemd-reload']],
  }

  service { ['homelab-backup-verify-integrity.timer', 'homelab-backup-verify-restore.timer']:
    ensure  => running,
    enable  => true,
    require => [
      File['/etc/systemd/system/homelab-backup-verify-integrity.timer'],
      File['/etc/systemd/system/homelab-backup-verify-restore.timer'],
      Exec['backup-systemd-reload'],
    ],
  }

  # Fresh-install marker. `replace => false` deliberately: unlike the
  # Ansible task (which has no such guard and re-writes this file, with a
  # fresh embedded timestamp, on every single run), this only ever
  # creates it once. Functionally equivalent - the file's mere existence
  # is the only thing anything reads - and it stops a spurious diff every
  # apply on hosts that are already initialized (both real targets today).
  file { "${base_path}/.homelab-initialized":
    ensure  => file,
    mode    => '0644',
    replace => false,
    content => "# Homelab Initialization Flag\n# Host: ${hostname}\n#\n# This file indicates that the host has been initialized.\n# Delete this file to allow a manual restore workflow (see restore.sh).\n",
  }
}

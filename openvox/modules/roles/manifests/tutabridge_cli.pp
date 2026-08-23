# Port of ansible/roles/tutabridge-cli (cross-checked against its
# already-verified migration/spot port, commit fe4c53f). nuc only -
# headless Tuta mail export (TutaBridge has no IMAP/SMTP server mode
# worth using here, so this drives its own `backup` command on a
# timer) feeding mail-archiver's local-import path. Verify-and-adopt
# port, not a fresh bootstrap: confirmed live before writing this class
# that the binary, keyring passphrase, and all 4 systemd units already
# exist byte-exact/checksum-exact in production, both units
# enabled/active, and /opt/tutabridge/.first-login-done already exists
# (bootstrapped 2026-08-13).
#
# HIGH-RISK STEP, present but should not fire in normal operation: the
# "first login" exec below only runs when
# /opt/tutabridge/.first-login-done is absent - confirmed live the
# marker already exists, so this is a permanent no-op under normal
# re-applies. It drives an interactive Tuta login via `expect` (only
# safe because this account has no TOTP - a 30+ char random password is
# the only factor; if TOTP is ever added this starts failing at the
# password prompt and the login needs to go manual again). Do not
# delete /opt/tutabridge/.first-login-done to "test" this path - it
# forces a real re-authentication against the live account.
#
# Also present, also should not fire in normal operation: the
# keyring-selfheal exec (stop daemon, delete keyring files, force
# first-login marker removal, restart) - destructive if it ever DOES
# trigger unexpectedly on a false-positive lock detection. Same
# caution as the Ansible role's own rescue-block-with-fail-loudly
# design and the spot port's own header warning.
class roles::tutabridge_cli (
  Sensitive[String] $keyring_password        = Sensitive(lookup('vault_tutabridge_keyring_password')),
  Sensitive[String] $tuta_email              = Sensitive(lookup('vault_tuta_email')),
  Sensitive[String] $tuta_password           = Sensitive(lookup('vault_tuta_password')),
  String             $install_dir            = '/opt/tutabridge',
  String             $export_dir             = '/data/tuta-export',
  String             $backup_schedule        = '*-*-* 03:00:00',
  String             $mailarchiver_import_dir = '/data/tuta-import',
  # Numeric ID of the "Import Only" mail-archiver account - matches the
  # real site-specific override already live in production (the
  # Ansible default is empty/inactive until this account exists).
  String             $mailarchiver_account_id = '3',
) {
  package { ['gnome-keyring', 'libsecret']:
    ensure => installed,
  }

  # /run/user/0 (and its D-Bus session bus) only exists while an actual
  # login session for root is active without this - gnome-keyring-daemon
  # and TutaBridge both need it to persist independent of any SSH
  # session, since they're driven by systemd/timers with nobody logged
  # in. Confirmed live in the original role's own development: without
  # this, org.freedesktop.secrets silently stops being reachable
  # between runs.
  exec { 'tutabridge-lingering':
    command => '/usr/bin/loginctl enable-linger root',
    creates => '/var/lib/systemd/linger/root',
  }

  $work_dir = '/usr/local/libexec/openvox-tutabridge-cli'

  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/tutabridge_cli',
  }

  file { $install_dir:
    ensure => directory,
    mode   => '0700',
  }

  # Sensitive-wrapped so the passphrase never leaks into noop/--show_diff
  # output or logs - same precedent as roles::authelia's own config
  # files.
  file { "${install_dir}/keyring-pass":
    ensure  => file,
    mode    => '0600',
    content => $keyring_password,
    require => File[$install_dir],
  }

  exec { 'tutabridge-download':
    command => "${work_dir}/download-apply.sh",
    unless  => "${work_dir}/download-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => [File[$install_dir], File[$work_dir]],
  }

  file { $export_dir:
    ensure => directory,
    mode   => '0700',
  }

  file { '/etc/systemd/system/gnome-keyring-daemon.service':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=GNOME Keyring daemon (headless - Secret Service backend for TutaBridge)\nAfter=network.target user@0.service\nRequires=user@0.service\n\n[Service]\n# gnome-keyring-daemon forks into the background on its own (neither --login\n# nor --start block), so this is Type=oneshot + RemainAfterExit rather than\n# Type=simple - a foreground wrapper here just exits immediately and looks\n# \"failed\" to systemd while the real daemon keeps running unsupervised.\n#\n# --login alone only unlocks the persistent collection and exits; it does\n# NOT register org.freedesktop.secrets on the bus - confirmed live (TutaBridge\n# kept failing with \"Secret Service: no result found\" / \"unlock prompt was\n# dismissed\" until --start --components=secrets ran too). Both calls need the\n# SAME real, persistent D-Bus session bus - XDG_RUNTIME_DIR alone isn't\n# enough, TutaBridge's client-side Secret Service lookup needs\n# DBUS_SESSION_BUS_ADDRESS set explicitly. That bus only exists at\n# /run/user/0 with `loginctl enable-linger root` applied (see role tasks) -\n# without lingering it's torn down between SSH sessions.\nType=oneshot\nRemainAfterExit=yes\nEnvironment=XDG_RUNTIME_DIR=/run/user/0\nEnvironment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus\nExecStartPre=-/usr/bin/pkill -f gnome-keyring-daemon\nExecStartPre=/bin/sleep 1\nExecStart=/bin/sh -c 'cat ${install_dir}/keyring-pass | gnome-keyring-daemon --login'\nExecStart=/bin/sh -c 'cat ${install_dir}/keyring-pass | gnome-keyring-daemon --start --components=secrets'\n\n[Install]\nWantedBy=multi-user.target\n",
  }

  file { '/etc/systemd/system/tutabridge-backup.service':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=TutaBridge - export Tuta mail to local .eml files\nRequires=gnome-keyring-daemon.service\nAfter=gnome-keyring-daemon.service network-online.target\nWants=network-online.target\nOnSuccess=tutabridge-import.service\n\n[Service]\nType=oneshot\nEnvironment=XDG_RUNTIME_DIR=/run/user/0\nEnvironment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus\nExecStart=${install_dir}/tutabridge-cli backup ${export_dir}\n",
  }

  file { '/etc/systemd/system/tutabridge-backup.timer':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=Daily TutaBridge mail export\n\n[Timer]\nOnCalendar=${backup_schedule}\nPersistent=true\nRandomizedDelaySec=300\n\n[Install]\nWantedBy=timers.target\n",
  }

  file { $mailarchiver_import_dir:
    ensure => directory,
    mode   => '0755',
  }

  file { '/etc/systemd/system/tutabridge-import.service':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=Zip TutaBridge export and import into mail-archiver\nAfter=tutabridge-backup.service\n\n[Service]\nType=oneshot\nExecStart=/bin/sh -c ' \\\n  rm -f ${mailarchiver_import_dir}/tuta-export.zip && \\\n  cd ${export_dir} && \\\n  zip -rq ${mailarchiver_import_dir}/tuta-export.zip . && \\\n  docker compose -f /opt/mail-archiver/docker-compose.yml exec -T mail-archiver \\\n    dotnet MailArchiver.dll --import-eml \\\n    --file /data/import/tuta/tuta-export.zip \\\n    --account-id ${mailarchiver_account_id} \\\n'\n",
  }

  # Puppet's systemd service provider does not itself run
  # `daemon-reload` when a unit file changes underneath it - needs an
  # explicit subscribe like this one, same pattern already established
  # by roles::hawser_agent/roles::homepage_data_sync.
  exec { 'tutabridge-daemon-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
    subscribe   => [
      File['/etc/systemd/system/gnome-keyring-daemon.service'],
      File['/etc/systemd/system/tutabridge-backup.service'],
      File['/etc/systemd/system/tutabridge-backup.timer'],
      File['/etc/systemd/system/tutabridge-import.service'],
    ],
  }

  # ExecStartPre kills any prior gnome-keyring-daemon instance before
  # this oneshot unit re-logs-in - on a redeploy that's often an
  # already-running instance from the last run, and the kill+relogin
  # transition occasionally races a plain `service` resource's own
  # restart (seen live during the Ansible role's own development:
  # systemd itself reported both --login and --start exiting
  # 0/SUCCESS a moment after the caller reported failure). `tries`/
  # `try_sleep` absorbs that instead of chasing a non-reproducible
  # timing window - this is why the restart is a dedicated exec here
  # rather than a plain `service { subscribe => ... }` the way
  # roles::hawser_agent's own (non-flaky) service restart is.
  exec { 'tutabridge-keyring-daemon-restart':
    command     => '/usr/bin/systemctl restart gnome-keyring-daemon.service',
    refreshonly => true,
    subscribe   => [File["${install_dir}/keyring-pass"], File['/etc/systemd/system/gnome-keyring-daemon.service']],
    tries       => 3,
    try_sleep   => 3,
    require     => Exec['tutabridge-daemon-reload'],
  }

  service { 'gnome-keyring-daemon':
    ensure  => running,
    enable  => true,
    require => Exec['tutabridge-daemon-reload'],
  }

  exec { 'tutabridge-keyring-selfheal':
    command => "${work_dir}/keyring-lock-apply.sh",
    unless  => "${work_dir}/keyring-lock-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => Service['gnome-keyring-daemon'],
  }

  exec { 'tutabridge-backup-timer':
    command => '/usr/bin/systemctl enable --now tutabridge-backup.timer',
    unless  => '/usr/bin/systemctl is-enabled --quiet tutabridge-backup.timer && /usr/bin/systemctl is-active --quiet tutabridge-backup.timer',
    path    => ['/usr/bin', '/bin'],
    require => Exec['tutabridge-daemon-reload'],
  }

  exec { 'tutabridge-first-login':
    command     => "${work_dir}/first-login.sh",
    unless      => "/usr/bin/test -f ${install_dir}/.first-login-done",
    path        => ['/usr/bin', '/bin'],
    environment => ["TUTA_EMAIL=${tuta_email.unwrap}", "TUTA_PASSWORD=${tuta_password.unwrap}"],
    timeout     => 3600,
    logoutput   => on_failure,
    require     => [
      Exec['tutabridge-download'],
      Exec['tutabridge-keyring-selfheal'],
      Exec['tutabridge-backup-timer'],
    ],
  }
}

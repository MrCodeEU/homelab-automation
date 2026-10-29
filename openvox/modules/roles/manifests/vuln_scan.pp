# Nightly vulnerability scanning, imported into DefectDojo (roles::services'
# `defectdojo` service) for deduplication and triage.
#   - Trivy (from its official, pinned container) scans every running
#     container image and the host OS packages, on every host that includes
#     this class.
#   - Nuclei (likewise) scans every public hostname in the services catalog
#     from this host's internet connection, the outside view. nuc only
#     ($nuclei_enabled), the other hosts would repeat the same scan.
#
#   - Hosts that can't run a timer of their own (Unraid) are scanned from
#     here: $remote_docker_scans maps a DefectDojo product name to a
#     DOCKER_HOST (ssh://...), so Trivy runs on that host's Docker daemon
#     while the script, the timer and the import stay on this host.
#     Containers only, there is no host package scan.
#
# The scripts live under files/vuln_scan/. DefectDojo is reached over the
# tailnet at $dojo_url. Two ways to authenticate:
#   - On the DefectDojo host (nuc): the admin password from
#     /opt/defectdojo/.env, no extra secret.
#   - On every other host: a least-privilege importer account, set with
#     $dojo_user. The account is created on the DefectDojo host from
#     $importers (one name per remote host); it can import into its own
#     product and do nothing else. Its password is the same value in both
#     hosts' eyaml: vault_dojo_import_<name>_password on the DefectDojo
#     host, vault_dojo_import_password on the importing host.
#
# Parameter named $scan_schedule, not $schedule - the latter collides with
# Puppet's own `schedule` metaparameter (same gotcha as
# roles::homepage_data_sync).
class roles::vuln_scan (
  String $dojo_url,
  # Matches the DefectDojo product the reports land in.
  String $product       = $facts['networking']['hostname'],
  # Pin on purpose: a Trivy bump can change the report format. Check
  # DefectDojo's Trivy parser before raising it.
  String $trivy_image   = 'ghcr.io/aquasecurity/trivy:0.76.1',
  # After the 03:00 backups, before the 06:15 health report.
  String $scan_schedule = '*-*-* 05:00:00',
  # Pin on purpose, same reasoning as $trivy_image (the JSONL format).
  String $nuclei_image  = 'docker.io/projectdiscovery/nuclei:v3.11.1',
  # DefectDojo product for the outside view (not a host).
  String $nuclei_product  = 'public hostnames',
  Boolean $nuclei_enabled = true,
  # Network-only, so it can run in the quiet window before the backups
  # (03:00); Trivy is disk-heavy and runs after them.
  String $nuclei_schedule = '*-*-* 01:30:00',
  # DefectDojo host only: hosts that push scans here. Each gets an account
  # import-<name> and a product <name>.
  Array[String] $importers = [],
  # product name => DOCKER_HOST, e.g. { nas => 'ssh://root@nas.tail33930.ts.net' }.
  # Use the FQDN: that is the name already in root's known_hosts.
  Hash[String, String] $remote_docker_scans = {},
  # Staggered after $scan_schedule so the scans do not compete for disk.
  String $remote_scan_schedule = '*-*-* 05:30:00',
  # Importing hosts only: the account to push as (import-<host>).
  Optional[String] $dojo_user = undef,
  # DefectDojo host only: fill EPSS and CISA KEV on the findings (the Trivy
  # parser leaves them empty). After the 05:00 local and 05:30 remote scans, so
  # it sees the night's new findings; the 06:15 health report reads the result
  # the same morning.
  Boolean $enrich_enabled = false,
  String $enrich_schedule = '*-*-* 05:55:00',
) {
  $dir = '/usr/local/libexec/vuln-scan'

  # Every enabled catalog entry with a domain is publicly routed through
  # mljr's Caddy (wildcard DNS), so this is the list of what the internet
  # can reach. Derived, not hardcoded: a new service is scanned from its
  # first deploy.
  $catalog_domains = flatten(lookup('services_catalog').filter |$svc| {
    pick($svc['enabled'], true) and $svc['domain'] != undef
  }.map |$svc| { $svc['domain'] })
  $nuclei_targets = $catalog_domains.unique.sort.map |$domain| { "https://${domain}" }

  file { $dir:
    ensure  => directory,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    recurse => remote,
    purge   => true,
    source  => 'puppet:///modules/roles/vuln_scan',
  }

  $etc_dir = '/etc/vuln-scan'
  $password_file = "${etc_dir}/dojo-password"

  if $dojo_user or !$importers.empty {
    file { $etc_dir:
      ensure => directory,
      owner  => 'root',
      group  => 'root',
      mode   => '0700',
    }
  }

  # Importing host: the account's password, read by dd-import.sh.
  if $dojo_user {
    $login_env = "Environment=DOJO_USER=${dojo_user}\nEnvironment=DOJO_PASSWORD_FILE=${password_file}\n"
    $login_require = File[$password_file]
    file { $password_file:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0600',
      content => Sensitive(lookup('vault_dojo_import_password')),
      require => File[$etc_dir],
    }
  } else {
    $login_env = ''
    $login_require = []
  }

  # DefectDojo host: provision the importer accounts. The credentials file
  # and the exec are two halves of one change, hence the shared guard.
  unless $importers.empty {
    $importers_file = "${etc_dir}/importers"
    $importer_lines = $importers.map |$name| {
      "${name}:${lookup("vault_dojo_import_${name}_password")}"
    }
    file { $importers_file:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0600',
      content => Sensitive("${importer_lines.join("\n")}\n"),
      require => File[$etc_dir],
    }

    # Through bash with a readability test: on the first rollout the scripts
    # do not exist yet during --noop, and Puppet errors on a missing command
    # or an exit 127. A plain exit 1 reads as "would run".
    exec { 'dojo-importer-provision':
      command     => "/usr/bin/bash ${dir}/dojo-importer-apply.sh",
      unless      => "/usr/bin/bash -c 'test -r ${dir}/dojo-importer-check.sh && exec bash ${dir}/dojo-importer-check.sh'",
      path        => ['/usr/bin', '/bin'],
      environment => ["DOJO_URL=${dojo_url}", "IMPORTERS_FILE=${importers_file}"],
      require     => [File[$dir], File[$importers_file], Exec['services-defectdojo-healthcheck']],
    }
  }

  file { '/etc/systemd/system/trivy-scan.service':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=Trivy scan of ${product} (images + host packages) into DefectDojo\nAfter=docker.service network-online.target\nWants=network-online.target\n\n[Service]\nType=oneshot\nEnvironment=TRIVY_IMAGE=${trivy_image}\nEnvironment=DOJO_PRODUCT=${product}\nEnvironment=DOJO_URL=${dojo_url}\n${login_env}ExecStart=${dir}/trivy-scan.sh\nTimeoutStartSec=3h\nNice=19\nIOSchedulingClass=idle\nStandardOutput=journal\nStandardError=journal\n",
    require => [File[$dir], $login_require],
  }

  if $nuclei_enabled {
    file { "${dir}/nuclei-targets.txt":
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => "${nuclei_targets.join("\n")}\n",
      require => File[$dir],
    }

    file { '/etc/systemd/system/nuclei-scan.service':
      ensure  => file,
      mode    => '0644',
      content => "[Unit]\nDescription=Nuclei scan of the public hostnames into DefectDojo\nAfter=docker.service network-online.target\nWants=network-online.target\n\n[Service]\nType=oneshot\nEnvironment=NUCLEI_IMAGE=${nuclei_image}\nEnvironment=NUCLEI_TARGETS=${dir}/nuclei-targets.txt\nEnvironment=DOJO_PRODUCT=${nuclei_product}\nEnvironment=DOJO_URL=${dojo_url}\nExecStart=${dir}/nuclei-scan.sh\nTimeoutStartSec=2h\nNice=19\nIOSchedulingClass=idle\nStandardOutput=journal\nStandardError=journal\n",
      require => [File[$dir], File["${dir}/nuclei-targets.txt"]],
    }

    file { '/etc/systemd/system/nuclei-scan.timer':
      ensure  => file,
      mode    => '0644',
      content => "[Unit]\nDescription=Nightly Nuclei scan of the public hostnames\n\n[Timer]\nOnCalendar=${nuclei_schedule}\nPersistent=true\nRandomizedDelaySec=10min\nUnit=nuclei-scan.service\n\n[Install]\nWantedBy=timers.target\n",
    }
  }

  file { '/etc/systemd/system/trivy-scan.timer':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=Nightly Trivy scan of ${product}\n\n[Timer]\nOnCalendar=${scan_schedule}\nPersistent=true\nRandomizedDelaySec=10min\nUnit=trivy-scan.service\n\n[Install]\nWantedBy=timers.target\n",
  }

  # Remote daemons, scanned from this host with the admin login (this is the
  # DefectDojo host). TRIVY_SCAN_HOST=false: no host package scan.
  $remote_docker_scans.each |$name, $docker_host| {
    file { "/etc/systemd/system/trivy-scan-${name}.service":
      ensure  => file,
      mode    => '0644',
      content => "[Unit]\nDescription=Trivy scan of the containers on ${name} into DefectDojo\nAfter=docker.service network-online.target\nWants=network-online.target\n\n[Service]\nType=oneshot\nEnvironment=TRIVY_IMAGE=${trivy_image}\nEnvironment=DOJO_PRODUCT=${name}\nEnvironment=DOJO_URL=${dojo_url}\nEnvironment=DOCKER_HOST=${docker_host}\nEnvironment=TRIVY_SCAN_HOST=false\nExecStart=${dir}/trivy-scan.sh\nTimeoutStartSec=3h\nNice=19\nStandardOutput=journal\nStandardError=journal\n",
      require => File[$dir],
    }

    file { "/etc/systemd/system/trivy-scan-${name}.timer":
      ensure  => file,
      mode    => '0644',
      content => "[Unit]\nDescription=Nightly Trivy scan of the containers on ${name}\n\n[Timer]\nOnCalendar=${remote_scan_schedule}\nPersistent=true\nRandomizedDelaySec=10min\nUnit=trivy-scan-${name}.service\n\n[Install]\nWantedBy=timers.target\n",
    }

    service { "trivy-scan-${name}.timer":
      ensure    => running,
      enable    => true,
      subscribe => File["/etc/systemd/system/trivy-scan-${name}.timer"],
      require   => Exec['trivy-scan-daemon-reload'],
    }
  }

  if $enrich_enabled {
    file { '/etc/systemd/system/dd-enrich.service':
      ensure  => file,
      mode    => '0644',
      content => "[Unit]\nDescription=Fill EPSS and CISA KEV on the DefectDojo findings\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=oneshot\nEnvironment=DOJO_URL=${dojo_url}\nExecStart=/usr/bin/bash ${dir}/dd-enrich.sh\nTimeoutStartSec=1h\nNice=19\nStandardOutput=journal\nStandardError=journal\n",
      require => File[$dir],
    }

    file { '/etc/systemd/system/dd-enrich.timer':
      ensure  => file,
      mode    => '0644',
      content => "[Unit]\nDescription=Daily EPSS and CISA KEV enrichment of the DefectDojo findings\n\n[Timer]\nOnCalendar=${enrich_schedule}\nPersistent=true\nRandomizedDelaySec=5min\nUnit=dd-enrich.service\n\n[Install]\nWantedBy=timers.target\n",
    }
  }

  # Puppet's systemd service provider does not run `daemon-reload` on its
  # own when a unit file changes (same gotcha as roles::hawser_agent).
  $nuclei_units = $nuclei_enabled ? {
    true    => [
      File['/etc/systemd/system/nuclei-scan.service'],
      File['/etc/systemd/system/nuclei-scan.timer'],
    ],
    default => [],
  }
  $enrich_units = $enrich_enabled ? {
    true    => [
      File['/etc/systemd/system/dd-enrich.service'],
      File['/etc/systemd/system/dd-enrich.timer'],
    ],
    default => [],
  }
  $remote_units = $remote_docker_scans.keys.map |$name| {
    [
      File["/etc/systemd/system/trivy-scan-${name}.service"],
      File["/etc/systemd/system/trivy-scan-${name}.timer"],
    ]
  }.flatten
  exec { 'trivy-scan-daemon-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
    subscribe   => [
      File['/etc/systemd/system/trivy-scan.service'],
      File['/etc/systemd/system/trivy-scan.timer'],
    ] + $nuclei_units + $enrich_units + $remote_units,
  }

  service { 'trivy-scan.timer':
    ensure    => running,
    enable    => true,
    subscribe => File['/etc/systemd/system/trivy-scan.timer'],
    require   => Exec['trivy-scan-daemon-reload'],
  }

  if $enrich_enabled {
    service { 'dd-enrich.timer':
      ensure    => running,
      enable    => true,
      subscribe => File['/etc/systemd/system/dd-enrich.timer'],
      require   => Exec['trivy-scan-daemon-reload'],
    }
  }

  if $nuclei_enabled {
    service { 'nuclei-scan.timer':
      ensure    => running,
      enable    => true,
      subscribe => File['/etc/systemd/system/nuclei-scan.timer'],
      require   => Exec['trivy-scan-daemon-reload'],
    }
  }
}

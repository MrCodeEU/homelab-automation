# Nightly vulnerability scanning, imported into DefectDojo (roles::services'
# `defectdojo` service) for deduplication and triage. nuc only for now.
#   - Trivy (from its official, pinned container) scans every running
#     container image and the host OS packages.
#   - Nuclei (likewise) scans every public hostname in the services catalog
#     from this host's internet connection, the outside view.
#
# The scripts live under files/vuln_scan/. DefectDojo is reached over the
# tailnet at $dojo_url and authenticated with the admin password from
# /opt/defectdojo/.env, so no extra secret is provisioned.
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
  # After the 03:00 backups, before the 06:00 health report.
  String $scan_schedule = '*-*-* 05:00:00',
  # Pin on purpose, same reasoning as $trivy_image (the JSONL format).
  String $nuclei_image  = 'docker.io/projectdiscovery/nuclei:v3.11.1',
  # DefectDojo product for the outside view (not a host).
  String $nuclei_product  = 'public hostnames',
  # Network-only, so it can run in the quiet window before the backups
  # (03:00); Trivy is disk-heavy and runs after them.
  String $nuclei_schedule = '*-*-* 01:30:00',
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

  file { '/etc/systemd/system/trivy-scan.service':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=Trivy scan of ${product} (images + host packages) into DefectDojo\nAfter=docker.service network-online.target\nWants=network-online.target\n\n[Service]\nType=oneshot\nEnvironment=TRIVY_IMAGE=${trivy_image}\nEnvironment=DOJO_PRODUCT=${product}\nEnvironment=DOJO_URL=${dojo_url}\nExecStart=${dir}/trivy-scan.sh\nTimeoutStartSec=3h\nNice=19\nIOSchedulingClass=idle\nStandardOutput=journal\nStandardError=journal\n",
    require => File[$dir],
  }

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

  file { '/etc/systemd/system/trivy-scan.timer':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=Nightly Trivy scan of ${product}\n\n[Timer]\nOnCalendar=${scan_schedule}\nPersistent=true\nRandomizedDelaySec=10min\nUnit=trivy-scan.service\n\n[Install]\nWantedBy=timers.target\n",
  }

  # Puppet's systemd service provider does not run `daemon-reload` on its
  # own when a unit file changes (same gotcha as roles::hawser_agent).
  exec { 'trivy-scan-daemon-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
    subscribe   => [
      File['/etc/systemd/system/trivy-scan.service'],
      File['/etc/systemd/system/trivy-scan.timer'],
      File['/etc/systemd/system/nuclei-scan.service'],
      File['/etc/systemd/system/nuclei-scan.timer'],
    ],
  }

  service { 'trivy-scan.timer':
    ensure    => running,
    enable    => true,
    subscribe => File['/etc/systemd/system/trivy-scan.timer'],
    require   => Exec['trivy-scan-daemon-reload'],
  }

  service { 'nuclei-scan.timer':
    ensure    => running,
    enable    => true,
    subscribe => File['/etc/systemd/system/nuclei-scan.timer'],
    require   => Exec['trivy-scan-daemon-reload'],
  }
}

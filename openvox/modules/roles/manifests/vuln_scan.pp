# Nightly vulnerability scanning of this host: Trivy (run from its official,
# pinned container) scans every running container image and the host OS
# packages, and the reports are imported into DefectDojo (roles::services'
# `defectdojo` service) for deduplication and triage. nuc only for now.
#
# The scripts live under files/vuln_scan/ and are shared with the Nuclei
# scan added later. DefectDojo is reached over the tailnet at $dojo_url and
# authenticated with the admin password from /opt/defectdojo/.env, so no
# extra secret is provisioned.
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
) {
  $dir = '/usr/local/libexec/vuln-scan'

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
    ],
  }

  service { 'trivy-scan.timer':
    ensure    => running,
    enable    => true,
    subscribe => File['/etc/systemd/system/trivy-scan.timer'],
    require   => Exec['trivy-scan-daemon-reload'],
  }
}

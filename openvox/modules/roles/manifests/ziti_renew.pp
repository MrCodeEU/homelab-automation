# Renewal of this host's Ziti identity certificates (tools/cmd/ziti-renew).
# The SDK identities (caddy-mljr, the m2m proxies, kuma-nuc, ...) get a
# one-year certificate at enrolment and nothing renews it; the routers and
# the controller renew their own. A daily timer renews every identity in
# $identities with fewer than $days left, through the controller's
# certificate extension (new key, no re-enrolment, the old cert works until
# the new one is committed), then runs its restart command so the service
# loads the new file. Entries without a restart and every non-.json path
# are only watched.
#
# Every watched certificate's expiry goes to Alloy's textfile collector
# (ziti_identity_cert_expiry_timestamp_seconds); healthreport warns at 30
# days left and when a renewal failed. Renew one now:
#   ziti-renew -renew <file>
class roles::ziti_renew (
  Array[Struct[{
    file              => Pattern[/\A\/\S+\z/],
    Optional[restart] => String[1],
  }]] $identities = [],
  Integer[7, 300] $days = 60,
) {
  file { '/usr/local/bin/ziti-renew':
    ensure => file,
    mode   => '0755',
    source => 'puppet:///modules/roles/ziti_renew/ziti-renew',
  }

  file { '/etc/ziti-renew':
    ensure => directory,
    mode   => '0755',
  }

  $lines = $identities.map |$i| {
    $i['restart'] ? {
      undef   => $i['file'],
      default => "${i['file']} ${i['restart']}",
    }
  }
  file { '/etc/ziti-renew/identities.conf':
    ensure  => file,
    mode    => '0644',
    content => "# Managed by OpenVox (roles::ziti_renew). <path> [restart command]\n${lines.map |$l| { "${l}\n" }.join('')}",
  }

  # 10:40 local with up to 30 min delay: in the day, so a failed renewal is
  # seen, and clear of the nightly jobs and the Sunday maintenance window.
  # UGOS sets GODEBUG=tlskyber=0 for every unit; Go 1.24+ aborts on it.
  file { '/etc/systemd/system/ziti-renew.service':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=Renew Ziti identity certificates (roles::ziti_renew)\nWants=network-online.target\nAfter=network-online.target docker.service\n\n[Service]\nType=oneshot\nEnvironment=GODEBUG=\nExecStart=/usr/local/bin/ziti-renew -days ${days}\n",
  }

  file { '/etc/systemd/system/ziti-renew.timer':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=Daily Ziti identity renewal check (roles::ziti_renew)\n\n[Timer]\nOnCalendar=*-*-* 10:40\nRandomizedDelaySec=30m\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n",
  }

  # The service provider does not daemon-reload on its own (roles::deploy_agent).
  exec { 'ziti-renew-daemon-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
    subscribe   => File['/etc/systemd/system/ziti-renew.service', '/etc/systemd/system/ziti-renew.timer'],
  }

  # The timer's first run is up to a day away; the metrics are wanted now.
  exec { 'ziti-renew-first-run':
    command => '/usr/bin/systemctl start ziti-renew.service',
    unless  => '/usr/bin/test -s /var/lib/node-textfile/ziti_identity.prom',
    require => Service['ziti-renew.timer'],
  }

  service { 'ziti-renew.timer':
    ensure  => running,
    enable  => true,
    require => [Exec['ziti-renew-daemon-reload'], File['/usr/local/bin/ziti-renew', '/etc/ziti-renew/identities.conf']],
  }
}

# Readable ntfy messages from the OpenZiti controller's event log on mljr
# (tools/cmd/ziti-notify): enrolments, configuration changes by author,
# failed logins, and services whose circuits keep failing, with names
# instead of ids. Grafana keeps controller down / router offline / link
# down (services/grafana/provisioning/alerting/ziti.yml), which must work
# while the controller is down.
#
# Root, read-only: it reads events.log under the controller's 0700 data
# dir and only ZITI_ADMIN_PASSWORD from /opt/ziti-controller/.env, to look
# names up on the management API at 127.0.0.1:8440.
class roles::ziti_notify (
  String $ntfy_url = 'https://ntfy.mljr.eu/homelab-security',
  # No circuit-failure messages in the weekly host maintenance, when nuc and
  # mljr reboot (roles::deploy_agent maintenance_window, Kuma's and
  # Grafana's window): same slot.
  Pattern[/\A(Sun|Mon|Tue|Wed|Thu|Fri|Sat) ([01][0-9]|2[0-3]):[0-5][0-9] [1-9][0-9]*m\z/] $quiet = 'Sun 01:00 60m',
) {
  file { '/usr/local/bin/ziti-notify':
    ensure => file,
    mode   => '0755',
    source => 'puppet:///modules/roles/ziti_notify/ziti-notify',
  }

  file { '/etc/systemd/system/ziti-notify.service':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=OpenZiti event notifications to ntfy (roles::ziti_notify)\nWants=network-online.target\nAfter=network-online.target docker.service\n\n[Service]\nType=simple\nEnvironment=ZITI_NOTIFY_NTFY_URL=${ntfy_url}\nEnvironment=\"ZITI_NOTIFY_QUIET=${quiet}\"\nExecStart=/usr/local/bin/ziti-notify\nNoNewPrivileges=yes\nProtectSystem=strict\nProtectHome=yes\nPrivateTmp=yes\nCapabilityBoundingSet=CAP_DAC_READ_SEARCH\nRestart=always\nRestartSec=30\n\n[Install]\nWantedBy=multi-user.target\n",
  }

  # The service provider does not daemon-reload on its own (roles::deploy_agent).
  exec { 'ziti-notify-daemon-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
    subscribe   => File['/etc/systemd/system/ziti-notify.service'],
  }

  service { 'ziti-notify':
    ensure    => running,
    enable    => true,
    require   => Exec['ziti-notify-daemon-reload'],
    subscribe => File['/usr/local/bin/ziti-notify', '/etc/systemd/system/ziti-notify.service'],
  }
}

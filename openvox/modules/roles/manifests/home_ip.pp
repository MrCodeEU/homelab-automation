# Keeps CrowdSec's allowlist "home" on mljr current with the home
# connection's public addresses (tools/cmd/home-ip, services/crowdsec/README.md):
#   serve (nuc):  home-ip serve on 127.0.0.1:19480 answers what the FRITZ!Box
#                 reports; reachable only as Ziti service home-ip-nuc
#                 (ziti/tofu/home-ip.tf, bound by nuc's router).
#   sync  (mljr): a timer runs home-ip sync every 5 min through ziti-proxy's
#                 127.0.0.1:19480 and fixes the allowlist with cscli.
class roles::home_ip (
  Enum['serve', 'sync'] $mode,
  String $fritzbox = 'http://192.168.50.1:49000',
  String $ntfy_url = 'https://ntfy.mljr.eu/homelab-security',
) {
  file { '/usr/local/bin/home-ip':
    ensure => file,
    mode   => '0755',
    source => 'puppet:///modules/roles/home_ip/home-ip',
  }

  if $mode == 'serve' {
    $unit = 'home-ip'
    file { '/etc/systemd/system/home-ip.service':
      ensure  => file,
      mode    => '0644',
      content => "[Unit]\nDescription=Home connection addresses from the FRITZ!Box (roles::home_ip)\nWants=network-online.target\nAfter=network-online.target\n\n[Service]\nType=simple\nEnvironment=HOME_IP_LISTEN=127.0.0.1:19480\nEnvironment=HOME_IP_FRITZBOX=${fritzbox}\nExecStart=/usr/local/bin/home-ip serve\nDynamicUser=yes\nNoNewPrivileges=yes\nProtectSystem=strict\nProtectHome=yes\nPrivateTmp=yes\nRestart=always\nRestartSec=10\n\n[Install]\nWantedBy=multi-user.target\n",
    }
    $units = ['/etc/systemd/system/home-ip.service']
  } else {
    $unit = 'home-ip-sync.timer'
    # Root: cscli runs through `docker exec crowdsec`.
    file { '/etc/systemd/system/home-ip-sync.service':
      ensure  => file,
      mode    => '0644',
      content => "[Unit]\nDescription=Sync CrowdSec allowlist \"home\" (roles::home_ip)\nAfter=docker.service\n\n[Service]\nType=oneshot\nEnvironment=HOME_IP_SOURCE=http://127.0.0.1:19480/v1/home-ip\nEnvironment=HOME_IP_NTFY_URL=${ntfy_url}\nEnvironment=HOME_IP_METRICS=/var/lib/node-textfile/homelab_home_ip.prom\nExecStart=/usr/local/bin/home-ip sync\nStateDirectory=home-ip\nStateDirectoryMode=0700\n",
    }
    file { '/etc/systemd/system/home-ip-sync.timer':
      ensure  => file,
      mode    => '0644',
      content => "[Unit]\nDescription=Sync CrowdSec allowlist \"home\" every 5 minutes\n\n[Timer]\nOnBootSec=2min\nOnUnitActiveSec=5min\nUnit=home-ip-sync.service\n\n[Install]\nWantedBy=timers.target\n",
    }
    $units = ['/etc/systemd/system/home-ip-sync.service', '/etc/systemd/system/home-ip-sync.timer']
  }

  # The service provider does not daemon-reload on its own (roles::deploy_agent).
  exec { 'home-ip-daemon-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
    subscribe   => File[$units],
  }

  service { $unit:
    ensure    => running,
    enable    => true,
    require   => Exec['home-ip-daemon-reload'],
    subscribe => File['/usr/local/bin/home-ip'],
  }
}

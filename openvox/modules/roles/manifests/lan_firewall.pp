# Default-deny inbound for the hosts without firewalld (Phase 7): ugreen
# here, nas through roles::nas_lan_firewall. One chain, HOMELAB-INPUT,
# hooked into INPUT for IPv4 and IPv6 (files/lan_firewall/setup.sh); vendor
# chains (UGOS's UG_*, ts-input, Docker's) are left alone.
#
# $mode 'log' (the start, 2026-11-26) blocks nothing: allowed traffic
# returns to INPUT unchanged, other new unicast traffic gets a
# rate-limited "homelab-in: " kernel log line in Loki. After about a week
# the logs decide which ports join the lists, then 'enforce' accepts the
# lists and drops the rest.
#
# Allowed by default: loopback, established, ICMP, DHCP, $interfaces
# (container bridges reach host services, the tailnet until tailscaled is
# uninstalled), ssh 22 (LAN break-glass), the Ziti router 8442 and
# Syncthing (22000, 21027; the nas and ugreen sync over the LAN).
#
# UGOS rebuilds INPUT at boot and on firewall changes in its UI, so a
# timer reloads the chain (1 min after boot, then every 5 min) like
# roles::ugreen_ssh_loopback.
class roles::lan_firewall (
  Enum['log', 'enforce'] $mode = 'log',
  Array[Integer] $tcp_ports = [22, 8442, 22000],
  Array[Integer] $udp_ports = [22000, 21027],
  Array[String] $interfaces = ['docker0', 'br-+', 'tailscale+'],
  String $dir = '/usr/local/libexec/openvox-lan-firewall',
) {
  file { $dir:
    ensure => directory,
    mode   => '0755',
  }

  file { "${dir}/setup.sh":
    ensure => file,
    mode   => '0755',
    source => 'puppet:///modules/roles/lan_firewall/setup.sh',
  }

  ['4', '6'].each |$family| {
    file { "${dir}/rules.v${family}":
      ensure  => file,
      mode    => '0644',
      content => epp('roles/lan_firewall/rules.epp', {
        'family'     => $family,
        'mode'       => $mode,
        'tcp_ports'  => $tcp_ports,
        'udp_ports'  => $udp_ports,
        'interfaces' => $interfaces,
        'class_name' => 'roles::lan_firewall',
      }),
    }
  }

  file { '/etc/systemd/system/homelab-lan-firewall.service':
    ensure  => file,
    mode    => '0644',
    content => @("UNIT"),
      [Unit]
      Description=Load the HOMELAB-INPUT chain (roles::lan_firewall)
      After=network-online.target netfilter-persistent.service

      [Service]
      Type=oneshot
      ExecStart=${dir}/setup.sh
      | UNIT
  }

  file { '/etc/systemd/system/homelab-lan-firewall.timer':
    ensure  => file,
    mode    => '0644',
    content => @(UNIT),
      [Unit]
      Description=Re-check HOMELAB-INPUT after boot and UGOS firewall rebuilds

      [Timer]
      OnBootSec=1min
      OnUnitActiveSec=5min

      [Install]
      WantedBy=timers.target
      | UNIT
  }

  exec { 'lan-firewall-daemon-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
    subscribe   => File['/etc/systemd/system/homelab-lan-firewall.service', '/etc/systemd/system/homelab-lan-firewall.timer'],
  }

  service { 'homelab-lan-firewall.timer':
    ensure  => running,
    enable  => true,
    require => Exec['lan-firewall-daemon-reload'],
  }

  exec { 'lan-firewall':
    command => "${dir}/setup.sh",
    unless  => "${dir}/setup.sh --check",
    path    => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
    require => File["${dir}/setup.sh", "${dir}/rules.v4", "${dir}/rules.v6"],
  }
}

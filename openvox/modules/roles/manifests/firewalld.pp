# Small native firewalld layer replacing the unmaintained Forge module.
# Every resource checks both runtime and permanent state so reboots preserve
# policy without a disruptive global firewall reload.
#
# $strict_forward_ports: firewalld's StrictForwardPorts=yes. Docker's
# published ports are DNAT rules in its own iptables chains, which bypass
# firewalld's zones; with this on, firewalld drops traffic that something
# else DNAT'd unless a firewalld rule allows it, so a port published on
# 0.0.0.0 by mistake stays closed to the LAN. Off where a container must be
# reachable from outside (mljr: mailcow).
class roles::firewalld (
  Boolean $strict_forward_ports = false,
) {
  file { '/usr/local/libexec/openvox-firewalld':
    ensure => directory,
    mode   => '0755',
  }

  file { '/usr/local/libexec/openvox-firewalld/zone-sources-check.sh':
    ensure  => file,
    mode    => '0755',
    source  => 'puppet:///modules/roles/firewalld/zone-sources-check.sh',
    require => File['/usr/local/libexec/openvox-firewalld'],
  }

  file { '/usr/local/libexec/openvox-firewalld/zone-sources-apply.sh':
    ensure  => file,
    mode    => '0755',
    source  => 'puppet:///modules/roles/firewalld/zone-sources-apply.sh',
    require => File['/usr/local/libexec/openvox-firewalld'],
  }

  # Rocky 10's cloud image ships without firewalld (the EL9 one had it).
  package { 'firewalld':
    ensure => installed,
  }

  service { 'firewalld':
    ensure  => running,
    enable  => true,
    require => Package['firewalld'],
  }

  # A reload applies it (tested on nuc, firewalld 2.4.3, Docker 29.10.1:
  # Docker keeps its rules, Ziti on loopback and container egress work).
  $strict = $strict_forward_ports ? {
    true    => 'yes',
    default => 'no',
  }
  exec { 'firewalld-strict-forward-ports':
    command => "sed -i -E 's/^#?StrictForwardPorts=.*/StrictForwardPorts=${strict}/' /etc/firewalld/firewalld.conf && firewall-cmd --reload",
    unless  => "grep -qx 'StrictForwardPorts=${strict}' /etc/firewalld/firewalld.conf",
    path    => ['/usr/bin', '/bin'],
    require => Service['firewalld'],
  }
}

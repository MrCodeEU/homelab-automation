# Small native firewalld layer replacing the unmaintained Forge module.
# Every resource checks both runtime and permanent state so reboots preserve
# policy without a disruptive global firewall reload.
class roles::firewalld {
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

  service { 'firewalld':
    ensure => running,
    enable => true,
  }
}

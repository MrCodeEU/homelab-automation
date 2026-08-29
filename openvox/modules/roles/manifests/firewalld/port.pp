# Manage one runtime and persistent firewalld port.
define roles::firewalld::port (
  Pattern[/\A[A-Za-z0-9_-]+\z/] $zone,
  Integer $port,
  Enum['tcp', 'udp'] $protocol,
  Enum['present', 'absent'] $ensure = 'present',
) {
  $spec = "${port}/${protocol}"
  if $ensure == 'present' {
    exec { "firewalld-port-${title}":
      command => "firewall-cmd --zone=${zone} --add-port=${spec} && firewall-cmd --permanent --zone=${zone} --add-port=${spec}",
      unless  => "firewall-cmd --zone=${zone} --query-port=${spec} && firewall-cmd --permanent --zone=${zone} --query-port=${spec}",
      path    => ['/usr/bin', '/bin'],
      require => Service['firewalld'],
    }
  } else {
    exec { "firewalld-port-${title}":
      command => "firewall-cmd --zone=${zone} --remove-port=${spec} || true; firewall-cmd --permanent --zone=${zone} --remove-port=${spec} || true",
      onlyif  => "firewall-cmd --zone=${zone} --query-port=${spec} || firewall-cmd --permanent --zone=${zone} --query-port=${spec}",
      path    => ['/usr/bin', '/bin'],
      require => Service['firewalld'],
    }
  }
}

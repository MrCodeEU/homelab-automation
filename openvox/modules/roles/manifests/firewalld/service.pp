# Manage one runtime and persistent firewalld service.
define roles::firewalld::service (
  Pattern[/\A[A-Za-z0-9_-]+\z/] $zone,
  Pattern[/\A[A-Za-z0-9_-]+\z/] $service,
  Enum['present', 'absent'] $ensure = 'present',
) {
  if $ensure == 'present' {
    exec { "firewalld-service-${title}":
      command => "firewall-cmd --zone=${zone} --add-service=${service} && firewall-cmd --permanent --zone=${zone} --add-service=${service}",
      unless  => "firewall-cmd --zone=${zone} --query-service=${service} && firewall-cmd --permanent --zone=${zone} --query-service=${service}",
      path    => ['/usr/bin', '/bin'],
      require => Service['firewalld'],
    }
  } else {
    exec { "firewalld-service-${title}":
      command => "firewall-cmd --zone=${zone} --remove-service=${service} || true; firewall-cmd --permanent --zone=${zone} --remove-service=${service} || true",
      onlyif  => "firewall-cmd --zone=${zone} --query-service=${service} || firewall-cmd --permanent --zone=${zone} --query-service=${service}",
      path    => ['/usr/bin', '/bin'],
      require => Service['firewalld'],
    }
  }
}

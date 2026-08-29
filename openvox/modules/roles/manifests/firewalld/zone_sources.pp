# Keep a zone's source CIDRs equal in runtime and persistent state.
define roles::firewalld::zone_sources (
  Pattern[/\A[A-Za-z0-9_-]+\z/] $zone,
  Array[Pattern[/\A[0-9A-Fa-f:.\/]+\z/]] $sources = [],
) {
  $source_args = $sources.join(' ')
  exec { "firewalld-zone-sources-${title}":
    command  => "/usr/local/libexec/openvox-firewalld/zone-sources-apply.sh ${zone} ${source_args}",
    unless   => "test -x /usr/local/libexec/openvox-firewalld/zone-sources-check.sh && /usr/local/libexec/openvox-firewalld/zone-sources-check.sh ${zone} ${source_args}",
    provider => shell,
    path     => ['/usr/bin', '/bin'],
    require  => [Service['firewalld'], File['/usr/local/libexec/openvox-firewalld/zone-sources-apply.sh'], File['/usr/local/libexec/openvox-firewalld/zone-sources-check.sh']],
  }
}

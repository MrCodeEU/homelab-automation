# Installs ziti-tcp-proxy (tools/cmd/ziti-tcp-proxy), the m2m sidecars'
# Ziti client. The sidecars (crowdsec-nuc, homepage, kuma,
# speedtest-metrics, ziti-proxy, ziti-proxy-nuc, ziti-proxy-ugreen) run a
# distroless image that bind-mounts this directory read-only, so the binary
# is shipped once per host instead of once per service.
#
# A running container keeps executing the binary it started with, so a new
# binary restarts every container labelled homelab.ziti-tcp-proxy. Declared
# before roles::services in the role so a first deploy finds the binary.
class roles::ziti_tcp_proxy {
  $dir = '/usr/local/libexec/ziti-tcp-proxy'

  file { $dir:
    ensure => directory,
    mode   => '0755',
  }
  file { "${dir}/ziti-tcp-proxy":
    ensure => file,
    mode   => '0755',
    source => 'puppet:///modules/roles/ziti_tcp_proxy/ziti-tcp-proxy',
  }
  exec { 'ziti-tcp-proxy-restart-sidecars':
    command     => 'docker ps -q --filter label=homelab.ziti-tcp-proxy=true | xargs -r docker restart',
    provider    => shell,
    path        => ['/usr/local/bin', '/usr/bin', '/bin'],
    refreshonly => true,
    subscribe   => File["${dir}/ziti-tcp-proxy"],
  }
}

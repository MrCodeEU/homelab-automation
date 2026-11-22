# ziti-tcp-proxy (tools/cmd/ziti-tcp-proxy) on nas, for its m2m sidecars
# (services/crowdsec-nas). nas has no Puppet agent, so nuc copies its own
# binary from roles::ziti_tcp_proxy over `ssh nas-mgmt`
# (roles::nas_mgmt_key) to the array: /usr/local is tmpfs on Unraid, the
# array survives a reboot. A changed binary restarts the sidecars there.
class roles::nas_ziti_tcp_proxy (
  String $work_dir = '/usr/local/libexec/openvox-nas-ziti-tcp-proxy',
) {
  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/nas_ziti_tcp_proxy',
  }

  # Guarded like roles::nas_mgmt_key: a --noop before the first real apply
  # reports "would run" instead of a missing-command error.
  exec { 'nas-ziti-tcp-proxy-binary':
    command  => "/bin/bash ${work_dir}/binary-apply.sh",
    unless   => "test -f ${work_dir}/binary-check.sh && /bin/bash ${work_dir}/binary-check.sh",
    provider => shell,
    path     => ['/usr/bin', '/bin'],
    require  => [File[$work_dir], Class['roles::ziti_tcp_proxy'], Class['roles::nas_mgmt_key']],
  }
}

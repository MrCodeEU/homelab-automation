# roles::lan_firewall for nas (Unraid, no firewalld, INPUT accepts
# everything). nas has no agent, so nuc renders the same rules and drives
# setup.sh over `ssh nas-mgmt`, like roles::nas_opkssh. The files live on
# the array (/mnt/user/appdata/homelab/lan-firewall) and the Unraid
# bootstrap (roles::unraid_proxy) reloads them at every array start.
#
# Same defaults and modes as roles::lan_firewall, including the container
# chain; Syncthing on nas syncs with LAN peers over 22000, so that is an
# egress exception here. Not in the default
# interface list: br0, nas's LAN bridge (192.168.50.80), whose traffic is
# what the lists decide.
class roles::nas_lan_firewall (
  Enum['log', 'enforce'] $mode = 'log',
  Enum['log', 'enforce'] $egress_mode = 'log',
  Array[String] $egress_exceptions = ['tcp:8442', 'tcp:22000', 'udp:22000'],
  Array[String] $lan_cidrs = ['192.168.50.0/24'],
  Array[Integer] $tcp_ports = [22, 8442, 22000],
  Array[Integer] $udp_ports = [22000, 21027],
  Array[String] $interfaces = ['tailscale+'],
  Array[String] $container_interfaces = ['docker0', 'br-+'],
  Array[String] $container_exceptions = ['tcp:8442'],
  String $staging_dir = '/var/lib/openvox-nas-lan-firewall',
  String $work_dir = '/usr/local/libexec/openvox-nas-lan-firewall',
) {
  file { $staging_dir:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0700',
  }

  file { "${staging_dir}/setup.sh":
    ensure => file,
    mode   => '0755',
    source => 'puppet:///modules/roles/lan_firewall/setup.sh',
  }

  ['4', '6'].each |$family| {
    file { "${staging_dir}/rules.v${family}":
      ensure  => file,
      mode    => '0644',
      content => epp('roles/lan_firewall/rules.epp', {
        'family'               => $family,
        'mode'                 => $mode,
        'scope'                => 'full',
        'tcp_ports'            => $tcp_ports,
        'udp_ports'            => $udp_ports,
        'interfaces'           => $interfaces,
        'container_interfaces' => $container_interfaces,
        'container_exceptions' => $container_exceptions,
        'class_name'           => 'roles::nas_lan_firewall',
      }),
    }
  }

  file { "${staging_dir}/rules.fwd.v4":
    ensure  => file,
    mode    => '0644',
    content => epp('roles/lan_firewall/forward.epp', {
      'mode'       => $egress_mode,
      'lan_cidrs'  => $lan_cidrs,
      'exceptions' => $egress_exceptions,
      'class_name' => 'roles::nas_lan_firewall',
    }),
  }

  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/nas_lan_firewall',
  }

  # Guarded like roles::nas_opkssh: a --noop before the first real apply
  # reports "would run" instead of a missing-command error.
  exec { 'nas-lan-firewall':
    command  => "/bin/bash ${work_dir}/apply.sh",
    unless   => "test -f ${work_dir}/check.sh && /bin/bash ${work_dir}/check.sh",
    provider => shell,
    path     => ['/usr/bin', '/bin'],
    require  => File[$work_dir, "${staging_dir}/setup.sh", "${staging_dir}/rules.v4", "${staging_dir}/rules.v6", "${staging_dir}/rules.fwd.v4"],
  }
}

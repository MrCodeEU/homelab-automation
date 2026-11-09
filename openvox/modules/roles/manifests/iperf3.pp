# Network performance testing server, rocky hosts + ugreen.
# Port of ansible/roles/iperf3 - see that role's header comment for usage.
#
# $bind: listen address. 127.0.0.1 on every host: the host's Ziti router
# (host network) publishes it as the service iperf3-<host>
# (ziti/tofu/iperf3.tf), which speedtest-metrics on nuc tests every 2h.
# Not the catalog's Tailscale IP, so it keeps working once Tailscale is
# gone. Empty listens on every address.
class roles::iperf3 (
  String  $base_path      = '/opt',
  Boolean $manage_firewall = true,
  String  $bind            = '',
) {
  $command = $bind ? {
    ''      => '["-s"]',
    default => "[\"-s\", \"-B\", \"${bind}\"]",
  }
  file { "${base_path}/iperf3":
    ensure => directory,
    mode   => '0755',
  }

  file { "${base_path}/iperf3/docker-compose.yml":
    ensure  => file,
    mode    => '0644',
    content => @("END"),
      services:
        iperf3:
          image: networkstatic/iperf3:latest@sha256:bc267517f534d9f7cced2669f325799a1fd7fe1d5953c2ca2c6ea1db61affa08
          container_name: iperf3
          restart: unless-stopped
          network_mode: host
          command: ${command}
          logging:
            driver: "json-file"
            options:
              max-size: "5m"
              max-file: "2"
      | END
    require => File["${base_path}/iperf3"],
  }

  # ugreen (UGOS/Debian) has no firewalld managed anywhere else in this
  # repo either, and is Tailscale-only the same way rocky hosts are -
  # skipping here is consistent with the existing posture, not a gap.
  # On loopback only the local router connects, so the ports close.
  $firewall_ensure = $bind ? {
    '127.0.0.1' => absent,
    default     => present,
  }
  if $manage_firewall {
    roles::firewalld::port { 'iperf3-tcp':
      ensure   => $firewall_ensure,
      zone     => 'trusted',
      port     => 5201,
      protocol => 'tcp',
    }
    roles::firewalld::port { 'iperf3-udp':
      ensure   => $firewall_ensure,
      zone     => 'trusted',
      port     => 5201,
      protocol => 'udp',
    }
  }

  docker_compose { 'iperf3':
    ensure        => present,
    compose_files => ["${base_path}/iperf3/docker-compose.yml"],
    # subscribe, not require - see roles::netronome_agent's identical
    # docker_compose resource for why: exists? never diffs file content,
    # so a require-only relationship leaves stale containers running
    # after a compose change goes unnoticed by Puppet.
    subscribe     => File["${base_path}/iperf3/docker-compose.yml"],
  }
}

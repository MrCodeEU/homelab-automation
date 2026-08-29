# Network performance testing server, rocky hosts + ugreen.
# Port of ansible/roles/iperf3 - see that role's header comment for usage.
class roles::iperf3 (
  String  $base_path      = '/opt',
  Boolean $manage_firewall = true,
) {
  file { "${base_path}/iperf3":
    ensure => directory,
    mode   => '0755',
  }

  file { "${base_path}/iperf3/docker-compose.yml":
    ensure  => file,
    mode    => '0644',
    content => @(END),
      services:
        iperf3:
          image: networkstatic/iperf3:latest
          container_name: iperf3
          restart: unless-stopped
          network_mode: host
          command: ["-s"]
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
  if $manage_firewall {
    roles::firewalld::port { 'iperf3-tcp':
      ensure   => present,
      zone     => 'trusted',
      port     => 5201,
      protocol => 'tcp',
    }
    roles::firewalld::port { 'iperf3-udp':
      ensure   => present,
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

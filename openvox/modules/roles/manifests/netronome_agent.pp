# Netronome system-metrics agent (CPU/mem/disk/bandwidth), reporting back
# to the central speedtest.mljr.eu server. Separate from roles::iperf3 -
# agents report host metrics, iperf3 handles mesh bandwidth tests; both
# run alongside each other on the same hosts.
#
# Tailscale integration mirrors the speedtest server's own piece: method
# host bind-mounts the HOST's own already-authenticated system tailscaled
# socket rather than minting a separate tsnet identity, so no per-host
# auth key is needed. Confirmed live: unlike the server, the `agent`
# subcommand does NOT read NETRONOME__TAILSCALE_ENABLED/_METHOD - it only
# picks up Tailscale via its own --tailscale/--tailscale-method CLI flags
# (verified by /netronome/info reporting using_tailscale:false with only
# the env vars set).
class roles::netronome_agent (
  String  $base_path       = '/opt',
  Boolean $manage_firewall = true,
) {
  $api_key = Sensitive(lookup('vault_netronome_agent_api_key'))

  file { "${base_path}/netronome-agent":
    ensure => directory,
    mode   => '0755',
  }

  $compose_content = @("END"/L)
    services:
      netronome-agent:
        image: ghcr.io/autobrr/netronome:latest
        container_name: netronome-agent
        restart: unless-stopped
        network_mode: host
        command: ["agent", "--tailscale", "--tailscale-method", "host"]
        environment:
          NETRONOME__AGENT_HOST: 0.0.0.0
          NETRONOME__AGENT_PORT: 8200
          NETRONOME__AGENT_API_KEY: ${api_key.unwrap}
        volumes:
          - /var/run/tailscale:/var/run/tailscale:ro
        logging:
          driver: "json-file"
          options:
            max-size: "5m"
            max-file: "2"
    | END

  file { "${base_path}/netronome-agent/docker-compose.yml":
    ensure  => file,
    mode    => '0644',
    content => Sensitive($compose_content),
    require => File["${base_path}/netronome-agent"],
  }

  # Same posture as roles::iperf3: ugreen manages no firewalld anywhere
  # else in this repo, Tailscale-only there too.
  if $manage_firewall {
    firewalld_port { 'netronome-agent-tcp':
      ensure   => present,
      zone     => 'trusted',
      port     => 8200,
      protocol => 'tcp',
    }
  }

  docker_compose { 'netronome-agent':
    compose_files => ["${base_path}/netronome-agent/docker-compose.yml"],
    ensure        => present,
    require       => File["${base_path}/netronome-agent/docker-compose.yml"],
  }
}

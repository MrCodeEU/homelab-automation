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
#
# No NETRONOME__AGENT_API_KEY here on purpose: auto-discovered Tailscale
# agents get created with a blank key by Netronome's own discovery code,
# and the "Edit Monitoring Settings" dialog for a Tailscale-connected
# agent has no field to set one at all ("Connection details are managed
# by Tailscale. Only monitoring can be toggled." - confirmed live).
# Tailnet membership is the trust boundary in this mode; setting a key
# here just makes every discovered agent 401 forever.
#
# Historical bandwidth export needs a real vnstatd running continuously
# with a persisted db - confirmed live that the agent's own bundled
# `vnstat` binary is CLI-only, it never starts the daemon itself, so
# without this sidecar every agent's /export/historical 500s forever
# ("vnStat daemon should have created the database"). Matches Netronome's
# own documented pattern (docs/README "Monitoring a Host Interface"): a
# vergoh/vnstat container in host network mode, sharing /var/lib/vnstat
# with the agent. $interface pins which host interface it and the agent
# both track - same reasoning as the nas-specific override this repo
# already carries (vnstat's own auto-pick landed on an inert interface
# on a many-interface host).
class roles::netronome_agent (
  String  $base_path       = '/opt',
  Boolean $manage_firewall = true,
  String  $interface       = '',
) {
  file { "${base_path}/netronome-agent":
    ensure => directory,
    mode   => '0755',
  }

  file { "${base_path}/netronome-agent/vnstat-db":
    ensure  => directory,
    mode    => '0755',
    require => File["${base_path}/netronome-agent"],
  }

  $agent_interface_env = $interface ? {
    ''      => '',
    default => "\n      NETRONOME__AGENT_INTERFACE: ${interface}",
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
          NETRONOME__AGENT_PORT: 8200${agent_interface_env}
        dns:
          - 100.100.100.100
        volumes:
          - /var/run/tailscale:/var/run/tailscale:ro
          - ${base_path}/netronome-agent/vnstat-db:/var/lib/vnstat:ro
        logging:
          driver: "json-file"
          options:
            max-size: "5m"
            max-file: "2"
      vnstat:
        image: ghcr.io/vergoh/vnstat:latest
        container_name: netronome-vnstat
        restart: unless-stopped
        network_mode: host
        cap_add:
          - NET_ADMIN
          - NET_RAW
        environment:
          TZ: Europe/Vienna
          HTTP_PORT: "0"
        volumes:
          - ${base_path}/netronome-agent/vnstat-db:/var/lib/vnstat
        logging:
          driver: "json-file"
          options:
            max-size: "5m"
            max-file: "2"
    | END

  file { "${base_path}/netronome-agent/docker-compose.yml":
    ensure  => file,
    mode    => '0644',
    content => $compose_content,
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
    ensure        => present,
    compose_files => ["${base_path}/netronome-agent/docker-compose.yml"],
    # subscribe, not require: docker_compose's own exists? only checks
    # that a container is running per service+image, it never diffs the
    # compose file's actual content - so a require-only relationship
    # silently leaves stale containers running after a command/env
    # change. subscribe triggers the type's refresh -> provider.restart
    # (real kill+build+up -d), which require never does.
    subscribe     => File["${base_path}/netronome-agent/docker-compose.yml"],
  }
}

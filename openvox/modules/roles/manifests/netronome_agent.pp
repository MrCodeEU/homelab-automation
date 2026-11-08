# Netronome system-metrics agent (CPU/mem/disk/bandwidth), reporting back
# to the central speedtest.mljr.eu server. Separate from roles::iperf3 -
# agents report host metrics, iperf3 handles mesh bandwidth tests; both
# run alongside each other on the same hosts.
#
# Reached over OpenZiti, not Tailscale (docs/ZERO_TRUST_PLAN.md Phase 4):
# the agent listens on $host only (the host's catalog bind address:
# 127.0.0.1 on mljr, the Tailscale IP elsewhere), the host's router
# publishes it as netronome-agent-<host> (ziti/tofu/netronome.tf), and only
# the speedtest server's proxy (identity netronome-nuc) may dial it. The
# server adds it as a manual agent (http://127.0.0.1:820x), no Tailscale
# discovery. Until 2026-11 the agent ran with --tailscale (host method,
# the host's tailscaled socket); that mode created agents with a blank
# API key that could not be edited, hence still no API key: the Ziti
# dial policy is the boundary now.
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
  String  $host            = '127.0.0.1',
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
        image: ghcr.io/autobrr/netronome:v0.16.0@sha256:e6e43960e60e5a84e1eff325af179ebe383ea3c63b57a142d696729f825e867b
        container_name: netronome-agent
        restart: unless-stopped
        network_mode: host
        command: ["agent"]
        environment:
          NETRONOME__AGENT_HOST: ${host}
          NETRONOME__AGENT_PORT: 8200${agent_interface_env}
        volumes:
          - ${base_path}/netronome-agent/vnstat-db:/var/lib/vnstat:ro
        logging:
          driver: "json-file"
          options:
            max-size: "5m"
            max-file: "2"
      vnstat:
        image: ghcr.io/vergoh/vnstat:2.13@sha256:be13a307f99e27e0f6380396ce05e135aec0b1ac73c3fcc055212464ec386ca1
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
  # else in this repo, Tailscale-only there too. Absent: only the host's
  # own router connects now, locally.
  if $manage_firewall {
    roles::firewalld::port { 'netronome-agent-tcp':
      ensure   => absent,
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

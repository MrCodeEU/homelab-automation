# OpenVox migration - entrypoint. Real agent-managed hosts get a node
# block here; nas/wd-mycloud have no agent at all (see manifests/roles/
# wd-mycloud-proxy.pp pattern once ported) and are driven by exec
# resources declared on nuc's own node block instead.

# CI's own weekly-maintenance run sets FACTER_openvox_weekly_maintenance=true
# before invoking `puppet apply` (see .github/workflows/deploy.yml) - the
# masterless equivalent of Ansible's `docker_prune_enabled`/
# `reboot_if_needed` extra-vars, which had no config file or CLI flag to
# live in otherwise. Every other trigger leaves the fact unset, so both
# stay off by default, matching roles::base's own Ansible-parity defaults.
$weekly_maintenance = $facts['openvox_weekly_maintenance'] == 'true'

node 'mljr.tail33930.ts.net' {
  class { 'roles::base':
    swap_enabled            => true,
    public_ip               => '157.173.97.107',
    ssh_breakglass_port     => 2299,
    tailscale_ip            => '100.100.20.1',
    cockpit_console_enabled => true,
    domain                  => 'mljr.eu',
    docker_prune_enabled    => $weekly_maintenance,
    reboot_if_needed        => $weekly_maintenance,
  }
  class { 'roles::iperf3':
    base_path => '/opt',
  }
  class { 'roles::netronome_agent':
    base_path => '/opt',
    interface => 'eth0',
  }
  include roles::caddy
  include roles::authelia
  include roles::glance
  include roles::mailcow
  class { 'roles::backup':
    services  => ['authelia', 'mailcow', 'ntfy', 'goaccess', 'crowdsec', 'newsletter'],
    # Must match ansible/inventory's inventory_hostname exactly, not this
    # VPS's real OS hostname (vmi2945702) - see roles::backup's own
    # $hostname param doc for why.
    hostname  => 'mljr',
    # This 4vCPU/7.5GB VPS also runs every service it backs up (unlike
    # nas/nuc's on-prem headroom) - the default 8/16 pCloud concurrency
    # saturated it enough that Kuma's 48s timeout tripped on nearly every
    # container, including uptime.mljr.eu itself, for minutes during its
    # own nightly backup (2026-08-14). Matches the real, already-live
    # ansible/inventory/hosts.yml override for this host exactly.
    transfers => 2,
    checkers  => 4,
    bwlimit   => '8M',
    cpu_quota => '40%',
    verification_integrity_schedule => 'Sun *-*-* 04:30:00',
    verification_restore_schedule   => 'Sun *-*-01..07 08:30:00',
  }
  class { 'roles::services':
    hostname => 'mljr',
  }
  include roles::container_reconcile
  class { 'roles::hawser_agent':
    tailscale_ip => '100.100.20.1',
  }
  include roles::hetrixtools_agent
  include roles::homepage_data_sync
  class { 'roles::host_facts_endpoint':
    os_family => 'rocky',
    hostname  => 'mljr',
    dest      => '/usr/local/bin/homelab-facts',
  }
  include roles::crowdsec_firewall_bouncer
  class { 'roles::grafana_alloy':
    hostname => 'mljr',
  }
}

node 'nuc.tail33930.ts.net' {
  class { 'roles::base':
    tailscale_ip         => '100.100.10.1',
    docker_prune_enabled => $weekly_maintenance,
    reboot_if_needed     => $weekly_maintenance,
    # nuc's own real LAN, not just Tailscale - previously a hand-rolled
    # `firewall-cmd --add-source` that never touched this other source;
    # now that the trusted zone is Puppet-managed, it has to be listed
    # explicitly or firewalld_zone's exact-set sources would drop it.
    trusted_zone_sources => ['100.64.0.0/10', '192.168.50.0/24'],
  }
  class { 'roles::iperf3':
    base_path => '/opt',
  }
  class { 'roles::netronome_agent':
    base_path => '/opt',
    interface => 'enp2s0',
  }
  # speedtest (Netronome) switched to network_mode: host to give the
  # container real routing to tailnet peer IPs for auto-discovery -
  # Docker's own bridge-network NAT no longer fronts this port, so it
  # needs the same explicit firewalld_port host-networked containers
  # always need (see roles::iperf3/roles::netronome_agent).
  firewalld_port { 'netronome-speedtest-tcp':
    ensure   => present,
    zone     => 'trusted',
    port     => 8090,
    protocol => 'tcp',
  }
  include roles::wd_mycloud_proxy
  include roles::wd_mycloud_node_exporter_proxy
  include roles::unraid_proxy
  include roles::unraid_backup_proxy
  include roles::services_nas
  class { 'roles::backup':
    services => ['kuma', 'forgejo', 'mail-archiver', 'umami', 'grafana', 'nocturne'],
    hostname => 'nuc',
    verification_integrity_schedule => 'Sun *-*-* 06:30:00',
    verification_restore_schedule   => 'Sun *-*-01..07 10:30:00',
  }
  class { 'roles::services':
    hostname     => 'nuc',
    tailscale_ip => '100.100.10.1',
  }
  include roles::container_reconcile
  include roles::backup_remote_key
  class { 'roles::hawser_agent':
    tailscale_ip => '100.100.10.1',
  }
  include roles::backup_dashboard
  include roles::healthreport
  class { 'roles::host_facts_endpoint':
    os_family => 'rocky',
    hostname  => 'nuc',
    dest      => '/usr/local/bin/homelab-facts',
  }
  include roles::unraid_host_facts_proxy
  class { 'roles::grafana_alloy':
    hostname => 'nuc',
  }
  include roles::tutabridge_cli
}

node 'ugreen.tail33930.ts.net' {
  class { 'roles::iperf3':
    base_path       => '/volume1/homelab',
    manage_firewall => false,
  }
  class { 'roles::netronome_agent':
    base_path       => '/volume1/homelab',
    manage_firewall => false,
    interface       => 'eth0',
  }
  include roles::backup_remote_target
  include roles::ugreen_tailscale
  class { 'roles::services':
    hostname        => 'ugreen',
    base_path       => '/volume1/homelab',
    tailscale_ip    => '100.100.10.4',
    # Matches ansible/inventory/group_vars/ugreen.yml's cleanup_enabled: false.
    cleanup_enabled => false,
  }
  class { 'roles::host_facts_endpoint':
    os_family     => 'ugreen',
    hostname      => 'ugreen',
    dest          => '/volume1/homelab/bin/homelab-facts',
    needs_symlink => true,
    dest_dir      => '/volume1/homelab/bin',
    base_path     => '/volume1/homelab',
  }
  class { 'roles::grafana_alloy':
    hostname          => 'ugreen',
    docker_root       => '/volume1/@docker',
    manage_docker_sdk => true,
  }
}

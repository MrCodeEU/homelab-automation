# OpenVox migration - entrypoint. Real agent-managed hosts get a node
# block here; nas/wd-mycloud have no agent at all (see manifests/roles/
# wd-mycloud-proxy.pp pattern once ported) and are driven by exec
# resources declared on nuc's own node block instead.

node 'mljr.tail33930.ts.net' {
  class { 'roles::base':
    swap_enabled         => true,
    public_ip            => '157.173.97.107',
    ssh_breakglass_port  => 2299,
    tailscale_ip         => '100.100.20.1',
    cockpit_console_enabled => true,
    domain               => 'mljr.eu',
  }
  class { 'roles::iperf3':
    base_path => '/opt',
  }
  include roles::caddy
  include roles::authelia
  include roles::glance
  include roles::mailcow
  class { 'roles::backup':
    services   => ['authelia', 'mailcow', 'ntfy', 'goaccess', 'crowdsec', 'newsletter'],
    # Must match ansible/inventory's inventory_hostname exactly, not this
    # VPS's real OS hostname (vmi2945702) - see roles::backup's own
    # $hostname param doc for why.
    hostname   => 'mljr',
    # This 4vCPU/7.5GB VPS also runs every service it backs up (unlike
    # nas/nuc's on-prem headroom) - the default 8/16 pCloud concurrency
    # saturated it enough that Kuma's 48s timeout tripped on nearly every
    # container, including uptime.mljr.eu itself, for minutes during its
    # own nightly backup (2026-08-14). Matches the real, already-live
    # ansible/inventory/hosts.yml override for this host exactly.
    transfers  => 2,
    checkers   => 4,
    bwlimit    => '8M',
    cpu_quota  => '40%',
  }
  class { 'roles::services':
    hostname => 'mljr',
  }
  include roles::container_reconcile
  class { 'roles::hawser_agent':
    tailscale_ip => '100.100.20.1',
  }
}

node 'nuc.tail33930.ts.net' {
  class { 'roles::base':
    tailscale_ip => '100.100.10.1',
  }
  class { 'roles::iperf3':
    base_path => '/opt',
  }
  include roles::wd_mycloud_proxy
  include roles::wd_mycloud_node_exporter_proxy
  include roles::unraid_proxy
  include roles::unraid_backup_proxy
  class { 'roles::backup':
    services => ['kuma', 'forgejo', 'mail-archiver', 'umami', 'grafana', 'nocturne'],
    hostname => 'nuc',
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
}

node 'ugreen.tail33930.ts.net' {
  class { 'roles::iperf3':
    base_path        => '/volume1/homelab',
    manage_firewall  => false,
  }
  include roles::backup_remote_target
  include roles::ugreen_tailscale
}

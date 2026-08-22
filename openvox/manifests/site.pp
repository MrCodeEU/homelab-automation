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
  include roles::authelia
  include roles::glance
  include roles::mailcow
}

node 'nuc.tail33930.ts.net' {
  class { 'roles::base':
    tailscale_ip => '100.100.10.1',
  }
  class { 'roles::iperf3':
    base_path => '/opt',
  }
  include roles::wd_mycloud_proxy
  include roles::unraid_proxy
  include roles::unraid_backup_proxy
}

node 'ugreen.tail33930.ts.net' {
  class { 'roles::iperf3':
    base_path        => '/volume1/homelab',
    manage_firewall  => false,
  }
}

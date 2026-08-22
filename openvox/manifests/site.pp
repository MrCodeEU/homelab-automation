# OpenVox migration - entrypoint. Real agent-managed hosts get a node
# block here; nas/wd-mycloud have no agent at all (see manifests/roles/
# wd-mycloud-proxy.pp pattern once ported) and are driven by exec
# resources declared on nuc's own node block instead.

node 'mljr.tail33930.ts.net' {
  class { 'roles::iperf3':
    base_path => '/opt',
  }
}

node 'nuc.tail33930.ts.net' {
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

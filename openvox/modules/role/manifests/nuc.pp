# role::nuc - staging + misc services (Rocky), and the reach-over-SSH
# proxy for nas/wd_mycloud (neither has a real Puppet agent). See
# role::mljr for the general roles/profiles convention this follows.
# Per-host data: data/nodes/nuc.tail33930.ts.net.yaml.
class role::nuc {
  include roles::base
  include roles::iperf3
  include roles::netronome_agent

  # speedtest (Netronome) uses network_mode: host for real routing to
  # tailnet peer IPs - needs the same explicit firewall port any
  # host-networked container needs (see roles::iperf3/netronome_agent).
  # Genuinely nuc-specific one-off config, not reusable data - left as a
  # bare resource declaration rather than turned into hiera-fed params.
  roles::firewalld::port { 'netronome-speedtest-tcp':
    ensure   => present,
    zone     => 'trusted',
    port     => 8090,
    protocol => 'tcp',
  }

  include roles::wd_mycloud_proxy
  include roles::wd_mycloud_node_exporter_proxy
  include roles::unraid_proxy
  include roles::unraid_backup_proxy
  include roles::canary_decoys
  include roles::canary_decoys_nas
  include roles::services_nas
  include roles::backup
  include roles::services
  include roles::container_reconcile
  include roles::backup_remote_key
  include roles::hawser_agent
  include roles::backup_dashboard
  include roles::healthreport
  include roles::host_facts_endpoint
  include roles::unraid_host_facts_proxy
  include roles::grafana_alloy
  include roles::tutabridge_cli
}

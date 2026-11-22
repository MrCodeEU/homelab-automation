# role::nuc - staging + misc services (Rocky), and the reach-over-SSH
# proxy for nas/wd_mycloud (neither has a real Puppet agent). See
# role::mljr for the general roles/profiles convention this follows.
# Per-host data: data/nodes/nuc.int.mljr.eu.yaml.
class role::nuc {
  include roles::base
  include roles::ssh_hardening
  include roles::opkssh
  include roles::tcp_notsent_lowat
  include roles::ziti_renew
  # m2m sidecar binary; installed before the sidecars start (roles::ziti_tcp_proxy)
  include roles::ziti_tcp_proxy
  Class['roles::ziti_tcp_proxy'] -> Class['roles::services']
  include roles::iperf3

  include roles::wd_mycloud_proxy
  include roles::wd_mycloud_node_exporter_proxy
  include roles::wd_mycloud_ziti_proxy
  include roles::unraid_proxy
  include roles::unraid_backup_proxy
  include roles::unraid_aoostar_proxy
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
  # nuc is deployed by its agent; deploy.yml no longer pushes here in apply
  # mode (docs/DEPLOY_AGENT.md).
  class { 'roles::deploy_agent': mode => 'apply' }
  include roles::host_facts_endpoint
  # FRITZ!Box addresses for CrowdSec's home allowlist on mljr
  class { 'roles::home_ip': mode => 'serve' }
  include roles::unraid_host_facts_proxy
  include roles::grafana_alloy
  include roles::tutabridge_cli
  include roles::vuln_scan
}

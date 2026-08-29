# role::ugreen - UGreen NAS (UGOS, vendor appliance, no roles::base -
# UGOS isn't dnf-managed). See role::mljr for the general roles/profiles
# convention this follows. Per-host data:
# data/nodes/ugreen.tail33930.ts.net.yaml.
class role::ugreen {
  include roles::iperf3
  include roles::netronome_agent
  include roles::backup_remote_target
  include roles::ugreen_tailscale
  include roles::services
  include roles::host_facts_endpoint
  include roles::grafana_alloy
}

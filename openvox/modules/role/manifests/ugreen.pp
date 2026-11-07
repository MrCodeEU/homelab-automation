# role::ugreen - UGreen NAS (UGOS, vendor appliance, no roles::base -
# UGOS isn't dnf-managed). See role::mljr for the general roles/profiles
# convention this follows. Per-host data:
# data/nodes/ugreen.int.mljr.eu.yaml.
class role::ugreen (
  # Set false only while recovering Ugreen's vendor-managed storage. This
  # pauses management of the SFTP write target without deleting its existing
  # data or account; restore the default before repopulating backups.
  Boolean $backup_remote_target_enabled = true,
) {
  include roles::iperf3
  include roles::ssh_hardening
  include roles::netronome_agent
  if $backup_remote_target_enabled {
    include roles::backup_remote_target
  }
  include roles::ugreen_tailscale
  include roles::ugreen_ssh_loopback
  include roles::canary_decoys
  include roles::services
  include roles::host_facts_endpoint
  include roles::grafana_alloy
  include roles::vuln_scan
}

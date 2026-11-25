# role::drill - throwaway Rocky 10 VM on nuc for the DR drill
# (docs/DISASTER_RECOVERY.md, Phase 5 gate in docs/ZERO_TRUST_PLAN.md).
# Round 1 sets it up as a new host, round 2 rebuilds it from a fresh OS
# with only the runbook. Just what the runbook's steps need: base, SSH
# (break-glass, opkssh), its own Ziti router and m2m proxy, and a backup
# of one test volume to pCloud and ugreen. No deploy agent (laptop push
# only), no monitoring. Removed with the drill.
# Per-host data: data/nodes/drill.int.mljr.eu.yaml.
class role::drill {
  include roles::base
  include roles::ssh_hardening
  include roles::opkssh
  # m2m sidecar binary; installed before the sidecars start (roles::ziti_tcp_proxy)
  include roles::ziti_tcp_proxy
  Class['roles::ziti_tcp_proxy'] -> Class['roles::services']
  include roles::backup
  include roles::services
}

# role::mljr - production ingress (Rocky). One class per node archetype,
# composing roles::* classes (this repo's technology/profile tier - see
# docs/OPENVOX_BACKLOG.md for why there's no separate profile:: module).
# Per-host data lives in data/nodes/mljr.int.mljr.eu.yaml, bound
# automatically by Puppet's class-parameter hiera lookup - every roles::*
# class below is declared via plain `include`, never `class { }`.
class role::mljr {
  include roles::base
  include roles::ssh_hardening
  include roles::iperf3
  include roles::netronome_agent
  include roles::caddy
  include roles::authelia
  include roles::canarytokens
  include roles::canary_decoys
  include roles::glance
  include roles::mailcow
  include roles::backup
  include roles::services
  include roles::container_reconcile
  include roles::hawser_agent
  include roles::hetrixtools_agent
  include roles::homepage_data_sync
  include roles::host_facts_endpoint
  include roles::crowdsec_firewall_bouncer
  include roles::grafana_alloy
  include roles::vuln_scan
  # Pull deploy agent; applies (roles::deploy_agent::mode in
  # data/nodes/mljr.int.mljr.eu.yaml), deploy.yml no longer pushes here
  # (AGENT_APPLY_HOSTS, docs/DEPLOY_AGENT.md).
  include roles::deploy_agent
  # CrowdSec allowlist "home" from nuc's home-ip serve, over Ziti
  class { 'roles::home_ip': mode => 'sync' }
  # Named ntfy messages from the Ziti controller's event log
  include roles::ziti_notify
}

# role::mljr - production ingress (Rocky). One class per node archetype,
# composing roles::* classes (this repo's technology/profile tier - see
# docs/OPENVOX_BACKLOG.md for why there's no separate profile:: module).
# Per-host data lives in data/nodes/mljr.tail33930.ts.net.yaml, bound
# automatically by Puppet's class-parameter hiera lookup - every roles::*
# class below is declared via plain `include`, never `class { }`.
class role::mljr {
  include roles::base
  include roles::iperf3
  include roles::netronome_agent
  include roles::caddy
  include roles::authelia
  include roles::canarytokens
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
}

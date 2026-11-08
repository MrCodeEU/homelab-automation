# Netronome agents (roles::netronome_agent) on hosts with a router. They are
# not catalog entries, so not in catalog.tf: one service per host,
# netronome-agent.<host>.int.mljr.eu:8200 -> the host's bind address:8200,
# bound by that host's router only. Dialled by the speedtest server's proxy
# (m2m.tf, netronome-nuc). nas's agent stays on Tailscale until Phase 5.
locals {
  netronome_hosts = ["mljr", "nuc", "ugreen"]

  # The services keyed by name (netronome-agent-<host>), for m2m.tf
  ziti_service_netronome_by_name = { for h, s in ziti_service.netronome_agent : s.name => s }
}

resource "ziti_intercept_v1_config" "netronome_agent" {
  for_each  = toset(local.netronome_hosts)
  name      = "netronome-agent-${each.key}-intercept"
  addresses = ["netronome-agent.${each.key}.int.mljr.eu"]
  protocols = ["tcp"]
  port_ranges = [{
    low  = 8200
    high = 8200
  }]
}

resource "ziti_host_v1_config" "netronome_agent" {
  for_each = toset(local.netronome_hosts)
  name     = "netronome-agent-${each.key}-host"
  protocol = "tcp"
  address  = local.bind_addr[each.key]
  port     = 8200
}

resource "ziti_service" "netronome_agent" {
  for_each        = toset(local.netronome_hosts)
  name            = "netronome-agent-${each.key}"
  configs         = sort([ziti_intercept_v1_config.netronome_agent[each.key].id, ziti_host_v1_config.netronome_agent[each.key].id])
  role_attributes = ["admin-services"]
}

resource "ziti_service_policy" "netronome_agent_bind" {
  for_each      = toset(local.netronome_hosts)
  name          = "netronome-agent-${each.key}-bind"
  type          = "Bind"
  semantic      = "AnyOf"
  identityroles = [local.router[each.key]]
  serviceroles  = ["@${ziti_service.netronome_agent[each.key].id}"]
}

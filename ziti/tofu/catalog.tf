# Ziti services generated from services_catalog (openvox/data/common.yaml),
# the same data OpenVox deploys from; scripts/ziti-tofu.sh stages it and the
# node files in openvox-data/ next to this file. Opt-in per entry with `ziti: true`:
# machine-to-machine traffic moves one service at a time (Phase 4).
#
# For an entry <name> on <host> with port <port>:
#   intercept  <name>.<host>.int.mljr.eu:<port>
#   host       <bind address of <host>>:<port>, bound by <host>'s router.
#              The bind address is what the service publishes on today:
#              roles::services::tailscale_ip from the host's node file, or
#              127.0.0.1 where that is empty (mljr, Caddy is co-located).
#   attributes catalog, catalog-<host>, admin-services (admins may dial
#              every catalog service, as over Tailscale today), and caddy
#              for entries with `ziti_via_caddy: true` (implies ziti):
#              mljr's Caddy dials them (caddy.tf)
# Consumers get Dial policies by attribute, added with the consumer.
#
# `ziti_ports: {<key>: <port>}` adds Ziti-only services for an entry's
# other ports (no Caddy): <name>-<key>.<host>.int.mljr.eu:<port>, same
# host, bind address and attributes, never caddy. Example: forgejo's SSH,
# `ziti_ports: {ssh: 2222}` -> forgejo-ssh.nuc.int.mljr.eu:2222.

locals {
  catalog = yamldecode(file("${path.module}/openvox-data/common.yaml")).services_catalog

  ziti_catalog = merge(
    {
      for s in local.catalog : s.name => {
        host  = s.host
        port  = try(s.port, 0)
        caddy = try(s.ziti_via_caddy, false)
      }
      if(try(s.ziti, false) || try(s.ziti_via_caddy, false)) && try(s.enabled, true)
    },
    merge([
      for s in local.catalog : {
        for k, p in try(s.ziti_ports, {}) : "${s.name}-${k}" => {
          host  = s.host
          port  = p
          caddy = false
        }
      }
      if try(s.enabled, true)
    ]...),
  )

  # Hosts with a router on Ziti; a catalog service on any other host fails
  # the plan (precondition below) instead of getting a dead service.
  bind_addr = {
    for h in keys(local.router) : h => coalesce(
      try(yamldecode(file("${path.module}/openvox-data/nodes/${h}.int.mljr.eu.yaml"))["roles::services::tailscale_ip"], ""),
      "127.0.0.1",
    )
  }
}

resource "ziti_intercept_v1_config" "catalog" {
  for_each  = local.ziti_catalog
  name      = "${each.key}-intercept"
  addresses = ["${each.key}.${each.value.host}.int.mljr.eu"]
  protocols = ["tcp"]
  port_ranges = [{
    low  = each.value.port
    high = each.value.port
  }]

  lifecycle {
    precondition {
      condition     = contains(keys(local.router), each.value.host) && each.value.port > 0
      error_message = "services_catalog ${each.key}: ziti needs a host with a router (${join(", ", keys(local.router))}) and a port > 0."
    }
  }
}

resource "ziti_host_v1_config" "catalog" {
  for_each = local.ziti_catalog
  name     = "${each.key}-host"
  protocol = "tcp"
  address  = local.bind_addr[each.value.host]
  port     = each.value.port
}

resource "ziti_service" "catalog" {
  for_each = local.ziti_catalog
  name     = each.key
  configs  = sort([ziti_intercept_v1_config.catalog[each.key].id, ziti_host_v1_config.catalog[each.key].id])
  role_attributes = sort(concat(
    ["admin-services", "catalog", "catalog-${each.value.host}"],
    each.value.caddy ? ["caddy"] : [],
  ))
}

# One Bind policy per host: its router hosts that host's catalog services.
resource "ziti_service_policy" "catalog_bind" {
  for_each      = toset([for s in local.ziti_catalog : s.host])
  name          = "catalog-${each.key}-bind"
  type          = "Bind"
  semantic      = "AnyOf"
  identityroles = [local.router[each.key]]
  serviceroles  = ["#catalog-${each.key}"]
}

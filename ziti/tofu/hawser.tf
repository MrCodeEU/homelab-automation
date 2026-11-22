# Dockhand (nas) -> the Hawser agents on nuc and mljr (roles::hawser_agent),
# which give full control of that host's Docker. hawser-<host>,
# hawser.<host>.int.mljr.eu:2376 -> 127.0.0.1:2376, bound by that host's
# router only. Dialled only by nas's host proxy (m2m.tf, m2m-nas;
# services/ziti-proxy-nas): no admin-services attribute, so not even the
# admins' devices may dial it. Was Hawser on each host's Tailscale IP,
# reachable from the whole tailnet.
locals {
  hawser_hosts = ["mljr", "nuc"]

  # The services keyed by name (hawser-<host>), for m2m.tf
  hawser_services = { for h, s in ziti_service.hawser : s.name => s }
}

resource "ziti_intercept_v1_config" "hawser" {
  for_each  = toset(local.hawser_hosts)
  name      = "hawser-${each.key}-intercept"
  addresses = ["hawser.${each.key}.int.mljr.eu"]
  protocols = ["tcp"]
  port_ranges = [{
    low  = 2376
    high = 2376
  }]
}

resource "ziti_host_v1_config" "hawser" {
  for_each = toset(local.hawser_hosts)
  name     = "hawser-${each.key}-host"
  protocol = "tcp"
  address  = "127.0.0.1"
  port     = 2376
}

resource "ziti_service" "hawser" {
  for_each        = toset(local.hawser_hosts)
  name            = "hawser-${each.key}"
  configs         = sort([ziti_intercept_v1_config.hawser[each.key].id, ziti_host_v1_config.hawser[each.key].id])
  role_attributes = []
}

resource "ziti_service_policy" "hawser_bind" {
  for_each      = toset(local.hawser_hosts)
  name          = "hawser-${each.key}-bind"
  type          = "Bind"
  semantic      = "AnyOf"
  identityroles = [local.router[each.key]]
  serviceroles  = ["@${ziti_service.hawser[each.key].id}"]
}

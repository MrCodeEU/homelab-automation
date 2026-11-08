# iperf3 servers (roles::iperf3) as test targets for speedtest-metrics on
# nuc (m2m.tf, speedtest-nuc). Not catalog entries, so not in catalog.tf:
# one service per host, iperf3.<host>.int.mljr.eu:5201 -> 127.0.0.1:5201
# (roles::iperf3::bind; the routers run with host networking), bound by
# that host's router only. Not local.bind_addr: that is the Tailscale IP
# on nuc and ugreen. Control and data
# connections both use 5201, so one TCP service carries a whole test.
locals {
  iperf3_hosts = ["mljr", "ugreen"]

  # The services keyed by name (iperf3-<host>), for m2m.tf
  iperf3_services = { for h, s in ziti_service.iperf3 : s.name => s }
}

resource "ziti_intercept_v1_config" "iperf3" {
  for_each  = toset(local.iperf3_hosts)
  name      = "iperf3-${each.key}-intercept"
  addresses = ["iperf3.${each.key}.int.mljr.eu"]
  protocols = ["tcp"]
  port_ranges = [{
    low  = 5201
    high = 5201
  }]
}

resource "ziti_host_v1_config" "iperf3" {
  for_each = toset(local.iperf3_hosts)
  name     = "iperf3-${each.key}-host"
  protocol = "tcp"
  address  = "127.0.0.1"
  port     = 5201
}

resource "ziti_service" "iperf3" {
  for_each        = toset(local.iperf3_hosts)
  name            = "iperf3-${each.key}"
  configs         = sort([ziti_intercept_v1_config.iperf3[each.key].id, ziti_host_v1_config.iperf3[each.key].id])
  role_attributes = ["admin-services"]
}

resource "ziti_service_policy" "iperf3_bind" {
  for_each      = toset(local.iperf3_hosts)
  name          = "iperf3-${each.key}-bind"
  type          = "Bind"
  semantic      = "AnyOf"
  identityroles = [local.router[each.key]]
  serviceroles  = ["@${ziti_service.iperf3[each.key].id}"]
}

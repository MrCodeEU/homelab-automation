# home-ip serve on nuc (roles::home_ip): the FRITZ!Box's view of the home
# connection's addresses, for home-ip sync on mljr (m2m.tf, m2m-mljr), which
# keeps CrowdSec's "home" allowlist current. home-ip.nuc.int.mljr.eu:19480 ->
# 127.0.0.1:19480, bound by nuc's router (host networking). Not a catalog
# entry: no web UI. The FRITZ!Box itself is not exposed: its UPnP control
# endpoint also takes port-mapping actions.
resource "ziti_intercept_v1_config" "home_ip_nuc" {
  name      = "home-ip-nuc-intercept"
  addresses = ["home-ip.nuc.int.mljr.eu"]
  protocols = ["tcp"]
  port_ranges = [{
    low  = 19480
    high = 19480
  }]
}

resource "ziti_host_v1_config" "home_ip_nuc" {
  name     = "home-ip-nuc-host"
  protocol = "tcp"
  address  = "127.0.0.1"
  port     = 19480
}

resource "ziti_service" "home_ip_nuc" {
  name            = "home-ip-nuc"
  configs         = sort([ziti_intercept_v1_config.home_ip_nuc.id, ziti_host_v1_config.home_ip_nuc.id])
  role_attributes = ["admin-services"]
}

resource "ziti_service_policy" "home_ip_nuc_bind" {
  name          = "home-ip-nuc-bind"
  type          = "Bind"
  semantic      = "AnyOf"
  identityroles = [local.router["nuc"]]
  serviceroles  = ["@${ziti_service.home_ip_nuc.id}"]
}

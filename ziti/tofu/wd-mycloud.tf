# WD My Cloud (EX2 Ultra, armv7, no router possible) hosts its own services
# with ziti-edge-tunnel in run-host mode (roles::wd_mycloud_ziti_proxy,
# C7). Its identity is #at-home, so it connects to the LAN routers (nas
# first: same switch). Enrolled on the device by
# scripts/ziti-enroll-wd-mycloud.sh; the key never leaves it.
#
# Both services listen on the device's loopback: sshd (real OpenSSH, for
# the management scripts on nuc, replacing Tailscale SSH) and
# node_exporter (moves off its Tailscale address). Dialed by #admin
# (admin-services) and, for the switch-over, m2m-nuc (m2m.tf).
locals {
  wd_mycloud_services = {
    "wd-mycloud-ssh"      = 22
    "wd-mycloud-exporter" = 9100
  }
}

resource "ziti_identity" "wd_mycloud" {
  name            = "wd-mycloud"
  type            = "Default"
  auth_policy_id  = "default"
  role_attributes = ["at-home"]
}

resource "ziti_intercept_v1_config" "wd_mycloud" {
  for_each  = local.wd_mycloud_services
  name      = "${each.key}-intercept"
  addresses = ["${trimprefix(each.key, "wd-mycloud-")}.wd-mycloud.int.mljr.eu", "${each.key}.ziti"]
  protocols = ["tcp"]
  port_ranges = [{
    low  = each.value
    high = each.value
  }]
}

resource "ziti_host_v1_config" "wd_mycloud" {
  for_each = local.wd_mycloud_services
  name     = "${each.key}-host"
  protocol = "tcp"
  address  = "127.0.0.1"
  port     = each.value
}

resource "ziti_service" "wd_mycloud" {
  for_each        = local.wd_mycloud_services
  name            = each.key
  configs         = sort([ziti_intercept_v1_config.wd_mycloud[each.key].id, ziti_host_v1_config.wd_mycloud[each.key].id])
  role_attributes = ["admin-services"]
}

resource "ziti_service_policy" "wd_mycloud_bind" {
  name          = "wd-mycloud-bind"
  type          = "Bind"
  semantic      = "AnyOf"
  identityroles = ["@${ziti_identity.wd_mycloud.id}"]
  serviceroles  = sort([for s in ziti_service.wd_mycloud : "@${s.id}"])
}

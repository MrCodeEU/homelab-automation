# --- nuc-alloy ----------------------------------------------------------------
# alloy.nuc.int.mljr.eu:12345 -> nuc 127.0.0.1:12345 (Grafana Alloy's
# metrics endpoint; nuc runs no node-exporter).
resource "ziti_intercept_v1_config" "nuc_alloy" {
  name      = "nuc-alloy-intercept"
  addresses = ["alloy.nuc.int.mljr.eu"]
  protocols = ["tcp"]
  port_ranges = [{
    low  = 12345
    high = 12345
  }]
}

resource "ziti_host_v1_config" "nuc_alloy" {
  name     = "nuc-alloy-host"
  protocol = "tcp"
  address  = "127.0.0.1"
  port     = 12345
}

resource "ziti_service" "nuc_alloy" {
  name            = "nuc-alloy"
  configs         = sort([ziti_intercept_v1_config.nuc_alloy.id, ziti_host_v1_config.nuc_alloy.id])
  role_attributes = ["admin-services"]
}

resource "ziti_service_policy" "nuc_alloy_bind" {
  name          = "nuc-alloy-bind"
  type          = "Bind"
  semantic      = "AnyOf"
  identityroles = [local.router["nuc"]]
  serviceroles  = ["@${ziti_service.nuc_alloy.id}"]
}

# --- ssh (addressable terminators, C10) ----------------------------------------
# <host>.int.mljr.eu:22 -> 127.0.0.1:22 on that host. The client dials the
# terminator named after the intercepted hostname ($dst_hostname); each
# hosting router binds under its own identity name, the host's certname.
# The intercept lists only hosts that are on Ziti, not *.int.mljr.eu: a
# wildcard makes every name resolve while the tunneler is up, so SSH
# canonicalization (ziti/laptop/ssh-int-mljr-eu.conf) could never fall back
# for hosts still on Tailscale only. The router-embedded tunneler does not
# resolve $tunneler_id.tag[...], hence routers named after their certname.
locals {
  ssh_hosts = ["mljr", "nuc", "ugreen"]
}

resource "ziti_intercept_v1_config" "ssh" {
  name      = "ssh-intercept"
  addresses = [for h in local.ssh_hosts : "${h}.int.mljr.eu"]
  protocols = ["tcp"]
  port_ranges = [{
    low  = 22
    high = 22
  }]
  dial_options = {
    identity = "$dst_hostname"
  }
}

resource "ziti_host_v1_config" "ssh" {
  name     = "ssh-host"
  protocol = "tcp"
  address  = "127.0.0.1"
  port     = 22
  listen_options = {
    bind_using_edge_identity = true
  }
}

resource "ziti_service" "ssh" {
  name            = "ssh"
  configs         = sort([ziti_intercept_v1_config.ssh.id, ziti_host_v1_config.ssh.id])
  role_attributes = ["admin-services"]
}

# <host>.ziti:22 for people (ssh root@nuc.ziti), one service per host:
# the ssh service above picks its terminator by the intercepted name
# ($dst_hostname = the router's identity name), which <host>.ziti is not.
resource "ziti_intercept_v1_config" "ssh_short" {
  for_each  = toset(local.ssh_hosts)
  name      = "ssh-${each.key}-short-intercept"
  addresses = ["${each.key}.ziti"]
  protocols = ["tcp"]
  port_ranges = [{
    low  = 22
    high = 22
  }]
}

resource "ziti_host_v1_config" "ssh_short" {
  name     = "ssh-short-host"
  protocol = "tcp"
  address  = "127.0.0.1"
  port     = 22
}

# ugreen: root from 127.0.0.1 is the facts endpoint's ForceCommand, so its
# admin login arrives from 127.0.0.2, where sshd allows root with a key
# (roles::opkssh::root_match_address). Linux answers the whole 127/8 on lo.
resource "ziti_host_v1_config" "ssh_short_ugreen" {
  name     = "ssh-short-host-ugreen"
  protocol = "tcp"
  address  = "127.0.0.2"
  port     = 22
}

resource "ziti_service" "ssh_short" {
  for_each = toset(local.ssh_hosts)
  name     = "ssh-${each.key}"
  configs = sort([ziti_intercept_v1_config.ssh_short[each.key].id,
  each.key == "ugreen" ? ziti_host_v1_config.ssh_short_ugreen.id : ziti_host_v1_config.ssh_short.id])
  role_attributes = ["admin-services"]
}

resource "ziti_service_policy" "ssh_short_bind" {
  for_each      = toset(local.ssh_hosts)
  name          = "ssh-${each.key}-bind"
  type          = "Bind"
  semantic      = "AnyOf"
  identityroles = [local.router[each.key]]
  serviceroles  = ["@${ziti_service.ssh_short[each.key].id}"]
}

resource "ziti_service_policy" "ssh_bind" {
  name          = "ssh-bind"
  type          = "Bind"
  semantic      = "AnyOf"
  identityroles = sort([for h in local.ssh_hosts : local.router[h]])
  serviceroles  = ["@${ziti_service.ssh.id}"]
}

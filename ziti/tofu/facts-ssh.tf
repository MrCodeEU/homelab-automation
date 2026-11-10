# SSH to hosts for healthreport's and backup-dashboard's facts
# (roles::host_facts_endpoint: a key that can only run homelab-facts).
# facts-ssh-<host>, facts-ssh.<host>.int.mljr.eu:22 -> 127.0.0.1:22, bound
# by that host's router only. Not the addressable "ssh" service
# (services.tf): `ziti tunnel proxy` cannot choose its terminator. The real sshd answers there (over the tailnet,
# Tailscale SSH did). Dialled by nuc's host proxy (m2m.tf, m2m-nuc). nas
# stays on the tailnet until Phase 5.
locals {
  facts_ssh_hosts = ["mljr", "ugreen"]

  # The services keyed by name (facts-ssh-<host>), for m2m.tf
  facts_ssh_services = { for h, s in ziti_service.facts_ssh : s.name => s }
}

resource "ziti_intercept_v1_config" "facts_ssh" {
  for_each  = toset(local.facts_ssh_hosts)
  name      = "facts-ssh-${each.key}-intercept"
  addresses = ["facts-ssh.${each.key}.int.mljr.eu"]
  protocols = ["tcp"]
  port_ranges = [{
    low  = 22
    high = 22
  }]
}

resource "ziti_host_v1_config" "facts_ssh" {
  for_each = toset(local.facts_ssh_hosts)
  name     = "facts-ssh-${each.key}-host"
  protocol = "tcp"
  address  = "127.0.0.1"
  port     = 22
}

resource "ziti_service" "facts_ssh" {
  for_each        = toset(local.facts_ssh_hosts)
  name            = "facts-ssh-${each.key}"
  configs         = sort([ziti_intercept_v1_config.facts_ssh[each.key].id, ziti_host_v1_config.facts_ssh[each.key].id])
  role_attributes = ["admin-services"]
}

resource "ziti_service_policy" "facts_ssh_bind" {
  for_each      = toset(local.facts_ssh_hosts)
  name          = "facts-ssh-${each.key}-bind"
  type          = "Bind"
  semantic      = "AnyOf"
  identityroles = [local.router[each.key]]
  serviceroles  = ["@${ziti_service.facts_ssh[each.key].id}"]
}

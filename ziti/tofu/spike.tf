# Config-management spike (docs/SPIKE_CONFIG_MGMT.md): three throwaway
# Rocky 10 VMs on nuc (libvirt NAT, nothing inbound). Reachable over Ziti
# only, never the tailnet. Delete this file when the spike ends; tofu then
# removes the identities, services and policies.
#
# spike-ssh-<vm>, <vm>.spike.int.mljr.eu:22 -> 127.0.0.1:22 on that VM,
# dialled by admins (the laptop: OpenVox push, glidesh).
# spike-cfengine, hub.spike.int.mljr.eu:5308 -> spike-hub 127.0.0.1:5308,
# dialled by the two clients (cf-agent pulls policy from cf-serverd).
locals {
  spike_vms     = ["spike-a", "spike-b", "spike-hub"]
  spike_clients = ["spike-a", "spike-b"]
}

resource "ziti_identity" "spike" {
  for_each        = toset(local.spike_vms)
  name            = each.key
  type            = "Default"
  auth_policy_id  = "default"
  role_attributes = ["spike"]
}

resource "ziti_intercept_v1_config" "spike_ssh" {
  for_each  = toset(local.spike_vms)
  name      = "spike-ssh-${each.key}-intercept"
  addresses = ["${each.key}.spike.int.mljr.eu"]
  protocols = ["tcp"]
  port_ranges = [{
    low  = 22
    high = 22
  }]
}

resource "ziti_host_v1_config" "spike_ssh" {
  for_each = toset(local.spike_vms)
  name     = "spike-ssh-${each.key}-host"
  protocol = "tcp"
  address  = "127.0.0.1"
  port     = 22
}

resource "ziti_service" "spike_ssh" {
  for_each        = toset(local.spike_vms)
  name            = "spike-ssh-${each.key}"
  configs         = sort([ziti_intercept_v1_config.spike_ssh[each.key].id, ziti_host_v1_config.spike_ssh[each.key].id])
  role_attributes = ["admin-services"]
}

resource "ziti_service_policy" "spike_ssh_bind" {
  for_each      = toset(local.spike_vms)
  name          = "spike-ssh-${each.key}-bind"
  type          = "Bind"
  semantic      = "AnyOf"
  identityroles = ["@${ziti_identity.spike[each.key].id}"]
  serviceroles  = ["@${ziti_service.spike_ssh[each.key].id}"]
}

resource "ziti_intercept_v1_config" "spike_cfengine" {
  name      = "spike-cfengine-intercept"
  addresses = ["hub.spike.int.mljr.eu"]
  protocols = ["tcp"]
  port_ranges = [{
    low  = 5308
    high = 5308
  }]
}

resource "ziti_host_v1_config" "spike_cfengine" {
  name     = "spike-cfengine-host"
  protocol = "tcp"
  address  = "127.0.0.1"
  port     = 5308
}

resource "ziti_service" "spike_cfengine" {
  name            = "spike-cfengine"
  configs         = sort([ziti_intercept_v1_config.spike_cfengine.id, ziti_host_v1_config.spike_cfengine.id])
  role_attributes = []
}

resource "ziti_service_policy" "spike_cfengine_bind" {
  name          = "spike-cfengine-bind"
  type          = "Bind"
  semantic      = "AnyOf"
  identityroles = ["@${ziti_identity.spike["spike-hub"].id}"]
  serviceroles  = ["@${ziti_service.spike_cfengine.id}"]
}

resource "ziti_service_policy" "spike_cfengine_dial" {
  name          = "spike-cfengine-dial"
  type          = "Dial"
  semantic      = "AnyOf"
  identityroles = sort([for vm in local.spike_clients : "@${ziti_identity.spike[vm].id}"])
  serviceroles  = ["@${ziti_service.spike_cfengine.id}"]
}

# Read-only identity for tools/cmd/ziti-mesh-exporter on mljr
# (services/ziti-mesh-exporter): reads routers, links, identities,
# terminators and circuits from the management and fabric APIs on the admin
# listener (127.0.0.1:8440) for Grafana's "Ziti mesh" dashboard. It dials
# and hosts nothing on the overlay, so no role attributes and no policies.
#
# Its permission, admin_readonly (OpenZiti 2.0, beta: reads everything
# except inspect/validate, writes nothing), is not something the provider
# knows: scripts/ziti-tofu.sh sets it after every apply from
# permissions.txt. The provider updates identities with PUT, which would
# drop the permission, so tofu never updates this one (ignore_changes);
# change it by replacing the resource.
#
# Enrolment: scripts/ziti-enroll-proxy.sh mesh-exporter mljr ziti-mesh-exporter
resource "ziti_identity" "mesh_exporter" {
  name           = "mesh-exporter"
  type           = "Default"
  auth_policy_id = "default"

  lifecycle {
    ignore_changes = all
  }
}

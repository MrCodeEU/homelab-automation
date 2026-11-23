# Login for Ziti's web console (ZAC, services/ziti-console on mljr):
# username/password, permission admin_readonly. Neither is something the
# provider knows: scripts/ziti-tofu.sh sets the permission from
# permissions.txt and the password authenticator from updb.txt (password
# vault_ziti_zac_password, in /opt/ziti-controller/.env). ignore_changes =
# all for the same reason as mesh-exporter.tf: the provider's PUT would
# drop the permission. The OTT enrolment the provider creates is never
# used and expires (edge.enrollment.edgeIdentity.duration).
#
# No role attributes, no policies: the console only reads the management
# API; it dials nothing.
resource "ziti_identity" "zac_readonly" {
  name           = "zac-readonly"
  type           = "Default"
  auth_policy_id = "default"

  lifecycle {
    ignore_changes = all
  }
}

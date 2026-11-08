# mljr's Caddy dials home services over Ziti itself, with the ziti
# reverse_proxy transport (services/caddy-poc/ziti-caddy). It has its own
# identity, enrolled once on mljr by scripts/ziti-enroll-caddy.sh into
# /etc/caddy/ziti/caddy-mljr.json, and may dial only services with the
# attribute caddy (catalog entries with ziti_via_caddy, catalog.tf). It
# hosts nothing.
resource "ziti_identity" "caddy_mljr" {
  name           = "caddy-mljr"
  type           = "Default"
  auth_policy_id = "default"
  # Explicitly empty: the controller stores [], and an unset list plans
  # [] -> null on every run.
  role_attributes = []
}

resource "ziti_service_policy" "caddy_dial" {
  name          = "caddy-dial"
  type          = "Dial"
  semantic      = "AnyOf"
  identityroles = ["@${ziti_identity.caddy_mljr.id}"]
  serviceroles  = ["#caddy"]
}

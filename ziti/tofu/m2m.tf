# Machine-to-machine consumers that cannot dial Ziti themselves (Grafana
# Alloy) go through `ziti tunnel proxy` on their host (services/ziti-proxy),
# one identity per host, enrolled on that host by scripts/ziti-enroll-proxy.sh
# so the key never leaves it. Each identity may dial only the services
# listed here, by name; it hosts nothing.
locals {
  m2m = {
    # Alloy on mljr -> VictoriaMetrics and Loki on nuc
    "m2m-mljr" = ["grafana-victoriametrics", "grafana-loki"]
  }
}

resource "ziti_identity" "m2m" {
  for_each       = local.m2m
  name           = each.key
  type           = "Default"
  auth_policy_id = "default"
  # Explicitly empty, as caddy-mljr (caddy.tf): avoids a [] -> null diff.
  role_attributes = []
}

resource "ziti_service_policy" "m2m_dial" {
  for_each      = local.m2m
  name          = "${each.key}-dial"
  type          = "Dial"
  semantic      = "AnyOf"
  identityroles = ["@${ziti_identity.m2m[each.key].id}"]
  serviceroles  = sort([for s in each.value : "@${ziti_service.catalog[s].id}"])
}

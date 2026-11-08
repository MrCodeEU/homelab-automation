# Machine-to-machine consumers that cannot dial Ziti themselves go through
# `ziti tunnel proxy`: one per host for host-network apps (Alloy,
# services/ziti-proxy*), one inside the compose project for a bridged app
# (homepage). Each has its own identity, enrolled on its host by
# scripts/ziti-enroll-proxy.sh so the key never leaves it. Each identity may dial only the services
# listed here, by name; it hosts nothing.
locals {
  m2m = {
    # Alloy on mljr -> VictoriaMetrics and Loki on nuc
    "m2m-mljr" = ["grafana-victoriametrics", "grafana-loki"]
    # Alloy on ugreen -> the same
    "m2m-ugreen" = ["grafana-victoriametrics", "grafana-loki"]
    # homepage on mljr (live homelab panel) -> VictoriaMetrics, PromQL
    "homepage-mljr" = ["grafana-victoriametrics"]
    # CrowdSec agent on nuc -> mljr's LAPI (crowdsec-nas stays on the
    # tailnet until nas is on Ziti, Phase 5)
    "crowdsec-nuc" = ["crowdsec-lapi"]
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

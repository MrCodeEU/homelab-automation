# Default deny, everything by role attribute: identities with #admin, and
# those in the Authelia group admins (#admins), may dial #admin-services.
resource "ziti_service_policy" "admin_dial" {
  name          = "admin-dial"
  type          = "Dial"
  semantic      = "AnyOf"
  identityroles = sort(["#admin", "#admins"])
  serviceroles  = ["#admin-services"]
}

# Edge routers by where an identity runs (C6, docs/ZERO_TRUST_PLAN.md
# Phase 4). Routers: mljr #public, nuc and ugreen #lan. A machine identity
# connects only to the routers of its own site, so its circuits start
# there: from home never through mljr, from mljr never into a LAN listener
# over Tailscale's subnet route. People's devices roam and may use any
# router (the LAN ones only answer at home). The routers' own tunneler
# identities have their system policies (edge-router-<id>-system).
resource "ziti_edge_router_policy" "at_mljr" {
  name            = "at-mljr-public-router"
  semantic        = "AnyOf"
  identityroles   = ["#at-mljr"]
  edgerouterroles = ["#public"]
}

resource "ziti_edge_router_policy" "at_home" {
  name            = "at-home-lan-routers"
  semantic        = "AnyOf"
  identityroles   = sort(["#at-home", "#spike"])
  edgerouterroles = ["#lan"]
}

resource "ziti_edge_router_policy" "roaming" {
  name            = "roaming-all-routers"
  semantic        = "AnyOf"
  identityroles   = sort(["#admin", "#admins", "#mobile"])
  edgerouterroles = ["#all"]
}

# Being replaced by the three above: removed in a separate apply once every
# identity is verified on its new routers (a delete, held for a manual
# apply).
resource "ziti_edge_router_policy" "all" {
  name            = "all-identities-all-routers"
  semantic        = "AnyOf"
  identityroles   = ["#all"]
  edgerouterroles = ["#all"]
}

# Every service on every router: none is LAN-only. Each is dialed from mljr
# (caddy-mljr, m2m-mljr) or is an #admin-service a roaming device reaches
# through mljr away from home, so every one needs #public, and its host's
# router hosts it. Restrict a service here once it is LAN-only, after
# C6 LAN (scripts/ziti-c6-iperf.sh lan).
resource "ziti_service_edge_router_policy" "all" {
  name            = "all-services-all-routers"
  semantic        = "AnyOf"
  serviceroles    = ["#all"]
  edgerouterroles = ["#all"]
}

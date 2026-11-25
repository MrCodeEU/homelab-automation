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
# Phase 4). Routers: mljr #public, nuc, ugreen and nas #lan. A machine identity
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
  identityroles   = ["#at-home"]
  edgerouterroles = ["#lan"]
}

# Roaming devices get the routers they can reach, #public and #lan, not
# #all: a router outside both (the DR drill VM's, 2026-11-25) may sit
# behind a NAT no client can reach.
resource "ziti_edge_router_policy" "roaming" {
  name            = "roaming-all-routers"
  semantic        = "AnyOf"
  identityroles   = sort(["#admin", "#admins", "#mobile"])
  edgerouterroles = sort(["#public", "#lan"])
}

# An identity without #at-mljr, #at-home or a roaming attribute gets no
# edge router at all, so it cannot connect: give every new identity one.

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

# Default deny, everything by role attribute: identities with #admin, and
# those in the Authelia group admins (#admins), may dial #admin-services.
resource "ziti_service_policy" "admin_dial" {
  name          = "admin-dial"
  type          = "Dial"
  semantic      = "AnyOf"
  identityroles = sort(["#admin", "#admins"])
  serviceroles  = ["#admin-services"]
}

# Every identity may use every router, every service every router. C6:
# replaced by attribute-based policies and link groups before any LAN-only
# service goes on Ziti.
resource "ziti_edge_router_policy" "all" {
  name            = "all-identities-all-routers"
  semantic        = "AnyOf"
  identityroles   = ["#all"]
  edgerouterroles = ["#all"]
}

resource "ziti_service_edge_router_policy" "all" {
  name            = "all-services-all-routers"
  semantic        = "AnyOf"
  serviceroles    = ["#all"]
  edgerouterroles = ["#all"]
}

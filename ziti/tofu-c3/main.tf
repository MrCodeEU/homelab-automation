# C3 test fixture (docs/ZERO_TRUST_PLAN.md): create, update and delete the
# object kinds scripts/ziti-poc-objects.sh manages, through the
# netfoundry/ziti provider. Run only by scripts/ziti-c3-tofu.sh. Every role
# is a c3-* attribute that no real identity, service or router carries, so
# these objects grant nothing.
#
# variant 1: initial objects. variant 2: changed port, roles and attributes,
# and the service-edge-router policy removed.

terraform {
  required_providers {
    ziti = {
      source  = "netfoundry/ziti"
      version = "= 2.2.1"
    }
  }
}

# ZITI_API_HOST, ZITI_API_USERNAME, ZITI_API_PASSWORD from the environment.
provider "ziti" {}

variable "variant" {
  type = number
}

locals {
  v2   = var.variant == 2
  port = local.v2 ? 7002 : 7001
}

resource "ziti_intercept_v1_config" "c3" {
  name      = "c3-intercept"
  addresses = ["c3.int.mljr.eu"]
  protocols = ["tcp"]
  port_ranges = [{
    low  = local.port
    high = local.port
  }]
  # Same addressable-terminator shape as the ssh service.
  dial_options = {
    identity = "$dst_hostname"
  }
}

resource "ziti_host_v1_config" "c3" {
  name     = "c3-host"
  protocol = "tcp"
  address  = "127.0.0.1"
  port     = local.port
  listen_options = {
    bind_using_edge_identity = true
  }
}

resource "ziti_service" "c3" {
  name            = "c3"
  configs         = [ziti_intercept_v1_config.c3.id, ziti_host_v1_config.c3.id]
  role_attributes = local.v2 ? ["c3-services", "c3-extra"] : ["c3-services"]
}

resource "ziti_service_policy" "c3_bind" {
  name          = "c3-bind"
  type          = "Bind"
  semantic      = "AnyOf"
  identityroles = local.v2 ? ["#c3-hosts", "#c3-other"] : ["#c3-hosts"]
  serviceroles  = ["#c3-services"]
}

resource "ziti_service_policy" "c3_dial" {
  name          = "c3-dial"
  type          = "Dial"
  semantic      = "AnyOf"
  identityroles = ["#c3-clients"]
  serviceroles  = ["#c3-services"]
}

resource "ziti_edge_router_policy" "c3" {
  name            = "c3-erp"
  semantic        = "AnyOf"
  identityroles   = ["#c3-clients"]
  # The controller returns role lists sorted and the provider compares them
  # as ordered lists: an unsorted list never converges (perpetual diff, seen
  # with ["#c3-routers", "#c3-lan"]). Write every role list sorted.
  edgerouterroles = local.v2 ? ["#c3-lan", "#c3-routers"] : ["#c3-routers"]
}

resource "ziti_service_edge_router_policy" "c3" {
  count           = local.v2 ? 0 : 1
  name            = "c3-serp"
  semantic        = "AnyOf"
  serviceroles    = ["#c3-services"]
  edgerouterroles = ["#c3-routers"]
}

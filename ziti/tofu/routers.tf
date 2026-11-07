# Routers are enrolled by scripts/ziti-enroll-router.sh; their identities
# are looked up here to bind services. A router's identity is named after
# its certname.
data "ziti_identity" "router" {
  for_each = toset(["mljr.int.mljr.eu", "nuc.int.mljr.eu", "ugreen.int.mljr.eu"])
  name     = each.key
}

locals {
  router = { for name, r in data.ziti_identity.router : split(".", name)[0] => "@${r.id}" }
}

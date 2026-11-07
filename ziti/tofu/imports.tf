# Adoption of the objects the Phase 3 script (scripts/ziti-poc-objects.sh,
# removed) created.
# Harmless once they are in state; remove after the first apply.
import {
  to = ziti_external_jwt_signer.authelia
  id = "4cZ8U7LUR410dMFxadBX5Y"
}
import {
  to = ziti_external_jwt_signer.github_actions
  id = "6LpNh3s2XXQXJ6P1VI2akZ"
}
import {
  to = ziti_auth_policy.ci_github
  id = "2ztCoRQprpWDs0fWhdRbpS"
}
import {
  to = ziti_identity.idp_admin
  id = "Qt8xy..h-"
}
import {
  to = ziti_identity.ci_ziti_c4
  id = "eDlj-yyTY"
}
import {
  to = ziti_service_policy.admin_dial
  id = "TxrCzEUPobZF5GQBXqjL1"
}
import {
  to = ziti_edge_router_policy.all
  id = "27N0PoP50VQvxX08SL8qZd"
}
import {
  to = ziti_service_edge_router_policy.all
  id = "dQOTDDMCxfEWRhr4yeAiT"
}
import {
  to = ziti_intercept_v1_config.nuc_alloy
  id = "20IT6wUFsxeOWWXKLZ9zLh"
}
import {
  to = ziti_host_v1_config.nuc_alloy
  id = "phD1pPMULX8iXQxOgfMPY"
}
import {
  to = ziti_service.nuc_alloy
  id = "21DtfbbU7XzvGdsWaaYATc"
}
import {
  to = ziti_service_policy.nuc_alloy_bind
  id = "4VByQcOwDI1SfeGLRgRdON"
}
import {
  to = ziti_service_policy.nuc_alloy_ci_dial
  id = "29olaH1XvDtw2sU5i2ebn9"
}
import {
  to = ziti_intercept_v1_config.ssh
  id = "3owsKmiqXFJOlZNj7HEl56"
}
import {
  to = ziti_host_v1_config.ssh
  id = "DCvkwV1WUN8rWu9W4HrnP"
}
import {
  to = ziti_service.ssh
  id = "23wJHw2UK9dqxSPzSVzKrR"
}
import {
  to = ziti_service_policy.ssh_bind
  id = "4HjhHfjlwHNJnI75shKbbB"
}

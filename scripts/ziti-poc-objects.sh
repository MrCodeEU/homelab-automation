#!/usr/bin/env bash
# Ziti PoC services and policies (docs/ZERO_TRUST_PLAN.md Phase 3). Idempotent:
# creates what is missing, updates what exists to match this file. Rerun after
# any edit. Hand-written CLI on purpose: C3 decides whether OpenTofu takes this
# over.
#
# Model (default deny, everything by role attribute):
#   - identities with #admin may dial services with #admin-services, and so
#     may identities in the Authelia group admins (#admins, C15)
#   - ext-jwt signer authelia (C15): the tunneler logs in through Authelia
#     (client ziti) and a new device enrols with that login alone
#     (enroll-to-cert or enroll-to-token, no enrolment file). The identity
#     is named after preferred_username, gets the Authelia groups as
#     attributes and is matched by the OIDC sub (external id).
#   - each service is bound (hosted) by named router identities (@name)
#   - every identity may use every router, every service every router
#
# Services:
#   nuc-alloy  alloy.nuc.int.mljr.eu:12345 -> nuc 127.0.0.1:12345 (Grafana
#              Alloy's metrics endpoint; nuc runs no node-exporter)
#   ssh        <host>.int.mljr.eu:22 -> 127.0.0.1:22 on that host (C10).
#              Addressable terminators: the client dials the terminator named
#              after the intercepted hostname ($dst_hostname); each hosting
#              router binds under its own identity name, which is the host's
#              certname (<host>.int.mljr.eu). The intercept lists only hosts
#              that are on Ziti, not *.int.mljr.eu: a wildcard makes every
#              name resolve while the tunneler is up, so SSH canonicalization
#              (ziti/laptop/ssh-int-mljr-eu.conf) could never fall back for
#              hosts still on Tailscale only. Routers are named after their certname for
#              this: the router-embedded tunneler does not resolve
#              $tunneler_id.tag[...] (the terminator got the literal string).
#
# Usage: scripts/ziti-poc-objects.sh
set -euo pipefail

CTRL_HOST=root@mljr.tail33930.ts.net

# The remote part runs on mljr; nothing below is expanded locally.
ssh "$CTRL_HOST" bash -s <<'REMOTE'
set -euo pipefail
set -a; . /opt/ziti-controller/.env; set +a
z() { docker exec ziti-controller ziti "$@"; }
z edge login localhost:8440 -u admin -p "$ZITI_ADMIN_PASSWORD" -y >/dev/null
unset ZITI_ADMIN_PASSWORD

exists() { z edge list "$1" "name=\"$2\"" -j | grep -q "\"name\": *\"$2\""; }

config() { # name type json
  if exists configs "$1"; then z edge update config "$1" -d "$3" >/dev/null; echo "config $1: updated"
  else z edge create config "$1" "$2" "$3" >/dev/null; echo "config $1: created"; fi
}
service() { # name attrs configs
  if exists services "$1"; then z edge update service "$1" -a "$2" -c "$3" >/dev/null; echo "service $1: updated"
  else z edge create service "$1" -a "$2" -c "$3" >/dev/null; echo "service $1: created"; fi
}
service_policy() { # name Bind|Dial identity-roles service-roles
  if exists service-policies "$1"; then
    z edge update service-policy "$1" --identity-roles "$3" --service-roles "$4" >/dev/null; echo "service-policy $1: updated"
  else
    z edge create service-policy "$1" "$2" --identity-roles "$3" --service-roles "$4" >/dev/null; echo "service-policy $1: created"
  fi
}
ext_jwt_signer() { # name, then the options shared by create and update
  local name=$1; shift
  if exists ext-jwt-signers "$name"; then
    z edge update ext-jwt-signer "$name" "$@" >/dev/null; echo "ext-jwt-signer $name: updated"
  else
    z edge create ext-jwt-signer "$name" "https://auth.mljr.eu" "$@" >/dev/null; echo "ext-jwt-signer $name: created"
  fi
}
idp_identity() { # name external-id(OIDC sub) attrs
  if exists identities "$1"; then
    z edge update identity "$1" --external-id "$2" -a "$3" >/dev/null; echo "identity $1: updated"
  else
    z edge create identity "$1" --external-id "$2" -a "$3" -P Default >/dev/null; echo "identity $1: created"
  fi
}
edge_router_policy() { # name identity-roles router-roles
  if exists edge-router-policies "$1"; then
    z edge update edge-router-policy "$1" --identity-roles "$2" --edge-router-roles "$3" >/dev/null; echo "edge-router-policy $1: updated"
  else
    z edge create edge-router-policy "$1" --identity-roles "$2" --edge-router-roles "$3" >/dev/null; echo "edge-router-policy $1: created"
  fi
}
serp() { # name service-roles router-roles
  if exists service-edge-router-policies "$1"; then
    z edge update service-edge-router-policy "$1" --service-roles "$2" --edge-router-roles "$3" >/dev/null; echo "serp $1: updated"
  else
    z edge create service-edge-router-policy "$1" --service-roles "$2" --edge-router-roles "$3" >/dev/null; echo "serp $1: created"
  fi
}

# --- shared policies ---------------------------------------------------------
# Before any service: a router whose first terminator request is rejected
# ("invalid edge router for session", no router policy yet) does not retry
# until it restarts. Seen 2026-11-06.
service_policy admin-dial Dial '#admin,#admins' '#admin-services'
# The controller fetches Authelia's keys over the public internet (it runs
# on mljr, next to Authelia). Audience and client id are the Authelia
# client; the ID token is used because Authelia's access tokens are opaque.
ext_jwt_signer authelia -u https://auth.mljr.eu/jwks.json -a ziti \
  --client-id ziti --scopes profile,email,groups --target-token ID \
  -c sub -x -y https://auth.mljr.eu \
  --enroll-to-cert --enroll-to-token \
  --enroll-name-claims-selector /preferred_username \
  --enroll-attr-claims-selector /groups
# One identity per Authelia user, matched by the OIDC sub; every device of
# that user logs in as it (ext-jwt-login after `add` with the network JWT).
# Needed because enroll-to-cert/-token fetches /network-jwts with the OS
# trust store, and the client API's certificate is from our private CA (C15).
idp_identity idp-admin 4a76133b-3e28-4917-b53e-5f46367f23bc admins
edge_router_policy all-identities-all-routers '#all' '#all'
serp all-services-all-routers '#all' '#all'

# --- nuc-alloy ---------------------------------------------------------------
config nuc-alloy-intercept intercept.v1 \
  '{"protocols":["tcp"],"addresses":["alloy.nuc.int.mljr.eu"],"portRanges":[{"low":12345,"high":12345}]}'
config nuc-alloy-host host.v1 '{"protocol":"tcp","address":"127.0.0.1","port":12345}'
service nuc-alloy admin-services nuc-alloy-intercept,nuc-alloy-host
service_policy nuc-alloy-bind Bind '@nuc.int.mljr.eu' '@nuc-alloy'

# --- ssh (wildcard, addressable terminators) ---------------------------------
config ssh-intercept intercept.v1 \
  '{"protocols":["tcp"],"addresses":["mljr.int.mljr.eu","nuc.int.mljr.eu","ugreen.int.mljr.eu"],"portRanges":[{"low":22,"high":22}],"dialOptions":{"identity":"$dst_hostname"}}'
config ssh-host host.v1 \
  '{"protocol":"tcp","address":"127.0.0.1","port":22,"listenOptions":{"bindUsingEdgeIdentity":true}}'
service ssh admin-services ssh-intercept,ssh-host
service_policy ssh-bind Bind '@mljr.int.mljr.eu,@nuc.int.mljr.eu,@ugreen.int.mljr.eu' '@ssh'

z edge logout >/dev/null 2>&1 || true
REMOTE

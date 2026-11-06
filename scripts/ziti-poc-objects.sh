#!/usr/bin/env bash
# Ziti PoC services and policies (docs/ZERO_TRUST_PLAN.md Phase 3). Idempotent:
# creates what is missing, updates what exists to match this file. Rerun after
# any edit. Hand-written CLI on purpose: C3 decides whether OpenTofu takes this
# over.
#
# Model (default deny, everything by role attribute):
#   - identities with #admin may dial services with #admin-services
#   - each service is bound (hosted) by exactly one router identity (@name)
#   - every identity may use every router, every service every router
#
# Services:
#   nuc-alloy  alloy.nuc.int.mljr.eu:12345 -> nuc 127.0.0.1:12345 (Grafana
#              Alloy's metrics endpoint; nuc runs no node-exporter)
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
service_policy admin-dial Dial '#admin' '#admin-services'
edge_router_policy all-identities-all-routers '#all' '#all'
serp all-services-all-routers '#all' '#all'

# --- nuc-alloy ---------------------------------------------------------------
config nuc-alloy-intercept intercept.v1 \
  '{"protocols":["tcp"],"addresses":["alloy.nuc.int.mljr.eu"],"portRanges":[{"low":12345,"high":12345}]}'
config nuc-alloy-host host.v1 '{"protocol":"tcp","address":"127.0.0.1","port":12345}'
service nuc-alloy admin-services nuc-alloy-intercept,nuc-alloy-host
service_policy nuc-alloy-bind Bind '@nuc' '@nuc-alloy'

z edge logout >/dev/null 2>&1 || true
REMOTE

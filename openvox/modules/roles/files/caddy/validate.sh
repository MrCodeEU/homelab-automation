#!/usr/bin/env bash
# Validates the staged config before it's ever promoted to the live
# paths - Puppet writes the staging copy via file resources, this exec
# runs after those and before promote-apply.sh. Read-only, never mutates.
#
# Inherited limitation from the already-validated spot port: the
# Caddyfile's own `import` directive is hardcoded to the LIVE
# /etc/caddy/conf.d/*.caddy path (render-caddy always emits that, not
# the staging path), so this only actually re-validates the staged
# top-level Caddyfile structure - a broken NEW service snippet in
# conf.d.openvox-staging is not caught here, only pre-existing live
# snippets are. Not introduced by this port; not fixed here either,
# matching the same scope-boundary precedent as other "match reality,
# don't improve on it mid-port" decisions elsewhere in this migration.
set -euo pipefail
# The unit gets this through EnvironmentFile=; validation runs outside it, and
# {env.CROWDSEC_BOUNCER_KEY} in the staged Caddyfile would otherwise be empty.
if [ -r /etc/caddy/crowdsec.env ]; then
  set -a
  # shellcheck source=/dev/null
  . /etc/caddy/crowdsec.env
  set +a
fi
if ! "${CADDY_BIN:-caddy}" validate --adapter caddyfile --config /etc/caddy/Caddyfile.openvox-staging 2>&1; then
  echo "FAILED: staged Caddyfile does not validate" >&2
  exit 1
fi

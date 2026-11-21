#!/usr/bin/env bash
# Grants everyone read-write on each whitelisted topic, so
# auth-default-access: deny-all (server.yml) only actually blocks topics
# NOT in the list. `ntfy access` edits the auth db directly and is safe to
# re-run - idempotent by design, no existing-grant check needed, matching
# how this hook is unconditionally re-run on every apply
# (services_common/post-deploy-hook.sh).
#
# NTFY_TOPIC_WHITELIST is a comma-separated list rendered into .env from
# ntfy_topic_whitelist in openvox/data/common.yaml.
set -euo pipefail

# `docker compose up -d` (compose-deploy.sh) only recreates a container when
# the compose config itself changes (image, env, labels) - it does not hash
# bind-mounted file *content*, so a server.yml edit alone never reaches the
# running process. Confirmed live 2026-09-02: auth-default-access: deny-all
# shipped and this hook's grants ran, but the container was still serving
# the old (fully open) config until restarted by hand. Restart here when
# server.yml differs from the one ntfy was last restarted with (stamp, as
# in the ziti-router hook), not on every deploy: each restart drops every
# open subscription.
stamp=.config-restarted.sha256
want=$(sha256sum server.yml | cut -d' ' -f1)
if [ "$(cat "$stamp" 2>/dev/null)" != "$want" ]; then
  docker restart ntfy >/dev/null
  printf '%s\n' "$want" >"$stamp"
  echo "ntfy: server.yml changed - restarted"
else
  echo "ntfy: server.yml unchanged - not restarted"
fi
for attempt in $(seq 1 30); do
  if docker exec ntfy ntfy access >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" -eq 30 ]; then
    echo "FAILED: ntfy is not answering." >&2
    exit 1
  fi
  sleep 1
done

if [ -z "${NTFY_TOPIC_WHITELIST:-}" ]; then
  echo "WARNING: NTFY_TOPIC_WHITELIST is empty - no topics will be reachable while auth-default-access is deny-all." >&2
  exit 0
fi

IFS=',' read -ra topics <<<"$NTFY_TOPIC_WHITELIST"
for topic in "${topics[@]}"; do
  topic="$(echo "$topic" | xargs)"
  [ -z "$topic" ] && continue
  if docker exec ntfy ntfy access everyone "$topic" read-write >/dev/null 2>&1; then
    echo "SUCCESS: granted everyone read-write on topic '${topic}'."
  else
    echo "WARNING: failed to grant access on topic '${topic}'." >&2
  fi
done

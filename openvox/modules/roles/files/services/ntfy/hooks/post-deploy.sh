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

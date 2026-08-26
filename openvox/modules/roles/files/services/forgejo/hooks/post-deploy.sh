#!/usr/bin/env bash
set -euo pipefail

SERVICE_PATH="${2:-$(pwd)}"
RUNNER_SECRET="${FORGEJO_RUNNER_SECRET:-}"

# roles/backup's fresh-install restore runs before Docker Services brings
# any container up at all (see roles/backup/tasks/main.yml - backup runs
# before services in the play), so its restore_post_hook's psql import
# fails there: forgejo-db doesn't exist yet to docker exec into. The
# file-level restore still succeeds though (plain rclone, no container
# needed), leaving the dump sitting on disk unimported. A leftover dump
# file at this path only ever means "restore ran, import didn't" - finish
# it now that forgejo-db is actually up, before touching the runner.
FORGEJO_DUMP_FILE="/opt/backups/forgejo-dumps/forgejo.sql"
if [ -s "${FORGEJO_DUMP_FILE}" ]; then
  for i in $(seq 1 30); do
    docker exec forgejo-db pg_isready >/dev/null 2>&1 && break
    if [ "${i}" -eq 30 ]; then
      echo "FAILED: forgejo-db never became ready - dump left in place for the next deploy to retry."
      exit 1
    fi
    sleep 2
  done
  if ! docker exec -i forgejo-db sh -c 'psql -U "$POSTGRES_USER" "$POSTGRES_DB"' < "${FORGEJO_DUMP_FILE}"; then
    echo "FAILED: psql import failed - dump left in place for the next deploy to retry."
    exit 1
  fi
  rm -f "${FORGEJO_DUMP_FILE}"
  echo "Fresh-install restore dump imported into forgejo-db."
fi

if [[ ! "${RUNNER_SECRET}" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "FAILED: FORGEJO_RUNNER_SECRET must be exactly 40 hexadecimal characters. Generate with: openssl rand -hex 20"
  exit 1
fi

for attempt in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:3300/ >/dev/null 2>&1; then
    break
  fi

  if [ "${attempt}" -eq 60 ]; then
    echo "FAILED: Forgejo did not become ready on http://127.0.0.1:3300/."
    exit 1
  fi

  sleep 2
done

register_output="$(docker exec --user 1000:1000 forgejo-app forgejo forgejo-cli actions register \
  --name nuc-runner \
  --secret "${RUNNER_SECRET}" 2>&1)" || {
  echo "FAILED: Forgejo runner registration failed."
  printf '%s\n' "${register_output}" | sed -E 's/[0-9a-fA-F]{40}/<redacted-secret>/g'
  exit 1
}

runner_uuid="$(printf '%s\n' "${register_output}" | tail -n 1 | tr -d '\r\n')"

if [[ ! "${runner_uuid}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  echo "FAILED: Unexpected Forgejo runner UUID returned: ${runner_uuid}"
  exit 1
fi

mkdir -p "${SERVICE_PATH}/runner-data/.cache"
chmod 775 "${SERVICE_PATH}/runner-data/.cache"
chown -R 1000:1000 "${SERVICE_PATH}/runner-data"

cat > "${SERVICE_PATH}/runner-data/runner-config.yml" <<EOF
log:
  level: info

runner:
  file: /data/.runner
  # One job per DinD daemon prevents concurrent workflows from inspecting or
  # mutating each other's containers, volumes, and build state.
  capacity: 1
  timeout: 3h
  insecure: false
  fetch_timeout: 5s
  fetch_interval: 2s
  labels:
    - docker:docker://ghcr.io/catthehacker/ubuntu:act-22.04
    - ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-22.04
    - self-hosted:docker://ghcr.io/catthehacker/ubuntu:act-22.04

cache:
  enabled: true
  dir: /data/.cache
  host: ""
  port: 0

container:
  network: ""
  privileged: false
  options:
  workdir_parent:
  valid_volumes: []
  docker_host: tcp://runner-dind:2375
  force_pull: false
  force_rebuild: false

host:
  workdir_parent:

server:
  connections:
    forgejo:
      url: http://forgejo:3000/
      uuid: ${runner_uuid}
      token: ${RUNNER_SECRET}
EOF

chown 1000:1000 "${SERVICE_PATH}/runner-data/runner-config.yml"
chmod 600 "${SERVICE_PATH}/runner-data/runner-config.yml"

docker restart forgejo-runner >/dev/null
echo "SUCCESS: Forgejo Actions runner registered as nuc-runner (${runner_uuid}) and restarted."

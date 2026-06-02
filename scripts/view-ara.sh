#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_NAME="${ARA_WORKFLOW_NAME:-Deploy Homelab}"
RUN_ID="${RUN_ID:-}"
PORT="${ARA_PORT:-8000}"
BASE_DIR="${ARA_DIR:-/tmp/homelab-ara}"

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh is required. Install GitHub CLI and authenticate with 'gh auth login'." >&2
  exit 1
fi

if ! command -v ara-manage >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: ara-manage is required.

Install ARA locally:
  pip install "ara[server]"

Or, if you use pipx:
  pipx install "ara[server]"
EOF
  exit 1
fi

if [ -z "$RUN_ID" ]; then
  echo "==> Finding latest completed '${WORKFLOW_NAME}' run with an ARA artifact"
  RUN_ID="$(
    gh run list \
      --workflow "$WORKFLOW_NAME" \
      --limit 20 \
      --json databaseId,status \
      --jq 'map(select(.status == "completed"))[0].databaseId // ""'
  )"
fi

if [ -z "$RUN_ID" ]; then
  echo "ERROR: could not find a completed '${WORKFLOW_NAME}' run. Set RUN_ID=<github run id> explicitly." >&2
  exit 1
fi

ARTIFACT_NAME="${ARA_ARTIFACT_NAME:-ara-report-${RUN_ID}}"
DEST_DIR="${BASE_DIR}/${RUN_ID}"
DB_PATH="${DEST_DIR}/ara/ansible.sqlite"
SETTINGS_PATH="${DEST_DIR}/ara-server-settings.yaml"

echo "==> Downloading ${ARTIFACT_NAME} from run ${RUN_ID}"
mkdir -p "$BASE_DIR"
rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"

if ! gh run download "$RUN_ID" -n "$ARTIFACT_NAME" -D "$DEST_DIR"; then
  cat >&2 <<EOF
ERROR: failed to download '${ARTIFACT_NAME}'.

The run may not have uploaded an ARA artifact yet, or the artifact retention window may have expired.
Run URL: https://github.com/$(gh repo view --json nameWithOwner --jq .nameWithOwner)/actions/runs/${RUN_ID}
EOF
  exit 1
fi

if [ ! -f "$DB_PATH" ]; then
  echo "ERROR: ARA database not found at ${DB_PATH}" >&2
  echo "Downloaded files:" >&2
  find "$DEST_DIR" -maxdepth 3 -type f -print >&2
  exit 1
fi

URL="http://127.0.0.1:${PORT}"

cat > "$SETTINGS_PATH" <<EOF
---
default:
  ALLOWED_HOSTS:
    - ::1
    - 127.0.0.1
    - localhost
  BASE_DIR: "${DEST_DIR}"
  BASE_PATH: /
  CORS_ORIGIN_ALLOW_ALL: false
  CORS_ORIGIN_REGEX_WHITELIST: []
  CORS_ORIGIN_WHITELIST:
    - "${URL}"
    - "http://localhost:${PORT}"
  CSRF_TRUSTED_ORIGINS: []
  DATABASE_CONN_MAX_AGE: 0
  DATABASE_ENGINE: django.db.backends.sqlite3
  DATABASE_HOST: null
  DATABASE_NAME: "${DB_PATH}"
  DATABASE_OPTIONS: {}
  DATABASE_PASSWORD: null
  DATABASE_PORT: null
  DATABASE_USER: null
  DEBUG: false
  DISTRIBUTED_SQLITE: false
  DISTRIBUTED_SQLITE_PREFIX: ara-report
  DISTRIBUTED_SQLITE_ROOT: "${BASE_DIR}"
  EXTERNAL_AUTH: false
  LOGGING:
    disable_existing_loggers: false
    formatters:
      normal:
        format: '%(asctime)s %(levelname)s %(name)s: %(message)s'
    handlers:
      console:
        class: logging.StreamHandler
        formatter: normal
        level: INFO
        stream: ext://sys.stdout
    loggers:
      ara:
        handlers:
          - console
        level: INFO
        propagate: 0
    version: 1
  LOG_LEVEL: INFO
  PAGE_SIZE: 100
  READ_LOGIN_REQUIRED: false
  SECRET_KEY: "local-ara-artifact-viewer-${RUN_ID}"
  TIME_ZONE: Europe/Vienna
  WRITE_LOGIN_REQUIRED: false
EOF

export ARA_SETTINGS="$SETTINGS_PATH"
export ARA_DATABASE="sqlite:///${DB_PATH}"

echo "==> Starting ARA UI for run ${RUN_ID}"
echo "    Database: ${DB_PATH}"
echo "    Settings: ${SETTINGS_PATH}"
echo "    URL:      ${URL}"

if command -v sqlite3 >/dev/null 2>&1; then
  echo "==> ARA record counts"
  sqlite3 "$DB_PATH" "select 'playbooks=' || count(*) from playbooks; select 'tasks=' || count(*) from tasks; select 'results=' || count(*) from results;" 2>/dev/null || true
fi

echo "==> Applying ARA server migrations to the local artifact copy"
ara-manage migrate --noinput

ara-manage runserver "127.0.0.1:${PORT}" &
SERVER_PID="$!"
trap 'kill "$SERVER_PID" >/dev/null 2>&1 || true' EXIT INT TERM

sleep 2
if [ -n "${BROWSER:-}" ]; then
  "$BROWSER" "$URL" >/dev/null 2>&1 || true
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$URL" >/dev/null 2>&1 || true
elif command -v open >/dev/null 2>&1; then
  open "$URL" >/dev/null 2>&1 || true
fi

echo "==> Press Ctrl-C to stop the ARA UI"
wait "$SERVER_PID"

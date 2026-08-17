#!/usr/bin/env bash
set -euo pipefail

# See services/mail-archiver/hooks/post-deploy.sh for the full explanation -
# same fresh-install gap: roles/backup runs before services in the play, so
# its restore_post_hook's psql import fails (nocturne-postgres doesn't
# exist yet). The dump still lands on disk via plain rclone though. This
# hook finishes the import once nocturne-postgres is actually running.
DUMP_FILE="/opt/backups/nocturne-dumps/nocturne.sql"

if [ ! -s "${DUMP_FILE}" ]; then
  echo "SUCCESS: no pending restore dump - nothing to do."
  exit 0
fi

for i in $(seq 1 30); do
  docker exec nocturne-postgres pg_isready >/dev/null 2>&1 && break
  if [ "${i}" -eq 30 ]; then
    echo "FAILED: nocturne-postgres never became ready - dump left in place for the next deploy to retry."
    exit 1
  fi
  sleep 2
done

if ! docker exec -i nocturne-postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" "$POSTGRES_DB"' < "${DUMP_FILE}"; then
  echo "FAILED: psql import failed - dump left in place for the next deploy to retry."
  exit 1
fi

rm -f "${DUMP_FILE}"
echo "SUCCESS: fresh-install restore dump imported into nocturne-postgres."

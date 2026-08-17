#!/usr/bin/env bash
set -euo pipefail

# roles/backup's fresh-install restore runs before Docker Services brings
# any container up at all (see roles/backup/tasks/main.yml - backup runs
# before services in the play), so its restore_post_hook's psql import
# fails there: mail-archiver-db doesn't exist yet to docker exec into. The
# file-level restore still succeeds though (plain rclone, no container
# needed), leaving the dump sitting on disk unimported. This hook runs
# after mail-archiver-db is actually up and finishes the job - a leftover
# dump file at this path only ever means "restore ran, import didn't."
DUMP_FILE="/opt/backups/mail-archiver-dumps/mail-archiver.sql"

if [ ! -s "${DUMP_FILE}" ]; then
  echo "SUCCESS: no pending restore dump - nothing to do."
  exit 0
fi

for i in $(seq 1 30); do
  docker exec mail-archiver-db pg_isready >/dev/null 2>&1 && break
  if [ "${i}" -eq 30 ]; then
    echo "FAILED: mail-archiver-db never became ready - dump left in place for the next deploy to retry."
    exit 1
  fi
  sleep 2
done

if ! docker exec -i mail-archiver-db sh -c 'psql -U mailuser MailArchiver' < "${DUMP_FILE}"; then
  echo "FAILED: psql import failed - dump left in place for the next deploy to retry."
  exit 1
fi

rm -f "${DUMP_FILE}"
echo "SUCCESS: fresh-install restore dump imported into mail-archiver-db."

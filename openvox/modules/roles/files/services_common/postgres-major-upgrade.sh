#!/usr/bin/env bash
# One-shot, logical PostgreSQL major-version migration for a Compose service.
#
# It deliberately never starts a newer PostgreSQL image on the old data
# volume. Instead it copies that volume, starts the old image against the
# copy, creates a logical dump, imports it into a fresh target volume, and
# leaves the original volume untouched for rollback. The caller must run this
# before Compose starts the new database image.
set -euo pipefail
umask 077

usage() {
  echo "usage: $0 check MARKER | $0 apply DEPLOY_PATH SERVICE OLD_IMAGE NEW_IMAGE OLD_VOLUME NEW_VOLUME DATABASE USER DB_CONTAINER MARKER" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
mode="$1"
shift

if [ "$mode" = check ]; then
  [ "$#" = 1 ] || usage
  test -f "$1"
  exit $?
fi
[ "$mode" = apply ] || usage
[ "$#" = 10 ] || usage

deploy_path="$1"
service="$2"
old_image="$3"
new_image="$4"
old_volume="$5"
new_volume="$6"
database="$7"
username="$8"
db_container="$9"
marker="${10}"

if [ -f "$marker" ]; then
  echo "PostgreSQL major migration already completed: $marker"
  exit 0
fi

for binary in docker tar; do
  command -v "$binary" >/dev/null || { echo "missing required command: $binary" >&2; exit 1; }
done
docker volume inspect "$old_volume" >/dev/null
docker container inspect "$db_container" >/dev/null

# A partially-created target has unknown state. Do not guess or overwrite it;
# retain all evidence and require an explicit operator decision instead.
if docker volume inspect "$new_volume" >/dev/null 2>&1; then
  echo "target volume exists without completion marker: $new_volume" >&2
  exit 1
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
source_copy="${new_volume}-source-${timestamp}"
source_container="openvox-pg-upgrade-${service}-source-${timestamp}"
target_container="openvox-pg-upgrade-${service}-target-${timestamp}"
backup_dir="${deploy_path}/postgres-upgrade-backups"
dump_file="${backup_dir}/${service}-pre-pg18-${timestamp}.dump"

cleanup_containers() {
  docker rm -f "$source_container" "$target_container" >/dev/null 2>&1 || true
}
trap cleanup_containers EXIT

mkdir -p "$backup_dir"
chmod 0700 "$backup_dir"
docker volume create "$source_copy" >/dev/null
docker run --rm \
  -v "${old_volume}:/from:ro" \
  -v "${source_copy}:/to" \
  alpine:3.22 sh -c 'cd /from && tar cf - . | tar xf - -C /to'

docker run -d --name "$source_container" --network none \
  -v "${source_copy}:/var/lib/postgresql/data" \
  "$old_image" >/dev/null
for _ in $(seq 1 60); do
  if docker exec "$source_container" pg_isready -U "$username" -d "$database" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker exec "$source_container" pg_isready -U "$username" -d "$database" >/dev/null
docker exec "$source_container" pg_dump -U "$username" -d "$database" -Fc > "$dump_file"
test -s "$dump_file"

# Reuse the database credential already rendered into the currently running
# (or failed) Compose container without printing it into Puppet or CI logs.
db_password="$(docker inspect "$db_container" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^POSTGRES_PASSWORD=//p' | head -n1)"
test -n "$db_password"

docker volume create "$new_volume" >/dev/null
docker run -d --name "$target_container" --network none \
  -e "POSTGRES_DB=${database}" \
  -e "POSTGRES_USER=${username}" \
  -e "POSTGRES_PASSWORD=${db_password}" \
  -v "${new_volume}:/var/lib/postgresql" \
  "$new_image" >/dev/null
for _ in $(seq 1 60); do
  if docker exec "$target_container" pg_isready -U "$username" -d "$database" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker exec "$target_container" pg_isready -U "$username" -d "$database" >/dev/null
docker exec -i "$target_container" pg_restore -U "$username" -d "$database" --clean --if-exists --no-owner < "$dump_file"

version="$(docker exec "$target_container" psql -U "$username" -d "$database" -Atc 'SHOW server_version_num')"
case "$version" in
  18*) ;;
  *) echo "target PostgreSQL is not v18: $version" >&2; exit 1 ;;
esac

cat > "$marker" <<EOF
completed_at=${timestamp}
service=${service}
old_volume=${old_volume}
new_volume=${new_volume}
logical_dump=${dump_file}
target_postgres_version=${version}
EOF
chmod 0600 "$marker"

# The original volume and logical dump are intentionally retained. The source
# copy only served the read-only export and is now safe to remove.
docker volume rm "$source_copy" >/dev/null
echo "PostgreSQL v18 migration prepared for ${service}; original volume retained: ${old_volume}"

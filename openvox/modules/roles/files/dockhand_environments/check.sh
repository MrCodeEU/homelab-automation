#!/usr/bin/env bash
# Exits 0 (no work needed) if Dockhand on nas was last set from exactly this
# environments file (its sha256 stamp on nas matches) and the rows still
# have the wanted host and port (someone may have edited them in the UI).
set -euo pipefail
TARGET="nas-mgmt"
WANT=/var/lib/openvox-dockhand-environments/environments.tsv
DB=/mnt/user/appdata/dockhand/db/dockhand.db
STAMP=/mnt/user/appdata/dockhand/.openvox-environments.sha256

want_sum=$(sha256sum "$WANT" | cut -d' ' -f1)
[ "$(ssh -o BatchMode=yes "$TARGET" "cat $STAMP 2>/dev/null" || true)" = "$want_sum" ] || exit 1
rows=$(ssh -o BatchMode=yes "$TARGET" "sqlite3 -readonly -separator '	' $DB 'select name, host, port, connection_type from environments;'")
while IFS=$'\t' read -r name host port _token; do
  printf '%s\n' "$rows" | grep -qxF "${name}	${host}	${port}	hawser-standard" || exit 1
done <"$WANT"

#!/usr/bin/env bash
# Sets host, port and Hawser token of existing Dockhand environments on nas
# (rows matched by name, created once in Dockhand's UI) from the environments
# file, then restarts Dockhand: at startup it encrypts tokens it finds in
# plain text, and it reconnects with the new values. The SQL, tokens
# included, goes over stdin, never on a command line.
set -euo pipefail
TARGET="nas-mgmt"
WANT=/var/lib/openvox-dockhand-environments/environments.tsv
DB=/mnt/user/appdata/dockhand/db/dockhand.db
STAMP=/mnt/user/appdata/dockhand/.openvox-environments.sha256

q() { printf "'%s'" "${1//\'/\'\'}"; }
sql="BEGIN;"
count=0
while IFS=$'\t' read -r name host port token; do
  [[ $port =~ ^[0-9]+$ ]] || { echo "bad port for $name" >&2; exit 1; }
  sql+="UPDATE environments SET host=$(q "$host"), port=$port, protocol='http', connection_type='hawser-standard', hawser_token=$(q "$token") WHERE name=$(q "$name");"
  count=$((count + 1))
done <"$WANT"
sql+="SELECT changes(); COMMIT;"

names=$(ssh -o BatchMode=yes "$TARGET" "sqlite3 -readonly $DB 'select name from environments;'")
while IFS=$'\t' read -r name _; do
  printf '%s\n' "$names" | grep -qxF "$name" \
    || { echo "no Dockhand environment named '$name' (create it once in the UI)" >&2; exit 1; }
done <"$WANT"

printf '%s\n' "$sql" | ssh -o BatchMode=yes "$TARGET" "sqlite3 $DB" >/dev/null
ssh -o BatchMode=yes "$TARGET" "docker restart dockhand >/dev/null && sha256sum >$STAMP.tmp && cut -d' ' -f1 $STAMP.tmp >$STAMP && rm -f $STAMP.tmp" <"$WANT"
echo "Dockhand: $count environment(s) set, restarted"

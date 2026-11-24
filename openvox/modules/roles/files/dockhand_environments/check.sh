#!/usr/bin/env bash
# Exits 0 (no work needed) if Dockhand on nas was last set from exactly these
# environments and OIDC files (their sha256 stamp on nas matches) and the
# rows still have the wanted values (someone may have edited them in the UI).
set -euo pipefail
TARGET="nas-mgmt"
WANT=/var/lib/openvox-dockhand-environments/environments.tsv
OIDC=/var/lib/openvox-dockhand-environments/oidc.tsv
DB=/mnt/user/appdata/dockhand/db/dockhand.db
STAMP=/mnt/user/appdata/dockhand/.openvox-environments.sha256

want_sum=$(cat "$WANT" "$OIDC" | sha256sum | cut -d' ' -f1)
[ "$(ssh -o BatchMode=yes "$TARGET" "cat $STAMP 2>/dev/null" || true)" = "$want_sum" ] || exit 1
rows=$(ssh -o BatchMode=yes "$TARGET" "sqlite3 -readonly -separator '	' $DB 'select name, host, port, connection_type from environments;'")
while IFS=$'\t' read -r name host port _token; do
  printf '%s\n' "$rows" | grep -qxF "${name}	${host}	${port}	hawser-standard" || exit 1
done <"$WANT"
if IFS=$'\t' read -r issuer client redirect _secret <"$OIDC"; then
  row=$(ssh -o BatchMode=yes "$TARGET" "sqlite3 -readonly -separator '	' $DB \"select enabled, issuer_url, client_id, redirect_uri from oidc_config where name='Authelia';\"")
  [ "$row" = "1	${issuer}	${client}	${redirect}" ] || exit 1
fi

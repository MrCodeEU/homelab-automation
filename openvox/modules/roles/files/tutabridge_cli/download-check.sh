#!/usr/bin/env bash
# No longer pinned to a fixed release - the account got locked out for
# almost a week (2026-09-15 to 2026-09-20) because rc.9 was pinned past
# the point Tuta raised its minimum accepted client version and every
# release up to rc.11 failed login with 474 Invalid Software Version.
# Checks the installed binary against upstream's *latest* release
# instead, using the sha256 digest GitHub itself publishes for the
# asset (asset.digest) as the source of truth - not a value derived
# from the download itself, so this still catches a corrupted transfer
# or a CDN/MITM substitution, same guarantee the old pinned hash gave.
set -uo pipefail
DST=/opt/tutabridge/tutabridge-cli
DIGEST_FILE=/opt/tutabridge/.release-digest

LATEST=$(curl -sSL --max-time 10 https://api.github.com/repos/spartanz51/tutabridge/releases/latest \
  | jq -r '.assets[]? | select(.name=="tutabridge-linux-x86_64") | .digest' 2>/dev/null)

# GitHub API unreachable or gave nothing usable this run - don't force a
# redownload on a transient network blip, just keep what's installed and
# let the next run retry.
if [ -z "$LATEST" ] || [ "$LATEST" = "null" ]; then
  exit 0
fi

[ -f "$DST" ] && [ -f "$DIGEST_FILE" ] && [ "$(cat "$DIGEST_FILE")" = "$LATEST" ] \
  && [ "sha256:$(sha256sum "$DST" | awk '{print $1}')" = "$LATEST" ]

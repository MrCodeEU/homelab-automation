#!/usr/bin/env bash
# Companion to download-check.sh - see its header for why this tracks
# upstream's latest release instead of a fixed pin. Verifies against the
# sha256 digest GitHub publishes for the asset, fetched fresh from the
# API rather than trusted blind from the download.
set -euo pipefail
DST=/opt/tutabridge/tutabridge-cli
DIGEST_FILE=/opt/tutabridge/.release-digest
TAG_FILE=/opt/tutabridge/.release-tag

RELEASE=$(curl -sSL --fail --max-time 10 https://api.github.com/repos/spartanz51/tutabridge/releases/latest)
TAG=$(echo "$RELEASE" | jq -r '.tag_name')
URL=$(echo "$RELEASE" | jq -r '.assets[]? | select(.name=="tutabridge-linux-x86_64") | .browser_download_url')
EXPECTED=$(echo "$RELEASE" | jq -r '.assets[]? | select(.name=="tutabridge-linux-x86_64") | .digest')

if [ -z "$TAG" ] || [ "$TAG" = "null" ] || [ -z "$URL" ] || [ "$URL" = "null" ] \
   || [ -z "$EXPECTED" ] || [ "$EXPECTED" = "null" ]; then
  echo "ERROR: could not resolve latest tutabridge-cli release/asset from GitHub API" >&2
  exit 1
fi

TMP=$(mktemp)
curl -sSL --fail -o "$TMP" "$URL"
ACTUAL="sha256:$(sha256sum "$TMP" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "ERROR: checksum mismatch for $URL (expected $EXPECTED, got $ACTUAL)" >&2
  rm -f "$TMP"
  exit 1
fi

PREV_TAG=""
[ -f "$TAG_FILE" ] && PREV_TAG=$(cat "$TAG_FILE")

mv "$TMP" "$DST"
chmod 755 "$DST"
# mv preserves the source's SELinux context - $TMP is labeled tmp_t
# (from /tmp), which systemd refuses to exec (203/EXEC, Permission
# denied) once moved into /opt/tutabridge. This never showed up before
# because download-check.sh's old fixed-hash check always matched after
# the one-time 2026-08-13 bootstrap, so this exec never ran again until
# the switch to always-check-latest triggered a real redownload for the
# first time. restorecon relabels it back to the directory's default
# (usr_t), which is executable.
restorecon "$DST" 2>/dev/null || true
echo "$EXPECTED" > "$DIGEST_FILE"
echo "$TAG" > "$TAG_FILE"
echo "downloaded $DST ($TAG)"

if [ -n "$PREV_TAG" ] && [ "$PREV_TAG" != "$TAG" ]; then
  curl -s -X POST "https://ntfy.mljr.eu/docker-updates" \
    -H "Title: tutabridge-cli auto-updated" -H "Priority: default" -H "Tags: tutabridge,homelab" \
    -d "tutabridge-cli auto-updated ${PREV_TAG} -> ${TAG} on nuc" >/dev/null 2>&1 || true
fi

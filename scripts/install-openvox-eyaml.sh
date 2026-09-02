#!/usr/bin/env bash
# These paths are deliberately expanded and validated on the client before
# being embedded in the fixed remote command.
# shellcheck disable=SC2029
# Retired shared-key installer. Keeping a command that copies one private key
# to every agent would make a future recovery silently undo the host-scoped
# secret boundary. Use bootstrap-openvox-eyaml-host-key.sh instead.
set -euo pipefail

echo 'Refusing to distribute the retired shared eyaml private key.' >&2
echo 'Use: scripts/bootstrap-openvox-eyaml-host-key.sh <mljr|nuc|ugreen>' >&2
exit 2

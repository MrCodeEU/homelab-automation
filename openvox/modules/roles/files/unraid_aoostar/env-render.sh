#!/usr/bin/env bash
# Sourced by env-apply.sh and env-check.sh. Prints the canonical content of
# /mnt/user/appdata/aoostar/controller.env from the secrets passed in the
# environment by roles::unraid_aoostar_proxy (decrypted from eyaml on nuc).
# Values are single-quoted: the file is sourced by bash, and quotes keep them
# literal.
: "${AOOSTAR_UI_PASSWORD:?}" "${AOOSTAR_IMMICH_API_KEY:?}"
render_env() {
  cat <<EOF2
# Managed by OpenVox (roles::unraid_aoostar_proxy) - do not edit manually.
NAS_IP=192.168.50.80
PORT=5123
USERNAME=admin
PASSWORD='${AOOSTAR_UI_PASSWORD}'
IMMICH_URL=https://immich.mljr.eu
IMMICH_API_KEY='${AOOSTAR_IMMICH_API_KEY}'
IMMICH_PERSON_NAMES=''
EOF2
}

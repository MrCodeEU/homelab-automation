#!/usr/bin/env bash
# Installs the AOOSTAR display files on nas:
#   /mnt/user/appdata/aoostar/aoostar-ctl.sh, aoostar-controller.sh (array, persistent)
#   User Scripts "aoostar-display" (start) and "aoostar-display-stop" (stop)
# Nothing is started here: the start script runs at the next array start, or
# by hand with `/mnt/user/appdata/aoostar/aoostar-ctl.sh start`.
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="/mnt/user/appdata/aoostar"
US_DIR="/boot/config/plugins/user.scripts/scripts"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
SCP=(scp -q -o StrictHostKeyChecking=accept-new)

"${SSH[@]}" "$TARGET" "mkdir -p $APP_DIR $US_DIR/aoostar-display $US_DIR/aoostar-display-stop"
"${SCP[@]}" "$DIR/aoostar-ctl.sh" "$TARGET:$APP_DIR/aoostar-ctl.sh"
"${SCP[@]}" "$DIR/aoostar-controller.sh" "$TARGET:$APP_DIR/aoostar-controller.sh"
"${SCP[@]}" "$DIR/user-script-start.sh" "$TARGET:$US_DIR/aoostar-display/script"
"${SCP[@]}" "$DIR/user-script-stop.sh" "$TARGET:$US_DIR/aoostar-display-stop/script"
"${SSH[@]}" "$TARGET" "
  chmod 755 $APP_DIR/aoostar-ctl.sh $APP_DIR/aoostar-controller.sh
  chmod 755 $US_DIR/aoostar-display/script $US_DIR/aoostar-display-stop/script
  echo aoostar-display > $US_DIR/aoostar-display/name
  echo aoostar-display-stop > $US_DIR/aoostar-display-stop/name
  printf '%s\n' 'Managed by OpenVox (roles::unraid_aoostar_proxy). Starts the AOOSTAR display driver and its controller at array start.' > $US_DIR/aoostar-display/description
  printf '%s\n' 'Managed by OpenVox (roles::unraid_aoostar_proxy). Stops the AOOSTAR display driver when the array stops.' > $US_DIR/aoostar-display-stop/description
  chmod 644 $US_DIR/aoostar-display/name $US_DIR/aoostar-display-stop/name $US_DIR/aoostar-display/description $US_DIR/aoostar-display-stop/description
"
echo "aoostar display scripts installed"

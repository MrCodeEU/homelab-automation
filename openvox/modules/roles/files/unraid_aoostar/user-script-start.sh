#!/bin/bash
#arrayStarted=true
#name=aoostar-display
#description=Managed by OpenVox (roles::unraid_aoostar_proxy). Starts the AOOSTAR display driver and its controller at array start.
# Managed by OpenVox - do not edit manually. Logic lives in
# /mnt/user/appdata/aoostar/aoostar-ctl.sh (also managed).
exec /mnt/user/appdata/aoostar/aoostar-ctl.sh start

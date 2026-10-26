#!/bin/bash
#name=aoostar-display-stop
#description=Managed by OpenVox (roles::unraid_aoostar_proxy). Stops the AOOSTAR display driver when the array stops, so shutdown is not blocked by it.
# Managed by OpenVox - do not edit manually. Scheduled "At Stopping of Array".
exec /mnt/user/appdata/aoostar/aoostar-ctl.sh stop

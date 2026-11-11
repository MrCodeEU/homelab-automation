#!/bin/bash
# Exit 0 when sshd's config applies the Match block.
/usr/sbin/sshd -T -C user=spikefacts,host=localhost,addr=127.0.0.1 \
  | grep -qx 'forcecommand /usr/local/sbin/spike-facts'

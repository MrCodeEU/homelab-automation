#!/usr/bin/env bash
# refreshonly - only runs when the persistent-journal file/dir resources
# actually changed. Storage=persistent alone does not move an
# already-running volatile journal - journald keeps writing to /run until
# something flushes it, so the flush has to run every time this fires too.
set -euo pipefail
systemctl restart systemd-journald
journalctl --flush

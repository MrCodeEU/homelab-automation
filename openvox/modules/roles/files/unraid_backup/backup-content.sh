#!/bin/bash
# Unraid rclone backup
# Managed by OpenVox (roles::unraid_backup_proxy, proxy-exec from nuc) - do not edit manually
#
# Rides the rclone config that was already set up manually on this NAS
# (/root/.config/rclone/rclone.conf) - this script only owns the schedule and
# the path list.
#
# Summary block format matches ansible/roles/backup/templates/backup.sh.j2 so
# the health report's backup-log parser (homelab-facts.py.j2 collect_backup_log)
# works unmodified against either host's log.

set -uo pipefail

LOG_DIR="/mnt/user/appdata/homelab/backup/logs"
LOG_FILE="${LOG_DIR}/backup-$(date +%Y%m%d).log"
mkdir -p "$LOG_DIR"

UGREEN_CONFIG="/mnt/user/appdata/homelab/backup-remote/rclone-ugreen.conf"
UGREEN_AVAILABLE=0
# A present config file does not mean a writable target. When ugreen's btrfs
# failed on 2026-07-31 the SFTP login still succeeded, so this leg was still
# attempted and every single file failed with
#   Put mkParentDir failed: mkdir "/nas" failed: permission denied
# One run spent three hours writing a 66MB log of those, and - worse - the
# remaining paths never got their pCloud sync because they were queued behind
# it. Probe for writability, not for the config file.
if [ -f "$UGREEN_CONFIG" ] && rclone --config "$UGREEN_CONFIG" mkdir "ugreen:probe-$$" \
        --timeout 20s --contimeout 20s --retries 1 >/dev/null 2>&1; then
    rclone --config "$UGREEN_CONFIG" rmdir "ugreen:probe-$$" >/dev/null 2>&1
    UGREEN_AVAILABLE=1
fi
# No "data/" prefix: the sftp session already lands directly in the backup
# user's home, which IS the data directory (see roles/backup-remote-target).

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE"; }
log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1" | tee -a "$LOG_FILE"; }

# record_stats: logs one path's local size/file count as a BACKUP_STATS
# line, parsed by homelab-facts.py.epp's collect_backup_log() and shown on
# the backup dashboard. Queries the LOCAL source path (with the same
# --exclude filters as its sync), not the pCloud destination - rclone sync
# makes pCloud an exact mirror of it, so this is equivalent without the
# extra remote API call (see this script's own ugreen-probe comment above
# for why an extra unnecessary remote call here is worth avoiding).
record_stats() {
    local name="$1" path="$2"
    shift 2
    local stats_json b c
    stats_json=$(rclone size --json "$path" "$@" 2>/dev/null) || stats_json='{}'
    b=$(printf '%s' "$stats_json" | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p')
    c=$(printf '%s' "$stats_json" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')
    log "BACKUP_STATS: ${name} bytes=${b:-0} files=${c:-0}"
}

send_notification() {
    curl -s -X POST "https://ntfy.mljr.eu/backup" \
        -H "Title: NAS Backup" -H "Priority: ${2:-default}" -H "Tags: backup,homelab,nas" \
        -d "$1" >/dev/null 2>&1 || log_warn "Failed to send notification"
}

total_count=0
declare -a failed_paths=()
BACKUP_DATE="$(date +%Y%m%d)"

total_count=$((total_count + 1))
log "Backing up /mnt/user/Fotos/Fotos -> pcloud:Fotos (pCloud)"
if rclone sync "/mnt/user/Fotos/Fotos" "pcloud:Fotos" \
    --backup-dir "pcloud:.deleted/fotos/${BACKUP_DATE}" \
    --exclude "**/.stfolder/**" \
    --transfers 4 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
    log "SUCCESS: /mnt/user/Fotos/Fotos backed up to pCloud"
    record_stats "fotos" "/mnt/user/Fotos/Fotos" --exclude "**/.stfolder/**"
else
    log_error "Failed to sync /mnt/user/Fotos/Fotos to pCloud"
    failed_paths+=("pcloud:Fotos")
fi
if [ "$UGREEN_AVAILABLE" = "1" ]; then
    log "Backing up /mnt/user/Fotos/Fotos -> ugreen:nas/fotos"
    if rclone --config "$UGREEN_CONFIG" sync "/mnt/user/Fotos/Fotos" "ugreen:nas/fotos" \
        --backup-dir "ugreen:nas/.deleted/fotos/${BACKUP_DATE}" \
        --exclude "**/.stfolder/**" \
        --transfers 2 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
        log "SUCCESS: /mnt/user/Fotos/Fotos backed up to ugreen"
    else
        log_warn "Failed to sync /mnt/user/Fotos/Fotos to ugreen (on-prem copy only, pCloud leg above is authoritative)"
    fi
fi
log "Backing up /mnt/user/Fotos/Fotos -> wd-cloud:Fotos"
wd_cloud_attempt=0
wd_cloud_success=0
while [ "$wd_cloud_attempt" -lt 2 ]; do
    wd_cloud_attempt=$((wd_cloud_attempt + 1))
    if rclone sync "/mnt/user/Fotos/Fotos" "wd-cloud:Fotos" \
        --backup-dir "wd-cloud:backup/.deleted/fotos/${BACKUP_DATE}" \
        --exclude "**/.stfolder/**" \
        --transfers 2 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
        wd_cloud_success=1
        break
    fi
    [ "$wd_cloud_attempt" -lt 2 ] && sleep 15
done
if [ "$wd_cloud_success" -eq 1 ]; then
    log "SUCCESS: /mnt/user/Fotos/Fotos backed up to wd-cloud"
else
    log_warn "Failed to sync /mnt/user/Fotos/Fotos to wd-cloud after 2 attempts (push-only copy, not fatal)"
    failed_paths+=("fotos (wd-cloud)")
fi

total_count=$((total_count + 1))
log "Backing up /mnt/user/Fotos/Videos -> pcloud:Fotos-Videos (pCloud)"
if rclone sync "/mnt/user/Fotos/Videos" "pcloud:Fotos-Videos" \
    --backup-dir "pcloud:.deleted/fotos-videos/${BACKUP_DATE}" \
    --exclude "**/.stfolder/**" \
    --transfers 4 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
    log "SUCCESS: /mnt/user/Fotos/Videos backed up to pCloud"
    record_stats "fotos-videos" "/mnt/user/Fotos/Videos" --exclude "**/.stfolder/**"
else
    log_error "Failed to sync /mnt/user/Fotos/Videos to pCloud"
    failed_paths+=("pcloud:Fotos-Videos")
fi
if [ "$UGREEN_AVAILABLE" = "1" ]; then
    log "Backing up /mnt/user/Fotos/Videos -> ugreen:nas/fotos-videos"
    if rclone --config "$UGREEN_CONFIG" sync "/mnt/user/Fotos/Videos" "ugreen:nas/fotos-videos" \
        --backup-dir "ugreen:nas/.deleted/fotos-videos/${BACKUP_DATE}" \
        --exclude "**/.stfolder/**" \
        --transfers 2 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
        log "SUCCESS: /mnt/user/Fotos/Videos backed up to ugreen"
    else
        log_warn "Failed to sync /mnt/user/Fotos/Videos to ugreen (on-prem copy only, pCloud leg above is authoritative)"
    fi
fi
log "Backing up /mnt/user/Fotos/Videos -> wd-cloud:Videos"
wd_cloud_attempt=0
wd_cloud_success=0
while [ "$wd_cloud_attempt" -lt 2 ]; do
    wd_cloud_attempt=$((wd_cloud_attempt + 1))
    if rclone sync "/mnt/user/Fotos/Videos" "wd-cloud:Videos" \
        --backup-dir "wd-cloud:backup/.deleted/fotos-videos/${BACKUP_DATE}" \
        --exclude "**/.stfolder/**" \
        --transfers 2 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
        wd_cloud_success=1
        break
    fi
    [ "$wd_cloud_attempt" -lt 2 ] && sleep 15
done
if [ "$wd_cloud_success" -eq 1 ]; then
    log "SUCCESS: /mnt/user/Fotos/Videos backed up to wd-cloud"
else
    log_warn "Failed to sync /mnt/user/Fotos/Videos to wd-cloud after 2 attempts (push-only copy, not fatal)"
    failed_paths+=("fotos-videos (wd-cloud)")
fi

total_count=$((total_count + 1))
log "Backing up /mnt/user/Fotos/Wichtiges Scans Adressen -> pcloud:Fotos-Wichtiges-Scans-Adressen (pCloud)"
if rclone sync "/mnt/user/Fotos/Wichtiges Scans Adressen" "pcloud:Fotos-Wichtiges-Scans-Adressen" \
    --backup-dir "pcloud:.deleted/fotos-wichtiges-scans-adressen/${BACKUP_DATE}" \
    --exclude "**/.stfolder/**" \
    --transfers 4 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
    log "SUCCESS: /mnt/user/Fotos/Wichtiges Scans Adressen backed up to pCloud"
    record_stats "fotos-wichtiges-scans-adressen" "/mnt/user/Fotos/Wichtiges Scans Adressen" --exclude "**/.stfolder/**"
else
    log_error "Failed to sync /mnt/user/Fotos/Wichtiges Scans Adressen to pCloud"
    failed_paths+=("pcloud:Fotos-Wichtiges-Scans-Adressen")
fi
if [ "$UGREEN_AVAILABLE" = "1" ]; then
    log "Backing up /mnt/user/Fotos/Wichtiges Scans Adressen -> ugreen:nas/fotos-wichtiges-scans-adressen"
    if rclone --config "$UGREEN_CONFIG" sync "/mnt/user/Fotos/Wichtiges Scans Adressen" "ugreen:nas/fotos-wichtiges-scans-adressen" \
        --backup-dir "ugreen:nas/.deleted/fotos-wichtiges-scans-adressen/${BACKUP_DATE}" \
        --exclude "**/.stfolder/**" \
        --transfers 2 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
        log "SUCCESS: /mnt/user/Fotos/Wichtiges Scans Adressen backed up to ugreen"
    else
        log_warn "Failed to sync /mnt/user/Fotos/Wichtiges Scans Adressen to ugreen (on-prem copy only, pCloud leg above is authoritative)"
    fi
fi

total_count=$((total_count + 1))
log "Backing up /mnt/user/Fotos/Musik -> pcloud:Musik (pCloud)"
if rclone sync "/mnt/user/Fotos/Musik" "pcloud:Musik" \
    --backup-dir "pcloud:.deleted/musik/${BACKUP_DATE}" \
    --exclude "**/.stfolder/**" \
    --transfers 4 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
    log "SUCCESS: /mnt/user/Fotos/Musik backed up to pCloud"
    record_stats "musik" "/mnt/user/Fotos/Musik" --exclude "**/.stfolder/**"
else
    log_error "Failed to sync /mnt/user/Fotos/Musik to pCloud"
    failed_paths+=("pcloud:Musik")
fi
if [ "$UGREEN_AVAILABLE" = "1" ]; then
    log "Backing up /mnt/user/Fotos/Musik -> ugreen:nas/musik"
    if rclone --config "$UGREEN_CONFIG" sync "/mnt/user/Fotos/Musik" "ugreen:nas/musik" \
        --backup-dir "ugreen:nas/.deleted/musik/${BACKUP_DATE}" \
        --exclude "**/.stfolder/**" \
        --transfers 2 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
        log "SUCCESS: /mnt/user/Fotos/Musik backed up to ugreen"
    else
        log_warn "Failed to sync /mnt/user/Fotos/Musik to ugreen (on-prem copy only, pCloud leg above is authoritative)"
    fi
fi
log "Backing up /mnt/user/Fotos/Musik -> wd-cloud:Musik"
wd_cloud_attempt=0
wd_cloud_success=0
while [ "$wd_cloud_attempt" -lt 2 ]; do
    wd_cloud_attempt=$((wd_cloud_attempt + 1))
    if rclone sync "/mnt/user/Fotos/Musik" "wd-cloud:Musik" \
        --backup-dir "wd-cloud:backup/.deleted/musik/${BACKUP_DATE}" \
        --exclude "**/.stfolder/**" \
        --transfers 2 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
        wd_cloud_success=1
        break
    fi
    [ "$wd_cloud_attempt" -lt 2 ] && sleep 15
done
if [ "$wd_cloud_success" -eq 1 ]; then
    log "SUCCESS: /mnt/user/Fotos/Musik backed up to wd-cloud"
else
    log_warn "Failed to sync /mnt/user/Fotos/Musik to wd-cloud after 2 attempts (push-only copy, not fatal)"
    failed_paths+=("musik (wd-cloud)")
fi

total_count=$((total_count + 1))
log "Backing up /mnt/user/Fotos/SB -> pcloud:Fotos-SB (pCloud)"
if rclone sync "/mnt/user/Fotos/SB" "pcloud:Fotos-SB" \
    --backup-dir "pcloud:.deleted/fotos-sb/${BACKUP_DATE}" \
    --exclude "**/.stfolder/**" \
    --transfers 4 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
    log "SUCCESS: /mnt/user/Fotos/SB backed up to pCloud"
    record_stats "fotos-sb" "/mnt/user/Fotos/SB" --exclude "**/.stfolder/**"
else
    log_error "Failed to sync /mnt/user/Fotos/SB to pCloud"
    failed_paths+=("pcloud:Fotos-SB")
fi
if [ "$UGREEN_AVAILABLE" = "1" ]; then
    log "Backing up /mnt/user/Fotos/SB -> ugreen:nas/fotos-sb"
    if rclone --config "$UGREEN_CONFIG" sync "/mnt/user/Fotos/SB" "ugreen:nas/fotos-sb" \
        --backup-dir "ugreen:nas/.deleted/fotos-sb/${BACKUP_DATE}" \
        --exclude "**/.stfolder/**" \
        --transfers 2 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
        log "SUCCESS: /mnt/user/Fotos/SB backed up to ugreen"
    else
        log_warn "Failed to sync /mnt/user/Fotos/SB to ugreen (on-prem copy only, pCloud leg above is authoritative)"
    fi
fi

total_count=$((total_count + 1))
log "Backing up /mnt/user/borgbackup/borg -> pcloud:Nextcloud-Borg (pCloud)"
if rclone sync "/mnt/user/borgbackup/borg" "pcloud:Nextcloud-Borg" \
    --backup-dir "pcloud:.deleted/nextcloud-borg/${BACKUP_DATE}" \
    --exclude "**/.stfolder/**" \
    --transfers 4 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
    log "SUCCESS: /mnt/user/borgbackup/borg backed up to pCloud"
    record_stats "nextcloud-borg" "/mnt/user/borgbackup/borg" --exclude "**/.stfolder/**"
else
    log_error "Failed to sync /mnt/user/borgbackup/borg to pCloud"
    failed_paths+=("pcloud:Nextcloud-Borg")
fi
if [ "$UGREEN_AVAILABLE" = "1" ]; then
    log "Backing up /mnt/user/borgbackup/borg -> ugreen:nas/nextcloud-borg"
    if rclone --config "$UGREEN_CONFIG" sync "/mnt/user/borgbackup/borg" "ugreen:nas/nextcloud-borg" \
        --backup-dir "ugreen:nas/.deleted/nextcloud-borg/${BACKUP_DATE}" \
        --exclude "**/.stfolder/**" \
        --transfers 2 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
        log "SUCCESS: /mnt/user/borgbackup/borg backed up to ugreen"
    else
        log_warn "Failed to sync /mnt/user/borgbackup/borg to ugreen (on-prem copy only, pCloud leg above is authoritative)"
    fi
fi

total_count=$((total_count + 1))
log "Backing up /boot -> pcloud:unraid-flash (pCloud)"
if rclone sync "/boot" "pcloud:unraid-flash" \
    --backup-dir "pcloud:.deleted/unraid-flash/${BACKUP_DATE}" \
    --exclude "**/.stfolder/**" \
    --transfers 4 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
    log "SUCCESS: /boot backed up to pCloud"
    record_stats "unraid-flash" "/boot" --exclude "**/.stfolder/**"
else
    log_error "Failed to sync /boot to pCloud"
    failed_paths+=("pcloud:unraid-flash")
fi
if [ "$UGREEN_AVAILABLE" = "1" ]; then
    log "Backing up /boot -> ugreen:nas/unraid-flash"
    if rclone --config "$UGREEN_CONFIG" sync "/boot" "ugreen:nas/unraid-flash" \
        --backup-dir "ugreen:nas/.deleted/unraid-flash/${BACKUP_DATE}" \
        --exclude "**/.stfolder/**" \
        --transfers 2 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
        log "SUCCESS: /boot backed up to ugreen"
    else
        log_warn "Failed to sync /boot to ugreen (on-prem copy only, pCloud leg above is authoritative)"
    fi
fi

total_count=$((total_count + 1))
log "Backing up /mnt/user/backup/appdata -> pcloud:unraid-appdata-backup (pCloud)"
if rclone sync "/mnt/user/backup/appdata" "pcloud:unraid-appdata-backup" \
    --backup-dir "pcloud:.deleted/appdata-backup/${BACKUP_DATE}" \
    --exclude "**/.stfolder/**" \
    --transfers 4 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
    log "SUCCESS: /mnt/user/backup/appdata backed up to pCloud"
    record_stats "appdata-backup" "/mnt/user/backup/appdata" --exclude "**/.stfolder/**"
else
    log_error "Failed to sync /mnt/user/backup/appdata to pCloud"
    failed_paths+=("pcloud:unraid-appdata-backup")
fi
if [ "$UGREEN_AVAILABLE" = "1" ]; then
    log "Backing up /mnt/user/backup/appdata -> ugreen:nas/appdata-backup"
    if rclone --config "$UGREEN_CONFIG" sync "/mnt/user/backup/appdata" "ugreen:nas/appdata-backup" \
        --backup-dir "ugreen:nas/.deleted/appdata-backup/${BACKUP_DATE}" \
        --exclude "**/.stfolder/**" \
        --transfers 2 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
        log "SUCCESS: /mnt/user/backup/appdata backed up to ugreen"
    else
        log_warn "Failed to sync /mnt/user/backup/appdata to ugreen (on-prem copy only, pCloud leg above is authoritative)"
    fi
fi

total_count=$((total_count + 1))
log "Backing up /mnt/user/backup/origami -> pcloud:origami (pCloud)"
if rclone sync "/mnt/user/backup/origami" "pcloud:origami" \
    --backup-dir "pcloud:.deleted/origami/${BACKUP_DATE}" \
    --exclude "**/.stfolder/**" \
    --transfers 4 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
    log "SUCCESS: /mnt/user/backup/origami backed up to pCloud"
    record_stats "origami" "/mnt/user/backup/origami" --exclude "**/.stfolder/**"
else
    log_error "Failed to sync /mnt/user/backup/origami to pCloud"
    failed_paths+=("pcloud:origami")
fi
if [ "$UGREEN_AVAILABLE" = "1" ]; then
    log "Backing up /mnt/user/backup/origami -> ugreen:nas/origami"
    if rclone --config "$UGREEN_CONFIG" sync "/mnt/user/backup/origami" "ugreen:nas/origami" \
        --backup-dir "ugreen:nas/.deleted/origami/${BACKUP_DATE}" \
        --exclude "**/.stfolder/**" \
        --transfers 2 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
        log "SUCCESS: /mnt/user/backup/origami backed up to ugreen"
    else
        log_warn "Failed to sync /mnt/user/backup/origami to ugreen (on-prem copy only, pCloud leg above is authoritative)"
    fi
fi

total_count=$((total_count + 1))
log "Backing up /mnt/user/Sync -> pcloud:Sync (pCloud)"
if rclone sync "/mnt/user/Sync" "pcloud:Sync" \
    --backup-dir "pcloud:.deleted/sync/${BACKUP_DATE}" \
    --exclude "**/.stfolder/**" \
    --exclude "**/node_modules/**" \
    --exclude "**/target/**" \
    --exclude "**/.embuild/**" \
    --exclude "**/.venv/**" \
    --exclude "**/venv/**" \
    --exclude "**/__pycache__/**" \
    --exclude "**/.next/**" \
    --exclude "**/.svelte-kit/**" \
    --exclude "**/dist/**" \
    --exclude "**/build/**" \
    --exclude "**/.cache/**" \
    --exclude "**/tmp/**" \
    --exclude "**/vendor/**" \
    --exclude "**/.pio/**" \
    --exclude "**/.dart_tool/**" \
    --exclude "**/.gradle/**" \
    --exclude "**/obj/**" \
    --exclude "**/.stversions/**" \
    --exclude "**/.git_broken_*/**" \
    --exclude "**/lib/python*/site-packages/**" \
    --exclude "**/goDrive/var/perf-data/**" \
    --exclude "**/goDrive/var/perf-appdata/**" \
    --exclude "**/goDrive/var/appdata/previews/thumbs/**" \
    --exclude "**/bin/**" \
    --exclude "**/Library/**" \
    --exclude "**/BA_Speaker_Diarization/data_vox/**" \
    --transfers 4 --checkers 8 --log-file="$LOG_FILE" --log-level INFO; then
    log "SUCCESS: /mnt/user/Sync backed up to pCloud"
    record_stats "sync" "/mnt/user/Sync" \
        --exclude "**/.stfolder/**" \
        --exclude "**/node_modules/**" \
        --exclude "**/target/**" \
        --exclude "**/.embuild/**" \
        --exclude "**/.venv/**" \
        --exclude "**/venv/**" \
        --exclude "**/__pycache__/**" \
        --exclude "**/.next/**" \
        --exclude "**/.svelte-kit/**" \
        --exclude "**/dist/**" \
        --exclude "**/build/**" \
        --exclude "**/.cache/**" \
        --exclude "**/tmp/**" \
        --exclude "**/vendor/**" \
        --exclude "**/.pio/**" \
        --exclude "**/.dart_tool/**" \
        --exclude "**/.gradle/**" \
        --exclude "**/obj/**" \
        --exclude "**/.stversions/**" \
        --exclude "**/.git_broken_*/**" \
        --exclude "**/lib/python*/site-packages/**" \
        --exclude "**/goDrive/var/perf-data/**" \
        --exclude "**/goDrive/var/perf-appdata/**" \
        --exclude "**/goDrive/var/appdata/previews/thumbs/**" \
        --exclude "**/bin/**" \
        --exclude "**/Library/**" \
        --exclude "**/BA_Speaker_Diarization/data_vox/**"
else
    log_error "Failed to sync /mnt/user/Sync to pCloud"
    failed_paths+=("pcloud:Sync")
fi

# Prune .deleted/ point-in-time folders older than the retention window -
# --backup-dir keeps every changed/deleted file forever otherwise.
log "Pruning .deleted/ folders older than 30 days"
rclone delete --min-age 30d "pcloud:.deleted/fotos" >/dev/null 2>&1 || true
[ "$UGREEN_AVAILABLE" = "1" ] && rclone --config "$UGREEN_CONFIG" delete --min-age 30d "ugreen:nas/.deleted/fotos" >/dev/null 2>&1 || true
rclone delete --min-age 30d "wd-cloud:backup/.deleted/fotos" >/dev/null 2>&1 || true
rclone delete --min-age 30d "pcloud:.deleted/fotos-videos" >/dev/null 2>&1 || true
[ "$UGREEN_AVAILABLE" = "1" ] && rclone --config "$UGREEN_CONFIG" delete --min-age 30d "ugreen:nas/.deleted/fotos-videos" >/dev/null 2>&1 || true
rclone delete --min-age 30d "wd-cloud:backup/.deleted/fotos-videos" >/dev/null 2>&1 || true
rclone delete --min-age 30d "pcloud:.deleted/fotos-wichtiges-scans-adressen" >/dev/null 2>&1 || true
[ "$UGREEN_AVAILABLE" = "1" ] && rclone --config "$UGREEN_CONFIG" delete --min-age 30d "ugreen:nas/.deleted/fotos-wichtiges-scans-adressen" >/dev/null 2>&1 || true
rclone delete --min-age 30d "pcloud:.deleted/musik" >/dev/null 2>&1 || true
[ "$UGREEN_AVAILABLE" = "1" ] && rclone --config "$UGREEN_CONFIG" delete --min-age 30d "ugreen:nas/.deleted/musik" >/dev/null 2>&1 || true
rclone delete --min-age 30d "wd-cloud:backup/.deleted/musik" >/dev/null 2>&1 || true
rclone delete --min-age 30d "pcloud:.deleted/fotos-sb" >/dev/null 2>&1 || true
[ "$UGREEN_AVAILABLE" = "1" ] && rclone --config "$UGREEN_CONFIG" delete --min-age 30d "ugreen:nas/.deleted/fotos-sb" >/dev/null 2>&1 || true
rclone delete --min-age 30d "pcloud:.deleted/nextcloud-borg" >/dev/null 2>&1 || true
[ "$UGREEN_AVAILABLE" = "1" ] && rclone --config "$UGREEN_CONFIG" delete --min-age 30d "ugreen:nas/.deleted/nextcloud-borg" >/dev/null 2>&1 || true
rclone delete --min-age 30d "pcloud:.deleted/unraid-flash" >/dev/null 2>&1 || true
[ "$UGREEN_AVAILABLE" = "1" ] && rclone --config "$UGREEN_CONFIG" delete --min-age 30d "ugreen:nas/.deleted/unraid-flash" >/dev/null 2>&1 || true
rclone delete --min-age 30d "pcloud:.deleted/appdata-backup" >/dev/null 2>&1 || true
[ "$UGREEN_AVAILABLE" = "1" ] && rclone --config "$UGREEN_CONFIG" delete --min-age 30d "ugreen:nas/.deleted/appdata-backup" >/dev/null 2>&1 || true
rclone delete --min-age 30d "pcloud:.deleted/origami" >/dev/null 2>&1 || true
[ "$UGREEN_AVAILABLE" = "1" ] && rclone --config "$UGREEN_CONFIG" delete --min-age 30d "ugreen:nas/.deleted/origami" >/dev/null 2>&1 || true
rclone delete --min-age 30d "pcloud:.deleted/sync" >/dev/null 2>&1 || true

log "=========================================="
log "Backup Summary"
log "=========================================="
log "Total services: $total_count"
log "Successful: $((total_count - ${#failed_paths[@]}))"
log "Critical failures: 0"
log "Non-critical failures: ${#failed_paths[@]}"

if [ ${#failed_paths[@]} -gt 0 ]; then
    log_warn "Non-critical backup failures: ${failed_paths[*]}"
    send_notification "⚠️ NAS backup failures: ${failed_paths[*]}" "default"
else
    log "SUCCESS: All backups completed successfully!"
    send_notification "✅ NAS backups completed successfully ($total_count/$total_count)"
fi

# 30-day retention, matching the rocky backup role's default.
find "$LOG_DIR" -name "backup-*.log" -mtime +30 -delete 2>/dev/null || true

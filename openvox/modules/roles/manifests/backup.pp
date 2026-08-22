# Host-local backup role - rclone to pCloud (primary) plus best-effort
# on-prem (ugreen) and semi-offsite push-only (WD MyCloud) legs. Logic-
# ported from ansible/roles/backup; no already-applied spot reference
# exists for this role (spot only ported backup-remote-key and
# backup-dashboard, not the host-local backup role itself), so this was
# derived directly from the Ansible role per the user's standing
# instruction to treat ansible/ as the source of truth.
#
# Scope decisions vs. the Ansible role (both deliberate, both discussed
# with the user as part of this port):
#   - ntfy push notifications are not ported: secrets.ntfy is not
#     currently defined in the vault either, so Ansible's own
#     send_notification() already falls back to log-only on every real
#     host today. Wiring a second notification channel with zero live
#     config to validate against isn't worth the added surface; the
#     log-only path here matches current production behavior exactly.
#   - The Docker-volume auto-detect task (`detected_volumes`) is dropped:
#     in the Ansible role it only ever feeds one cosmetic debug line, it
#     never drives which volumes actually get backed up (that's always
#     backup_host_service_configs), so it has no behavioral effect to
#     preserve.
#   - "auto-restore on fresh install" is not ported: both hosts this role
#     targets (mljr, nuc) are long-running and already carry
#     .homelab-initialized, so that branch is dead code on every real
#     target today and isn't safely testable without staging an actual
#     fresh host. restore.sh itself is still fully deployed and callable
#     by hand for disaster recovery - see the DR runbook - only the
#     automatic trigger-on-first-boot path is out of scope here.
#   - The backup-to-ugreen SSH keypair (ansible/roles/backup-remote-key)
#     is not re-generated here - it already exists on disk on every real
#     target (Ansible deployed it there already, `regenerate: never`) and
#     this role only ever reads it. Same reasoning as
#     roles::unraid_backup_proxy's identical note.
#
# $services selects the subset of $backup_service_configs this host
# backs up (mirrors Ansible's per-host filter over the `services` list -
# see site.pp for each host's actual set).
class roles::backup (
  Array[String] $services       = [],
  String        $local_path     = '/opt/backups',
  String        $base_path      = '/opt',
  String        $rclone_config_path = '/root/.config/rclone',
  String        $remote_name    = 'pcloud',
  # Role default in ansible/roles/backup is "homelab-backup/{{ inventory_hostname }}"
  # (per-host); real production overrides this globally in
  # ansible/inventory/group_vars/all/all.yml to one shared flat path
  # across every host - matching that live value here, not the dormant
  # role default, per the same "match reality, not the stale role
  # default" precedent as roles::mailcow's http_port.
  String        $remote_path    = 'homelab-backups',
  String        $backup_schedule = '*-*-* 03:00:00',
  Integer       $retention_days = 30,
  String        $item_timeout   = '40m',
  Integer       $transfers      = 8,
  Integer       $checkers       = 16,
  String        $bwlimit        = '',
  String        $cpu_quota      = '',
  # This is only ever used for the UGREEN_REMOTE path segment (the
  # directory backup-remote-target already authorized on ugreen for this
  # host - see ansible/roles/backup-remote-key). It must match Ansible's
  # inventory_hostname exactly ('mljr', 'nuc'), NOT the box's real OS
  # hostname: mljr's actual $facts['networking']['hostname'] is its VPS
  # provider's default ('vmi2945702'), which would silently start writing
  # the on-prem leg to a brand new, never-authorized ugreen directory
  # instead of the one Ansible has used all along. Caught by diffing this
  # role's noop-rendered backup.sh against the real deployed one before
  # ever applying for real - see the migration memory for the full story.
  String        $hostname       = $facts['networking']['hostname'],
) {

  $pcloud_token      = Sensitive(lookup('vault_pcloud_token', { 'default_value' => '' }))
  $wd_cloud_user     = Sensitive(lookup('vault_wd_cloud_user', { 'default_value' => 'admin' }))
  $wd_cloud_password = Sensitive(lookup('vault_wd_cloud_password', { 'default_value' => '' }))

  # ==========================================================================
  # Per-service backup definitions - mirrors ansible/roles/backup's
  # backup_service_configs default exactly (defaults/main.yml). Hook
  # scripts use unquoted heredocs (@(TAG), no quotes around the tag) so
  # their bash $VAR / ${VAR} reads pass through completely literally -
  # see the authelia role's commit history for why that distinction
  # matters (a quoted tag is interpolating and silently eats bare $2-style
  # tokens).
  # ==========================================================================
  $mailcow_pre_hook = @(MAILCOW_PRE)
    cd /opt/mailcow-dockerized && \
    set -a && . ./mailcow.conf && set +a && \
    mkdir -p /opt/backups/mailcow-dumps && \
    docker compose exec -T mysql-mailcow mysqldump -u"$DBUSER" -p"$DBPASS" "$DBNAME" > /opt/backups/mailcow-dumps/mailcow.sql
    | MAILCOW_PRE

  $forgejo_pre_hook = @(FORGEJO_PRE)
    mkdir -p /opt/backups/forgejo-dumps && \
    docker exec forgejo-db sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' \
      > /opt/backups/forgejo-dumps/forgejo.sql
    | FORGEJO_PRE

  $forgejo_restore_hook = @(FORGEJO_RESTORE)
    for i in $(seq 1 30); do
      docker exec forgejo-db pg_isready > /dev/null 2>&1 && break
      sleep 2
    done
    docker exec -i forgejo-db sh -c 'psql -U "$POSTGRES_USER" "$POSTGRES_DB"' \
      < /opt/backups/forgejo-dumps/forgejo.sql
    | FORGEJO_RESTORE

  $mailarchiver_pre_hook = @(MAILARCHIVER_PRE)
    mkdir -p /opt/backups/mail-archiver-dumps && \
    docker exec mail-archiver-db sh -c 'pg_dump -U mailuser MailArchiver' \
      > /opt/backups/mail-archiver-dumps/mail-archiver.sql
    | MAILARCHIVER_PRE

  $mailarchiver_restore_hook = @(MAILARCHIVER_RESTORE)
    for i in $(seq 1 30); do
      docker exec mail-archiver-db pg_isready > /dev/null 2>&1 && break
      sleep 2
    done
    docker exec -i mail-archiver-db psql -U mailuser MailArchiver \
      < /opt/backups/mail-archiver-dumps/mail-archiver.sql
    | MAILARCHIVER_RESTORE

  $umami_pre_hook = @(UMAMI_PRE)
    mkdir -p /opt/backups/umami-dumps && \
    docker exec umami-db sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' \
      > /opt/backups/umami-dumps/umami.sql
    | UMAMI_PRE

  $umami_restore_hook = @(UMAMI_RESTORE)
    for i in $(seq 1 30); do
      docker exec umami-db pg_isready > /dev/null 2>&1 && break
      sleep 2
    done
    docker exec -i umami-db sh -c 'psql -U "$POSTGRES_USER" "$POSTGRES_DB"' \
      < /opt/backups/umami-dumps/umami.sql
    | UMAMI_RESTORE

  $nocturne_pre_hook = @(NOCTURNE_PRE)
    mkdir -p /opt/backups/nocturne-dumps && \
    docker exec nocturne-postgres sh -c \
      'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' \
      > /opt/backups/nocturne-dumps/nocturne.sql
    | NOCTURNE_PRE

  $nocturne_restore_hook = @(NOCTURNE_RESTORE)
    for i in $(seq 1 30); do
      docker exec nocturne-postgres pg_isready > /dev/null 2>&1 && break
      sleep 2
    done
    docker exec -i nocturne-postgres sh -c \
      'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" "$POSTGRES_DB"' \
      < /opt/backups/nocturne-dumps/nocturne.sql
    | NOCTURNE_RESTORE

  $backup_service_configs = {
    'authelia' => {
      'paths'    => ['/opt/authelia'],
      'volumes'  => ['authelia_redis_data'],
      'critical' => true,
    },
    'mailcow' => {
      'volumes'  => ['mailcowdockerized_vmail-vol-1', 'mailcowdockerized_mysql-vol-1'],
      'pre_hook' => $mailcow_pre_hook,
      'post_hook' => 'rm -rf /opt/backups/mailcow-dumps',
      'paths'    => ['/opt/backups/mailcow-dumps', '/opt/mailcow-dockerized/data'],
      'critical' => true,
    },
    'kuma' => {
      'volumes'  => ['kuma_uptime-kuma-data'],
      'critical' => false,
    },
    'ntfy' => {
      'volumes'  => ['ntfy_ntfy-data', 'ntfy_ntfy-cache'],
      'critical' => false,
    },
    'forgejo' => {
      'volumes'           => ['forgejo-data', 'forgejo-db-data'],
      'pre_hook'          => $forgejo_pre_hook,
      'paths'             => ['/opt/backups/forgejo-dumps'],
      'post_hook'         => 'rm -rf /opt/backups/forgejo-dumps',
      'restore_post_hook' => $forgejo_restore_hook,
      'critical'          => true,
    },
    'mail-archiver' => {
      'volumes'           => ['mail-archiver_mail-archiver-dp-keys'],
      'pre_hook'          => $mailarchiver_pre_hook,
      'paths'             => ['/opt/backups/mail-archiver-dumps'],
      'post_hook'         => 'rm -rf /opt/backups/mail-archiver-dumps',
      'restore_post_hook' => $mailarchiver_restore_hook,
      'critical'          => true,
    },
    'umami' => {
      'volumes'           => ['umami_umami-db-data'],
      'pre_hook'          => $umami_pre_hook,
      'paths'             => ['/opt/backups/umami-dumps'],
      'post_hook'         => 'rm -rf /opt/backups/umami-dumps',
      'restore_post_hook' => $umami_restore_hook,
      'critical'          => false,
    },
    'grafana' => {
      'volumes'  => ['grafana-data', 'victoriametrics-data', 'loki-data'],
      'critical' => false,
    },
    'nocturne' => {
      'volumes'           => ['nocturne_nocturne-postgres-data'],
      'pre_hook'          => $nocturne_pre_hook,
      'paths'             => ['/opt/backups/nocturne-dumps'],
      'post_hook'         => 'rm -rf /opt/backups/nocturne-dumps',
      'restore_post_hook' => $nocturne_restore_hook,
      'critical'          => false,
    },
    'newsletter' => {
      'volumes'  => ['newsletter_newsletter-data'],
      'critical' => true,
    },
    'goaccess' => {
      'volumes'  => ['goaccess_goaccess-data', 'goaccess_goaccess-report'],
      'critical' => false,
    },
    'crowdsec' => {
      'volumes'  => ['crowdsec-config', 'crowdsec-data', 'crowdsec-web-ui-data'],
      'critical' => false,
    },
  }

  $host_configs = $backup_service_configs.filter |$k, $v| { $k in $services }

  # ==========================================================================
  # backup.sh - assembled from single-quoted / unquoted-heredoc literal
  # bash fragments joined with Puppet's `.join('')` (Puppet's `+` operator
  # is arithmetic-only, not string concatenation - confirmed the hard way
  # against a live host), never by interpolating raw bash $VAR text inside
  # a double-quoted Puppet string. That interpolation-avoidance half of
  # the rule is the same one the mailcow role's cert-sync/update scripts
  # follow, applied here to a script whose body is generated per-host
  # rather than static.
  # ==========================================================================
  $bwlimit_line = $bwlimit ? {
    ''      => 'PCLOUD_BWLIMIT_ARGS=()',
    default => ['PCLOUD_BWLIMIT_ARGS=(--bwlimit "', $bwlimit, '")'].join(''),
  }

  $backup_config_block = [
    'REMOTE="', $remote_name, ':', $remote_path, '"', "\n",
    'LOCAL_PATH="', $local_path, '"', "\n",
    'UGREEN_KEY="/opt/backup-remote/ssh/id_ed25519"', "\n",
    'UGREEN_REMOTE="ugreen:', $hostname, '"', "\n",
    'WD_CLOUD_REMOTE="wd-cloud:"', "\n",
    'LOG_FILE="${LOCAL_PATH}/logs/backup-$(date +%Y%m%d).log"', "\n",
    'TIMESTAMP=$(date +%Y%m%d_%H%M%S)', "\n",
    'RETENTION_DAYS=', String($retention_days), "\n",
    'ITEM_TIMEOUT="', $item_timeout, '"', "\n",
    'PCLOUD_TRANSFERS="', String($transfers), '"', "\n",
    'PCLOUD_CHECKERS="', String($checkers), '"', "\n",
    $bwlimit_line, "\n",
  ].join('')

  $backup_sh_top = @(BACKUPTOP)
    #!/bin/bash
    # Homelab Backup Script
    # Managed by OpenVox - do not edit manually

    set -euo pipefail

    # Configuration
    | BACKUPTOP

  $backup_sh_functions = @(BACKUPFUNCS)

    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # No Color

    error_handler() {
        local line_number=$1
        local error_code=$2
        log_error "Script failed at line $line_number with exit code $error_code"
        send_notification "Backup failed at line $line_number" "high"
        exit "$error_code"
    }

    trap 'error_handler ${LINENO} $?' ERR

    log() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
    }

    log_error() {
        echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" | tee -a "$LOG_FILE"
    }

    log_success() {
        echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $1${NC}" | tee -a "$LOG_FILE"
    }

    log_warn() {
        echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}" | tee -a "$LOG_FILE"
    }

    # secrets.ntfy is not configured in the vault today - Ansible's own
    # send_notification() falls back to this same log-only path on every
    # real host right now, so this matches current production behavior.
    send_notification() {
        local message="$1"
        log "Notification: $message"
    }

    UGREEN_AVAILABLE=0
    probe_ugreen() {
        [ -f "$UGREEN_KEY" ] || return 0
        if timeout 60s rclone mkdir "${UGREEN_REMOTE}-probe-$$" \
                --sftp-key-file "$UGREEN_KEY" \
                --timeout 20s --contimeout 20s --retries 1 >/dev/null 2>&1; then
            timeout 60s rclone rmdir "${UGREEN_REMOTE}-probe-$$" \
                --sftp-key-file "$UGREEN_KEY" >/dev/null 2>&1
            UGREEN_AVAILABLE=1
        else
            log_warn "ugreen is not writable - skipping the on-prem leg for this run"
        fi
    }

    sync_to_ugreen() {
        local snapshot_dir="$1"
        local remote_suffix="$2"

        if [ "$UGREEN_AVAILABLE" != "1" ]; then
            return 0
        fi

        timeout "$ITEM_TIMEOUT" rclone sync "$snapshot_dir" "${UGREEN_REMOTE}/${remote_suffix}" \
            --sftp-key-file "$UGREEN_KEY" \
            --transfers 2 --checkers 4 \
            --timeout 60s --contimeout 20s --low-level-retries 3 \
            --log-file="$LOG_FILE" --log-level INFO || {
            log_warn "Failed to sync ${remote_suffix} to ugreen (on-prem copy only, not fatal)"
            return 1
        }
        return 0
    }

    sync_to_wdcloud() {
        local snapshot_dir="$1"
        local remote_suffix="$2"

        timeout "$ITEM_TIMEOUT" rclone sync "$snapshot_dir" "${WD_CLOUD_REMOTE}backup/${remote_suffix}" \
            --transfers 2 --checkers 4 \
            --timeout 60s --contimeout 20s --low-level-retries 3 \
            --log-file="$LOG_FILE" --log-level INFO || {
            log_warn "Failed to sync ${remote_suffix} to wd-cloud (push-only copy, not fatal)"
            return 1
        }
        return 0
    }

    backup_volume() {
        local volume_name="$1"
        local wd_cloud="${2:-true}"

        local volume_path
        volume_path=$(docker volume inspect --format '{{.Mountpoint}}' "$volume_name" 2>/dev/null)

        if [ -z "$volume_path" ] || [ ! -d "$volume_path" ]; then
            log_warn "Volume $volume_name not found or invalid path: $volume_path"
            return 1
        fi

        log "Backing up Docker volume: $volume_name"

        local snapshot_dir="${LOCAL_PATH}/volumes/${volume_name}"
        mkdir -p "$snapshot_dir"

        timeout "$ITEM_TIMEOUT" rsync -a --delete --info=progress2 "$volume_path/" "$snapshot_dir/" 2>> "$LOG_FILE" || {
            log_error "Failed to rsync volume $volume_name"
            return 1
        }

        timeout "$ITEM_TIMEOUT" rclone sync "$snapshot_dir" "${REMOTE}/volumes/${volume_name}" \
            --progress \
            --transfers "$PCLOUD_TRANSFERS" \
            --checkers "$PCLOUD_CHECKERS" \
            "${PCLOUD_BWLIMIT_ARGS[@]}" \
            --timeout 60s --contimeout 20s --low-level-retries 3 \
            --log-file="$LOG_FILE" \
            --log-level INFO || {
            log_error "Failed to sync volume $volume_name to remote"
            return 1
        }

        sync_to_ugreen "$snapshot_dir" "volumes/${volume_name}"

        if [ "$wd_cloud" = "true" ]; then
            sync_to_wdcloud "$snapshot_dir" "volumes/${volume_name}"
        fi

        log_success "Volume $volume_name backed up successfully"
        return 0
    }

    backup_path() {
        local source_path="$1"
        local optional="${2:-false}"
        local wd_cloud="${3:-true}"
        local backup_name
        backup_name=$(basename "$source_path")

        if [ ! -d "$source_path" ]; then
            if [ "$optional" = "true" ]; then
                log "Skipping optional path $source_path (not configured yet)"
                return 0
            fi
            log_warn "Path $source_path not found"
            return 1
        fi

        log "Backing up path: $source_path"

        timeout "$ITEM_TIMEOUT" rclone sync "$source_path" "${REMOTE}/paths/${backup_name}" \
            --progress \
            --transfers "$PCLOUD_TRANSFERS" \
            --checkers "$PCLOUD_CHECKERS" \
            "${PCLOUD_BWLIMIT_ARGS[@]}" \
            --timeout 60s --contimeout 20s --low-level-retries 3 \
            --log-file="$LOG_FILE" \
            --log-level INFO || {
            log_error "Failed to sync path $source_path to remote"
            return 1
        }

        sync_to_ugreen "$source_path" "paths/${backup_name}"

        if [ "$wd_cloud" = "true" ]; then
            sync_to_wdcloud "$source_path" "${backup_name}"
        fi

        log_success "Path $source_path backed up successfully"
        return 0
    }

    run_pre_hook() {
        local service="$1"
        local hook="$2"

        if [ -n "$hook" ]; then
            log "Running pre-backup hook for $service"
            bash -c "$hook" 2>> "$LOG_FILE" || {
                log_warn "Pre-backup hook for $service failed"
                return 1
            }
        fi
        return 0
    }

    run_post_hook() {
        local service="$1"
        local hook="$2"

        if [ -n "$hook" ]; then
            log "Running post-backup hook for $service"
            bash -c "$hook" 2>> "$LOG_FILE" || {
                log_warn "Post-backup hook for $service failed"
                return 1
            }
        fi
        return 0
    }

    cleanup_old_logs() {
        log "Cleaning up logs older than $RETENTION_DAYS days"
        find "${LOCAL_PATH}/logs" -name "backup-*.log" -mtime +${RETENTION_DAYS} -delete 2>/dev/null || true
    }

    main() {
        log "=========================================="
        log "Starting homelab backup - $TIMESTAMP"
        log "=========================================="

        local failed_critical=()
        local failed_noncritical=()
        local success_count=0
        local total_count=0

        probe_ugreen

    | BACKUPFUNCS

  $backup_sh_bottom = @(BACKUPBOTTOM)

        cleanup_old_logs

        log "=========================================="
        log "Backup Summary"
        log "=========================================="
        log "Total services: $total_count"
        log "Successful: $success_count"
        log "Critical failures: ${#failed_critical[@]}"
        log "Non-critical failures: ${#failed_noncritical[@]}"

        if [ ${#failed_critical[@]} -gt 0 ]; then
            log_error "Critical backup failures: ${failed_critical[*]}"
            send_notification "Critical backup failures: ${failed_critical[*]}" "high"
            exit 1
        fi

        if [ ${#failed_noncritical[@]} -gt 0 ]; then
            log_warn "Non-critical backup failures: ${failed_noncritical[*]}"
            send_notification "Non-critical backup failures: ${failed_noncritical[*]}" "default"
        fi

        log_success "Critical backups completed successfully!"
        send_notification "All backups completed successfully ($success_count/$total_count)" "default"
        exit 0
    }

    main "$@"
    | BACKUPBOTTOM

  $backup_service_blocks = $host_configs.reduce('') |$acc, $kv| {
    $name = $kv[0]
    $cfg  = $kv[1]

    $pre_call = $cfg['pre_hook'] ? {
      undef   => '',
      default => [
        '    run_pre_hook "', $name, '" \'', $cfg['pre_hook'].regsubst("'", "'\\\\''", 'G'), '\' || service_failed=true', "\n",
      ].join(''),
    }
    $post_call = $cfg['post_hook'] ? {
      undef   => '',
      default => [
        '    run_post_hook "', $name, '" \'', $cfg['post_hook'].regsubst("'", "'\\\\''", 'G'), '\' || service_failed=true', "\n",
      ].join(''),
    }
    $vol_calls = $cfg['volumes'] ? {
      undef   => '',
      default => $cfg['volumes'].map |$v| { ['    backup_volume "', $v, '" "true" || service_failed=true', "\n"].join('') }.join(''),
    }
    $path_calls = $cfg['paths'] ? {
      undef   => '',
      default => $cfg['paths'].map |$p| { ['    backup_path "', $p, '" "false" "true" || service_failed=true', "\n"].join('') }.join(''),
    }
    $crit_block = $cfg['critical'] ? {
      true    => [
        '        failed_critical+=("', $name, '")', "\n",
        '        log_error "Critical service ', $name, ' backup failed!"', "\n",
      ].join(''),
      default => [
        '        failed_noncritical+=("', $name, '")', "\n",
        '        log_warn "Non-critical service ', $name, ' backup failed"', "\n",
      ].join(''),
    }

    $block = [
      '    # Backup ', $name, "\n",
      '    log "Processing service: ', $name, '"', "\n",
      '    total_count=$((total_count + 1))', "\n",
      '    service_failed=false', "\n\n",
      $pre_call, $vol_calls, $path_calls, $post_call, "\n",
      '    if [ "$service_failed" = true ]; then', "\n",
      $crit_block,
      '    else', "\n",
      '        success_count=$((success_count + 1))', "\n",
      '        log_success "Service ', $name, ' backup completed"', "\n",
      '    fi', "\n\n",
    ].join('')

    [$acc, $block].join('')
  }

  $backup_sh_content = [$backup_sh_top, $backup_config_block, $backup_sh_functions,
    $backup_service_blocks, $backup_sh_bottom].join('')

  # ==========================================================================
  # restore.sh - same construction rules as backup.sh above.
  # ==========================================================================
  $restore_config_block = [
    'REMOTE="', $remote_name, ':', $remote_path, '"', "\n",
    'LOCAL_PATH="', $local_path, '"', "\n",
  ].join('')

  $restore_services_usage = $host_configs.keys.map |$n| { ['    - ', $n, "\n"].join('') }.join('')

  $restore_sh_top = @(RESTORETOP)
    #!/bin/bash
    # Homelab Restore Script
    # Managed by OpenVox - do not edit manually

    set -euo pipefail

    # Configuration
    | RESTORETOP

  $restore_sh_funcs = @(RESTOREFUNCS)

    LOG_FILE="${LOCAL_PATH}/logs/restore-$(date +%Y%m%d).log"

    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color

    log() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
    }

    log_error() {
        echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" | tee -a "$LOG_FILE"
    }

    log_success() {
        echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $1${NC}" | tee -a "$LOG_FILE"
    }

    log_warn() {
        echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}" | tee -a "$LOG_FILE"
    }

    log_info() {
        echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1${NC}" | tee -a "$LOG_FILE"
    }

    | RESTOREFUNCS

  $restore_usage_and_body = @(RESTOREBODY)
    usage() {
        cat << USAGEEOF
    Usage: $0 [OPTIONS] <service|volume|path>

    Restore data from pCloud backup.

    Options:
        -l, --list              List available backups
        -s, --service SERVICE   Restore all data for a service
        -v, --volume VOLUME     Restore a specific Docker volume
        -p, --path PATH         Restore a specific path
        -d, --dry-run           Show what would be restored without doing it
        -f, --force             Skip confirmation prompts
        -h, --help              Show this help message

    Examples:
        $0 --list                    # List all available backups
        $0 --service mailcow         # Restore all mailcow data
        $0 --volume kuma_uptime-kuma-data  # Restore specific volume
        $0 --dry-run --service kuma  # Preview kuma restore

    Available services:
    | RESTOREBODY

  $restore_usage_footer = @(RESTOREUSAGEFOOTER)

    USAGEEOF
        exit 0
    }

    list_backups() {
        log_info "Listing available backups from $REMOTE"
        echo ""
        echo "=== Docker Volumes ==="
        rclone lsd "${REMOTE}/volumes" 2>/dev/null || echo "No volume backups found"
        echo ""
        echo "=== Paths ==="
        rclone lsd "${REMOTE}/paths" 2>/dev/null || echo "No path backups found"
    }

    restore_volume() {
        local volume_name="$1"
        local dry_run="${2:-false}"

        log "Restoring Docker volume: $volume_name"

        if ! rclone lsf "${REMOTE}/volumes/${volume_name}" --max-depth 1 > /dev/null 2>&1; then
            log_error "No backup found for volume $volume_name"
            return 1
        fi

        if ! docker volume inspect "$volume_name" > /dev/null 2>&1; then
            log_info "Creating Docker volume: $volume_name"
            docker volume create "$volume_name" > /dev/null
        fi

        local volume_path
        volume_path=$(docker volume inspect --format '{{.Mountpoint}}' "$volume_name" 2>/dev/null)
        if [ -z "$volume_path" ] || [ ! -d "$volume_path" ]; then
            log_error "Volume $volume_name has no usable mountpoint: $volume_path"
            return 1
        fi

        local rclone_opts="--progress --transfers 4 --checkers 8"
        if [ "$dry_run" = true ]; then
            rclone_opts="$rclone_opts --dry-run"
            log_info "DRY RUN - No changes will be made"
        fi

        rclone sync "${REMOTE}/volumes/${volume_name}" "$volume_path" \
            $rclone_opts \
            --log-file="$LOG_FILE" \
            --log-level INFO || {
            log_error "Failed to restore volume $volume_name"
            return 1
        }

        log_success "Volume $volume_name restored successfully"
        return 0
    }

    restore_path() {
        local path_name="$1"
        local target_path="$2"
        local dry_run="${3:-false}"

        log "Restoring path: $path_name to $target_path"

        if ! rclone lsf "${REMOTE}/paths/${path_name}" --max-depth 1 > /dev/null 2>&1; then
            log_error "No backup found for path $path_name"
            return 1
        fi

        if [ ! -d "$target_path" ]; then
            log_info "Creating target directory: $target_path"
            mkdir -p "$target_path"
        fi

        local rclone_opts="--progress --transfers 4 --checkers 8"
        if [ "$dry_run" = true ]; then
            rclone_opts="$rclone_opts --dry-run"
            log_info "DRY RUN - No changes will be made"
        fi

        rclone sync "${REMOTE}/paths/${path_name}" "$target_path" \
            $rclone_opts \
            --log-file="$LOG_FILE" \
            --log-level INFO || {
            log_error "Failed to restore path $path_name"
            return 1
        }

        log_success "Path $path_name restored successfully to $target_path"
        return 0
    }

    restore_service() {
        local service="$1"
        local dry_run="${2:-false}"
        local force="${3:-false}"

        log "=========================================="
        log "Restoring service: $service"
        log "=========================================="

        local failed=0

        case "$service" in
    | RESTOREUSAGEFOOTER

  $restore_cases = $host_configs.reduce('') |$acc, $kv| {
    $name = $kv[0]
    $cfg  = $kv[1]

    $vol_lines = $cfg['volumes'] ? {
      undef   => '',
      default => $cfg['volumes'].map |$v| {
        [
          '            log "Restoring volume: ', $v, '"', "\n",
          '            restore_volume "', $v, '" "$dry_run" || failed=1', "\n",
        ].join('')
      }.join(''),
    }
    $path_lines = $cfg['paths'] ? {
      undef   => '',
      default => $cfg['paths'].map |$p| {
        $bn = $p.split('/')[-1]
        [
          '            log "Restoring path: ', $p, '"', "\n",
          '            restore_path "', $bn, '" "', $p, '" "$dry_run" || failed=1', "\n",
        ].join('')
      }.join(''),
    }
    $restore_hook_block = $cfg['restore_post_hook'] ? {
      undef   => '',
      default => [
        '            if [ "$failed" -eq 0 ] && [ "$dry_run" != true ]; then', "\n",
        '                log "Running restore_post_hook for ', $name, '"', "\n",
        '                if ! (', "\n", $cfg['restore_post_hook'], "\n", '                ); then', "\n",
        '                    log_error "restore_post_hook failed for ', $name, ' - data is on disk but may not be re-imported into a running service"', "\n",
        '                    failed=1', "\n",
        '                fi', "\n",
        '            elif [ "$dry_run" = true ]; then', "\n",
        '                log_info "DRY RUN - would run restore_post_hook for ', $name, '"', "\n",
        '            fi', "\n",
      ].join(''),
    }

    [$acc, '        ', $name, ')', "\n", $vol_lines, $path_lines, $restore_hook_block, '            ;;', "\n"].join('')
  }

  $restore_sh_tail = @(RESTORETAIL)
            *)
                log_error "Unknown service: $service"
                return 1
                ;;
        esac

        if [ "$failed" -ne 0 ]; then
            log_error "Service $service restore completed with errors"
            return 1
        fi

        log_success "Service $service restore completed"
        return 0
    }

    DRY_RUN=false
    FORCE=false
    ACTION=""
    TARGET=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -l|--list)
                ACTION="list"
                shift
                ;;
            -s|--service)
                ACTION="service"
                TARGET="$2"
                shift 2
                ;;
            -v|--volume)
                ACTION="volume"
                TARGET="$2"
                shift 2
                ;;
            -p|--path)
                ACTION="path"
                TARGET="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                if [ -z "$ACTION" ]; then
                    ACTION="service"
                    TARGET="$1"
                fi
                shift
                ;;
        esac
    done

    case "$ACTION" in
        list)
            list_backups
            ;;
        service)
            if [ -z "$TARGET" ]; then
                log_error "No service specified"
                usage
            fi
            if [ "$FORCE" != true ] && [ "$DRY_RUN" != true ]; then
                read -p "Are you sure you want to restore service '$TARGET'? This may overwrite existing data. [y/N] " confirm
                if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                    log "Restore cancelled"
                    exit 0
                fi
            fi
            restore_service "$TARGET" "$DRY_RUN" "$FORCE"
            ;;
        volume)
            if [ -z "$TARGET" ]; then
                log_error "No volume specified"
                usage
            fi
            if [ "$FORCE" != true ] && [ "$DRY_RUN" != true ]; then
                read -p "Are you sure you want to restore volume '$TARGET'? This may overwrite existing data. [y/N] " confirm
                if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                    log "Restore cancelled"
                    exit 0
                fi
            fi
            restore_volume "$TARGET" "$DRY_RUN"
            ;;
        path)
            if [ -z "$TARGET" ]; then
                log_error "No path specified"
                usage
            fi
            if [ "$FORCE" != true ] && [ "$DRY_RUN" != true ]; then
                read -p "Are you sure you want to restore path '$TARGET'? This may overwrite existing data. [y/N] " confirm
                if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                    log "Restore cancelled"
                    exit 0
                fi
            fi
            restore_path "$(basename "$TARGET")" "$TARGET" "$DRY_RUN"
            ;;
        *)
            usage
            ;;
    esac
    | RESTORETAIL

  $restore_sh_content = [$restore_sh_top, $restore_config_block, $restore_sh_funcs,
    $restore_usage_and_body, $restore_services_usage, $restore_usage_footer,
    $restore_cases, $restore_sh_tail].join('')

  # ==========================================================================
  # Filesystem layout, rclone, generated scripts, systemd timer
  # ==========================================================================
  package { 'rclone':
    ensure => installed,
  }

  file { [$local_path, "${local_path}/volumes", "${local_path}/scripts", "${local_path}/logs", $rclone_config_path]:
    ensure => directory,
    mode   => '0700',
  }

  $wd_cloud_block = $wd_cloud_password.unwrap ? {
    ''      => '',
    default => "\n[wd-cloud]\ntype = smb\nhost = 192.168.50.176\nuser = ${wd_cloud_user.unwrap}\npass = ${wd_cloud_password.unwrap}\n",
  }

  $rclone_conf_content = Sensitive(
    "# rclone configuration for pCloud\n# Managed by OpenVox - do not edit manually\n\n[${remote_name}]\ntype = pcloud\nhostname = eapi.pcloud.com\ntoken = ${pcloud_token.unwrap}\n\n[ugreen]\ntype = sftp\nhost = 100.100.10.4\nuser = rclone-backup\nkey_file = /opt/backup-remote/ssh/id_ed25519\nshell_type = unix\nmd5sum_command = none\nsha1sum_command = none\n${wd_cloud_block}"
  )

  file { "${rclone_config_path}/rclone.conf":
    ensure  => file,
    mode    => '0600',
    content => $rclone_conf_content,
    require => File[$rclone_config_path],
  }

  file { "${local_path}/scripts/backup.sh":
    ensure  => file,
    mode    => '0700',
    content => $backup_sh_content,
    require => File["${local_path}/scripts"],
  }

  file { "${local_path}/scripts/restore.sh":
    ensure  => file,
    mode    => '0700',
    content => $restore_sh_content,
    require => File["${local_path}/scripts"],
  }

  $cpu_quota_line = $cpu_quota ? {
    ''      => '',
    default => ['CPUQuota=', $cpu_quota, "\n"].join(''),
  }

  file { '/etc/systemd/system/homelab-backup.service':
    ensure  => file,
    mode    => '0644',
    content => ["[Unit]\nDescription=Homelab Backup Service\nAfter=network-online.target docker.service\nWants=network-online.target\n\n[Service]\nType=oneshot\nExecStart=${local_path}/scripts/backup.sh\nStandardOutput=journal\nStandardError=journal\nTimeoutStartSec=10800\nNice=19\nIOSchedulingClass=idle\n", $cpu_quota_line, "\n[Install]\nWantedBy=multi-user.target\n"].join(''),
    notify  => Exec['backup-systemd-reload'],
  }

  file { '/etc/systemd/system/homelab-backup.timer':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=Homelab Backup Timer\n\n[Timer]\nOnCalendar=${backup_schedule}\nPersistent=true\nRandomizedDelaySec=15min\nUnit=homelab-backup.service\n\n[Install]\nWantedBy=timers.target\n",
    notify  => Exec['backup-systemd-reload'],
  }

  exec { 'backup-systemd-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
  }

  service { 'homelab-backup.timer':
    ensure  => running,
    enable  => true,
    require => [File['/etc/systemd/system/homelab-backup.timer'], Exec['backup-systemd-reload']],
  }

  # Fresh-install marker. `replace => false` deliberately: unlike the
  # Ansible task (which has no such guard and re-writes this file, with a
  # fresh embedded timestamp, on every single run), this only ever
  # creates it once. Functionally equivalent - the file's mere existence
  # is the only thing anything reads - and it stops a spurious diff every
  # apply on hosts that are already initialized (both real targets today).
  file { "${base_path}/.homelab-initialized":
    ensure  => file,
    mode    => '0644',
    replace => false,
    content => "# Homelab Initialization Flag\n# Host: ${hostname}\n#\n# This file indicates that the host has been initialized.\n# Delete this file to allow a manual restore workflow (see restore.sh).\n",
  }
}

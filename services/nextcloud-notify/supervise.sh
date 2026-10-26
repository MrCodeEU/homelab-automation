#!/bin/sh
# Keeps two Nextcloud jobs alive from outside the Nextcloud AIO containers:
#
#   1. `occ files_external:notify <mount>` for the external storages listed in
#      NOTIFY_MOUNTS. It makes Nextcloud pick up files that arrive outside
#      Nextcloud (Syncthing into /mnt/user/Fotos) and feeds the preview
#      generator's queue. It dies whenever the container restarts, which AIO
#      does every night during its backup, so it is checked every
#      CHECK_INTERVAL seconds and restarted when missing.
#   2. `occ preview:pre-generate` once a day at PREGEN_TIME.
#
# Everything is UTC (the Nextcloud container and AIO's backup schedule are UTC).
# Needs the Docker socket; talks to Nextcloud only through `docker exec`.
#
# Env: NEXTCLOUD_CONTAINER, NOTIFY_MOUNTS (space separated mount ids),
#      NO_PREVIEW_MOUNTS (mount ids whose previews are switched off),
#      PREGEN_TIME (HH:MM), CHECK_INTERVAL (seconds)

NC="${NEXTCLOUD_CONTAINER:-nextcloud-aio-nextcloud}"
NOTIFY_MOUNTS="${NOTIFY_MOUNTS:-1}"
NO_PREVIEW_MOUNTS="${NO_PREVIEW_MOUNTS:-}"
PREGEN_TIME="${PREGEN_TIME:-03:30}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
HEALTH_FILE=/tmp/healthy

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

occ() { docker exec -u www-data "$NC" php /var/www/html/occ "$@"; }

nextcloud_ready() {
  [ "$(docker inspect -f '{{.State.Running}}' "$NC" 2>/dev/null)" = "true" ] || return 1
  status=$(occ status --output=json 2>/dev/null) || return 1
  case "$status" in
    *'"installed":true'*'"maintenance":false'*) return 0 ;;
    *) return 1 ;;
  esac
}

watcher_running() {
  docker exec "$NC" ps -eo args 2>/dev/null | grep -q "files_external:notify $1\$"
}

supervise() {
  while :; do
    if nextcloud_ready; then
      all_up=1
      for m in $NOTIFY_MOUNTS; do
        if ! watcher_running "$m"; then
          if docker exec -d -u www-data "$NC" php /var/www/html/occ files_external:notify "$m"; then
            log "started files_external:notify for mount $m"
          else
            log "ERROR: could not start files_external:notify for mount $m"
            all_up=0
          fi
        fi
      done
      for m in $NO_PREVIEW_MOUNTS; do
        # Prints "true" or "1" while on and nothing at all once it is off.
        cur=$(occ files_external:option "$m" previews 2>/dev/null)
        if [ -n "$cur" ] && [ "$cur" != "false" ] && [ "$cur" != "0" ]; then
          occ files_external:option "$m" previews false >/dev/null \
            && log "disabled previews for mount $m"
        fi
      done
      [ "$all_up" = 1 ] && touch "$HEALTH_FILE"
    fi
    sleep "$CHECK_INTERVAL"
  done
}

pregenerate() {
  while :; do
    if [ "$(date +%H:%M)" = "$PREGEN_TIME" ] && [ "$(cat /tmp/pregen.day 2>/dev/null)" != "$(date +%F)" ]; then
      date +%F > /tmp/pregen.day
      if nextcloud_ready; then
        log "preview:pre-generate start"
        if occ preview:pre-generate -n; then
          log "preview:pre-generate done"
        else
          log "preview:pre-generate failed or was interrupted (container restart?)"
        fi
      else
        log "preview:pre-generate skipped, Nextcloud not ready"
      fi
    fi
    sleep 30
  done
}

log "starting: container=$NC notify_mounts='$NOTIFY_MOUNTS' no_preview_mounts='$NO_PREVIEW_MOUNTS' pregen=$PREGEN_TIME UTC"
supervise &
pregenerate &
wait

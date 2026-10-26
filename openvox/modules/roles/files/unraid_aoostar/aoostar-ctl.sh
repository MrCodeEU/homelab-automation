#!/bin/bash
# Start, stop and inspect the AOOSTAR display driver and its controller.
# Managed by OpenVox (roles::unraid_aoostar_proxy, proxy-exec from nuc) - do not edit manually.
#
# AOOSTAR-X (vendor binary, web UI on :5123) drives the LCD and the fans;
# aoostar-controller.sh drives AOOSTAR-X's web UI (Immich photo, night mode).
# Both run detached in their own session so one signal to the process group
# stops a process and everything it spawned (the binary unpacks itself and
# runs a child of the same name).
#
# Unraid does not stop processes started from User Scripts when the array
# stops, which used to block shutdown until the driver was killed by hand;
# the "stop" User Script calls `aoostar-ctl.sh stop`.
set -uo pipefail

DIR="${AOOSTAR_DIR:-/mnt/user/appdata/aoostar}"
BINARY="$DIR/AOOSTAR-X"
CONTROLLER="$DIR/aoostar-controller.sh"
PID_X=/var/run/aoostar-x.pid
PID_C=/var/run/aoostar-controller.pid
LOG_X=/var/log/aoostar-x.log
LOG_C=/var/log/aoostar-controller.log
UI_URL="http://127.0.0.1:5123/"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] aoostar-ctl: $*"; }

alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

stop_one() {
  local pidfile=$1 name=$2 pid
  if alive "$pidfile"; then
    pid=$(cat "$pidfile")
    log "stopping $name (process group $pid)"
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      log "$name ignored SIGTERM, sending SIGKILL"
      kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    fi
  fi
  rm -f "$pidfile"
}

# Anything still running from the binary (e.g. started by hand or by the old
# User Scripts, so without a pidfile or process group of ours).
kill_strays() {
  local p exe
  for p in /proc/[0-9]*; do
    exe=$(readlink "$p/exe" 2>/dev/null) || continue
    case "$exe" in
      "$BINARY"*) log "killing stray ${p#/proc/} ($exe)"; kill -KILL "${p#/proc/}" 2>/dev/null ;;
    esac
  done
}

stop() {
  stop_one "$PID_C" "controller"
  stop_one "$PID_X" "AOOSTAR-X"
  kill_strays
}

# The vendor UI keeps its login in Monitor3.json (plain text). controller.env
# is the source of truth, so the vendor login follows it at every start.
sync_ui_password() {
  local env_file="$DIR/controller.env" cfg="$DIR/Monitor3.json"
  [ -r "$env_file" ] && [ -f "$cfg" ] || return 0
  (
    # shellcheck disable=SC1090
    . "$env_file"
    AOOSTAR_PW="${PASSWORD:-}" python3 - "$cfg" <<'PY'
import json, os, sys
path, pw = sys.argv[1], os.environ.get("AOOSTAR_PW", "")
if not pw:
    sys.exit(0)
with open(path) as f:
    cfg = json.load(f)
if cfg.get("credentials", {}).get("password") != pw:
    cfg.setdefault("credentials", {})["password"] = pw
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print("vendor UI password updated from controller.env")
PY
  ) | while IFS= read -r l; do log "$l"; done
}

start() {
  if [ ! -x "$BINARY" ]; then
    log "ERROR: $BINARY missing or not executable"
    return 1
  fi
  stop
  sync_ui_password
  cd "$DIR" || return 1
  log "starting AOOSTAR-X"
  setsid nohup "$BINARY" >> "$LOG_X" 2>&1 < /dev/null &
  echo $! > "$PID_X"

  for _ in $(seq 1 60); do
    curl -s -o /dev/null --max-time 2 "$UI_URL" && break
    sleep 1
  done
  curl -s -o /dev/null --max-time 2 "$UI_URL" || log "WARNING: AOOSTAR-X web UI not answering after 60s, starting the controller anyway"

  if [ -x "$CONTROLLER" ]; then
    log "starting controller"
    setsid nohup "$CONTROLLER" daemon >> "$LOG_C" 2>&1 < /dev/null &
    echo $! > "$PID_C"
  else
    log "WARNING: $CONTROLLER missing, display driver runs without controller"
  fi
  log "started (driver pid $(cat "$PID_X"), logs $LOG_X and $LOG_C)"
}

status() {
  local rc=0
  if alive "$PID_X"; then echo "AOOSTAR-X:  running (pid $(cat "$PID_X"))"; else echo "AOOSTAR-X:  stopped"; rc=1; fi
  if alive "$PID_C"; then echo "controller: running (pid $(cat "$PID_C"))"; else echo "controller: stopped"; rc=1; fi
  if curl -s -o /dev/null --max-time 2 "$UI_URL"; then echo "web UI:     answering on :5123"; else echo "web UI:     not answering"; fi
  return $rc
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  *) echo "usage: $0 {start|stop|restart|status}" >&2; exit 2 ;;
esac

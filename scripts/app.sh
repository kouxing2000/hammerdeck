#!/usr/bin/env bash
#
# Hammerdeck control script -- start / stop / restart / status / logs.
#
# "start" rebuilds (swift build) and launches the built binary in the
# background so you always run the latest code; the menubar app keeps running
# after the terminal closes (nohup + reparented to launchd). PID + the
# launcher's stdout live under the app's own Application Support dir, so they
# survive a `swift package clean` that would wipe .build.
#
# Usage: scripts/app.sh {start|stop|restart|status|logs} [-- extra args to the binary]
# The thin start.sh / stop.sh / restart.sh wrappers just call this.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$HOME/Library/Application Support/Hammerdeck/run"
PIDFILE="$RUN_DIR/hammerdeck.pid"
OUTLOG="$RUN_DIR/stdout.log"

mkdir -p "$RUN_DIR"

bin_path() {
    # Resolve the built binary path for this machine's architecture.
    echo "$(cd "$REPO" && swift build --show-bin-path 2>/dev/null)/Hammerdeck"
}

# Echo the PID of a live Hammerdeck process, preferring the pidfile and falling
# back to a match on the exact binary path (so we still find it after a manual
# `swift run`). Empty output => not running.
running_pid() {
    if [[ -f "$PIDFILE" ]]; then
        local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"; return 0
        fi
        rm -f "$PIDFILE"   # stale
    fi
    # Fallback: anything running out of this repo's .build dir.
    pgrep -f "$REPO/.build/.*/Hammerdeck\$" 2>/dev/null | head -1 || true
}

cmd_start() {
    local pid; pid="$(running_pid)"
    if [[ -n "$pid" ]]; then
        echo "already running (PID $pid) -- use restart to relaunch"
        return 0
    fi

    echo "building..."
    ( cd "$REPO" && swift build )   # fail here => we never launch

    local bin; bin="$(bin_path)"
    if [[ ! -x "$bin" ]]; then
        echo "ERROR: built binary not found at $bin" >&2
        return 1
    fi

    echo "----- $(date '+%Y-%m-%d %H:%M:%S') start -----" >>"$OUTLOG"
    nohup "$bin" "$@" >>"$OUTLOG" 2>&1 &
    local newpid=$!
    echo "$newpid" >"$PIDFILE"
    sleep 1
    if kill -0 "$newpid" 2>/dev/null; then
        echo "started (PID $newpid); stdout -> $OUTLOG"
    else
        echo "ERROR: process exited immediately -- last log lines:" >&2
        tail -n 20 "$OUTLOG" >&2
        rm -f "$PIDFILE"
        return 1
    fi
}

cmd_stop() {
    local pid; pid="$(running_pid)"
    if [[ -z "$pid" ]]; then
        echo "not running"
        rm -f "$PIDFILE"
        return 0
    fi
    echo "stopping (PID $pid)..."
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do            # up to ~5s for a graceful exit
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "still alive after SIGTERM -- sending SIGKILL"
        kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
    echo "stopped"
}

cmd_restart() {
    cmd_stop
    cmd_start "$@"
}

cmd_status() {
    local pid; pid="$(running_pid)"
    if [[ -n "$pid" ]]; then
        echo "running (PID $pid)"
    else
        echo "stopped"
    fi
}

cmd_logs() {
    # The app's own daily logs live in .../Hammerdeck/logs ("Open Logs" in the
    # menubar); this tails the launcher's captured stdout/stderr.
    echo "tailing $OUTLOG (Ctrl-C to stop)"
    touch "$OUTLOG"
    tail -n 50 -f "$OUTLOG"
}

sub="${1:-}"; shift || true
# allow an optional "--" separator before binary args
[[ "${1:-}" == "--" ]] && shift || true

case "$sub" in
    start)   cmd_start "$@" ;;
    stop)    cmd_stop ;;
    restart) cmd_restart "$@" ;;
    status)  cmd_status ;;
    logs)    cmd_logs ;;
    *)
        echo "usage: $0 {start|stop|restart|status|logs}" >&2
        exit 2
        ;;
esac

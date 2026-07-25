#!/usr/bin/env bash
#
# Send a line of Lua to the RUNNING Hammerdeck app and print its result.
#
# The app must be started with the control channel enabled -- scripts/app.sh
# start does that automatically (it sets HAMMERDECK_CONTROL_DIR). The full Lua
# platform is reachable, so you can drive or query anything:
#
#   scripts/control.sh "require('platform.registry').setEnabled('command_palette', true); return 'on'"
#   scripts/control.sh "require('platform.registry').runAction('command_palette','main'); return 'opened'"
#   scripts/control.sh "return #require('platform.registry').all()"
#
# End the snippet with `return X` to read a value back; otherwise you get "nil".
# Pair with scripts/shot.sh to capture a screenshot for visual verification.
#
# SINGLE-USER by construction: the file handshake has no request/response
# correlation id, so two callers racing on cmd.lua/result.txt can hand each
# other's answers back or strand a command entirely. That used to be a comment
# asking you not to do it; it is now ENFORCED by the lock below, because the
# symptom (a timeout that reads as "the app is hung") costs far more to diagnose
# than the collision costs to prevent. Agents in particular batch independent
# commands into one parallel block by default -- a note in a header does not
# reach them.

set -euo pipefail

CONTROL_DIR="$HOME/Library/Application Support/Hammerdeck/run/control"
CMD="$CONTROL_DIR/cmd.lua"
RES="$CONTROL_DIR/result.txt"
LOCK="$CONTROL_DIR/.inflight.lock"

code="${1:-}"
if [[ -z "$code" ]]; then
    echo "usage: $0 '<lua; end with: return X to read a value>'" >&2
    exit 2
fi

mkdir -p "$CONTROL_DIR"

# Mutual exclusion. `mkdir` is the atomic test-and-set here -- macOS has no
# flock(1) -- and the pid inside lets us tell a live holder from a stale lock a
# killed run left behind. Without the staleness check, one ^C would wedge the
# tool permanently, trading a transient failure for a persistent one.
acquire_lock() {
    if mkdir "$LOCK" 2>/dev/null; then
        echo $$ >"$LOCK/pid"
        return 0
    fi
    local holder
    holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
        echo "ERROR: another control.sh (PID $holder) is mid-request." >&2
        echo "  This channel is single-user: one command at a time, never in parallel." >&2
        echo "  Run them sequentially, or wait for that one to finish (~8s max)." >&2
        return 1
    fi
    # Holder is gone (or never recorded one): reclaim and retry once.
    echo "note: clearing a stale lock from PID ${holder:-unknown}" >&2
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || { echo "ERROR: could not acquire $LOCK" >&2; return 1; }
    echo $$ >"$LOCK/pid"
}
acquire_lock || exit 3
trap 'rm -rf "$LOCK"' EXIT       # released on success, failure, and ^C alike

rm -f "$RES"                      # so the result's appearance means "fresh"
# Atomic publish: the app's poller guards only on existence, so write to a temp
# then rename (same dir => atomic) so it never reads a half-written command.
printf '%s' "$code" >"$CMD.tmp" && mv -f "$CMD.tmp" "$CMD"

# The app polls every 0.2s; wait up to ~8s for it to consume + answer.
for _ in $(seq 1 80); do
    if [[ -f "$RES" ]]; then
        cat "$RES"; echo
        exit 0
    fi
    sleep 0.1
done

echo "ERROR: no response from the app." >&2
echo "  Is it running with control enabled?  scripts/app.sh status" >&2
echo "  (control needs a start via scripts/app.sh, which sets HAMMERDECK_CONTROL_DIR)" >&2
echo "  If it IS running: the poller may be stalled behind an open menubar menu or" >&2
echo "  a modal panel -- dismiss it and retry. cmd.lua is left in place on purpose," >&2
echo "  so a stalled poller picks this command up as soon as it resumes." >&2
exit 1

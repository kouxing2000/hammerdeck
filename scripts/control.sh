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
# NOTE: single-user debug tool -- do not run two instances concurrently (the
# file handshake has no request/response correlation id).

set -euo pipefail

CONTROL_DIR="$HOME/Library/Application Support/Hammerdeck/run/control"
CMD="$CONTROL_DIR/cmd.lua"
RES="$CONTROL_DIR/result.txt"

code="${1:-}"
if [[ -z "$code" ]]; then
    echo "usage: $0 '<lua; end with: return X to read a value>'" >&2
    exit 2
fi

mkdir -p "$CONTROL_DIR"
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
exit 1

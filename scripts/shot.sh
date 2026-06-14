#!/usr/bin/env bash
#
# Capture a screenshot of the current screen for visual verification of the
# live app's UI (the one thing the in-process tests cannot check).
#
# Usage:
#   scripts/shot.sh [outfile.png]        # default: /tmp/hammerdeck-shot.png
#   HD_SHOT_DELAY=0.6 scripts/shot.sh    # longer settle before capture
#
# Typical agent flow:
#   scripts/app.sh start
#   scripts/control.sh "require('platform.registry').setEnabled('command_palette', true)
#                       require('platform.registry').runAction('command_palette','main'); return 'opened'"
#   scripts/shot.sh /tmp/palette.png     # then read the PNG
#
# PERMISSION: on macOS the process running this (your terminal / IDE) needs
# Screen Recording -- System Settings > Privacy & Security > Screen Recording.
# Without it screencapture silently returns only the desktop/wallpaper, so the
# panels will be MISSING from the image (it won't error). Grant it once.

set -euo pipefail

OUT="${1:-/tmp/hammerdeck-shot.png}"

sleep "${HD_SHOT_DELAY:-0.4}"            # let the panel finish drawing
screencapture -x "$OUT"                  # -x: silent (no shutter sound)

if [[ ! -s "$OUT" ]]; then
    echo "ERROR: capture failed -- $OUT is empty" >&2
    exit 1
fi
echo "$OUT"

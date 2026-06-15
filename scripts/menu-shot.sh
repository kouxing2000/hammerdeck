#!/usr/bin/env bash
#
# menu-shot.sh -- open Hammerdeck's menubar menu and screenshot JUST the menu.
#
# The status-bar menu is a transient popup that scripts/shot.sh can't reliably
# frame (it flashes, toggles closed, and its position shifts with the other menu
# extras). This helper instead asks Accessibility for the OPEN menu's exact
# rectangle and hands that straight to `screencapture -R`, so the capture is the
# menu and nothing else -- no guessed crop offsets.
#
# Usage:
#   scripts/app.sh start            # the app must be running with its menubar icon
#   scripts/menu-shot.sh [out.png]  # default: /tmp/hammerdeck-menu.png
#
# Then read the PNG. Pair with scripts/control.sh for non-menu UI.
#
# PERMISSION: the terminal/IDE running this needs BOTH Screen Recording (or the
# capture is blank) AND Accessibility (or the AX query returns nothing). Grant
# once in System Settings > Privacy & Security.
#
# GOTCHA: if two Hammerdeck instances are running you may screenshot a stale
# menu -- `pgrep -lf debug/Hammerdeck` and kill the extra first.

set -euo pipefail

OUT="${1:-/tmp/hammerdeck-menu.png}"
PROC="Hammerdeck"
DELAY="${HD_MENU_DELAY:-0.4}"

# Open the menu and read its exact on-screen rect (points, top-left origin --
# the same convention screencapture -R wants). The menu must be open for AX to
# report a size; right after launch the first open can race, so retry until the
# rect is well-formed (x,y,w,h with positive width/height).
read_rect() {
  osascript 2>/dev/null <<OSA
tell application "System Events" to tell process "$PROC"
  click menu bar item 1 of menu bar 1
  delay $DELAY
  set p to position of menu 1 of menu bar item 1 of menu bar 1
  set s to size of menu 1 of menu bar item 1 of menu bar 1
  return ((item 1 of p) as text) & "," & ((item 2 of p) as text) & "," & ((item 1 of s) as text) & "," & ((item 2 of s) as text)
end tell
OSA
}

RECT=""
for _ in 1 2 3; do
  R="$(read_rect | tr -d ' ')"
  if [[ "$R" =~ ^-?[0-9]+,-?[0-9]+,[1-9][0-9]*,[1-9][0-9]*$ ]]; then RECT="$R"; break; fi
  osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true   # close, then retry
  sleep 0.3
done

if [[ -z "${RECT:-}" ]]; then
  echo "menu-shot: could not read a valid menu rect." >&2
  echo "  - is $PROC running with a menubar icon? (scripts/app.sh status)" >&2
  echo "  - is Accessibility granted to this terminal/IDE?" >&2
  echo "  - more than one instance running? (pgrep -lf debug/Hammerdeck)" >&2
  osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
  exit 1
fi

screencapture -x -R"$RECT" "$OUT"

# Dismiss our own menu (it is the frontmost modal at this point, so Escape is safe).
osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true

echo "$OUT"

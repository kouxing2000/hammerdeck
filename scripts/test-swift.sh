#!/usr/bin/env bash
#
# Run `swift test` so a failure stays DIAGNOSABLE.
#
# WHY THIS EXISTS -- 2026-07-24. A Swift test failed exactly once during a
# verification sweep. The command had been run as `swift test 2>&1 | grep -E
# "Executed|failure"`, which reported "87 tests, 1 failure" and threw away the
# one thing that mattered: WHICH test. Fourteen re-runs could not reproduce it,
# so the failure is still unexplained -- not because it was hard to diagnose, but
# because the evidence was discarded before anyone looked at it.
#
# Two rules from the global CLAUDE.md meet here, and both were violated by that
# one pipe:
#   * a pipeline reports the LAST command's status, so `swift test | grep` exits
#     0 essentially always -- a hard failure reads as success;
#   * piping to a filter throws away everything the filter did not match, which
#     for a test run is precisely the failing case's identity and message.
#
# So: run to a LOG FILE, keep the real exit status, then surface the failures
# from the log. The full output is always kept, whatever happened.
#
#   scripts/test-swift.sh                 # whole suite (UI tests skipped)
#   scripts/test-swift.sh --filter Foo    # args pass through to `swift test`
#   HAMMERDECK_UI_TESTS=1 scripts/test-swift.sh   # include the UI-gated tests
#
# Companion to scripts/test-lua.sh (headless Lua on the embedded 5.4.7).
set -uo pipefail          # NOT -e: a test failure is an outcome to report, not an abort
cd "$(dirname "$0")/.."

LOG_DIR=".build/test-logs"
mkdir -p "$LOG_DIR"
# Plain sequential name, not a timestamp: this file is written by the run and
# read moments later, and a stable-ish path is easier to point someone at. Keep
# the last few so a flake caught on run N can still be compared against N-1.
LOG="$LOG_DIR/swift-test.log"
[ -f "$LOG" ] && mv "$LOG" "$LOG_DIR/swift-test.prev.log"

# The same link flags as app.sh / package.sh, so a test run does not relink the
# products that a dev run just built (lib/sdk-link-flags.sh says why they exist).
# shellcheck source=lib/sdk-link-flags.sh
source scripts/lib/sdk-link-flags.sh || exit 1   # no -e here; a silent miss relinks mis-stamped
swift test "${SWIFT_SDK_LINK_FLAGS[@]}" "$@" > "$LOG" 2>&1
status=$?

# The failing-case lines XCTest emits. Printed BEFORE the summary so the thing
# you need is the last thing on screen when there is one.
if [ "$status" -ne 0 ]; then
    echo "--- failures ---"
    grep -E "error:|' failed \(|Fatal error|Crashed" "$LOG" || \
        echo "(exit $status with no XCTest failure line -- a build error or a crash; read the log)"
    echo
fi

# The suite totals (last matching line: the outermost "All tests" summary).
grep -E "Executed [0-9]+ tests?, with" "$LOG" | tail -1 || true
echo "full log: $LOG"
exit "$status"

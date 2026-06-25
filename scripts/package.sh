#!/usr/bin/env bash
#
# Package Hammerdeck into a runnable macOS .app bundle (+ a zip for release upload).
#
# This is the version-controlled package recipe -- run it locally OR from CI
# (.github/workflows/release.yml calls this exact script on a v* tag). It is
# Tier A of docs/DISTRIBUTION.md: a self-contained, AD-HOC-signed .app that runs
# on THIS machine. Tier B (Developer ID signing + notarization, so it opens on a
# stranger's Mac past Gatekeeper) needs the Apple Developer account and is layered
# on later -- it does not change this script's shape, it adds steps after step 4.
#
# Usage:
#   scripts/package.sh [VERSION]
#     VERSION  marketing version for Info.plist (e.g. 1.2.0). Defaults to
#              `git describe` (the nearest tag), else 0.0.0-dev. A leading "v" is
#              stripped, so a `v1.2.0` tag yields 1.2.0.
#
# Output: dist/Hammerdeck.app and dist/Hammerdeck-<version>.zip
set -euo pipefail

APP_NAME="Hammerdeck"
# PLACEHOLDER bundle id. It pins the UserDefaults domain (and later the Sparkle
# feed), so changing it after real users exist orphans their settings -- finalize
# it (reverse-DNS under the Apple Developer prefix) before any public release.
# See docs/DISTRIBUTION.md "Lock these TODAY" #2.
BUNDLE_ID="${HAMMERDECK_BUNDLE_ID:-com.kouxing.hammerdeck}"
MIN_MACOS="13.0"   # must match Package.swift `platforms: [.macOS(.v13)]`

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo "0.0.0")"
fi
VERSION="${VERSION#v}"

# CFBundleShortVersionString must be 1-3 dot-separated integers. A bare commit
# hash (no tags yet) or a `git describe` with commits-since-tag (1.0.0-3-gabc)
# is invalid and Gatekeeper/Finder reject it -- fall back to 0.0.0 with a warning
# rather than ship a malformed plist. CI always passes a clean tag, so it's exact.
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "==> WARNING: '$VERSION' is not a numeric X.Y.Z version; using 0.0.0 (pass an explicit version or tag vX.Y.Z)"
  VERSION="0.0.0"
fi

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ZIP="$DIST/$APP_NAME-$VERSION.zip"

echo "==> Packaging $APP_NAME $VERSION (bundle id $BUNDLE_ID)"

# 1. Pre-package gate: the full test suite must pass (this is where the
#    feature-page roster<->feature.json consistency check, and every other
#    integration test, actually blocks a bad build from being packaged). The UI
#    tests that synthesize keystrokes stay skipped (HAMMERDECK_UI_TESTS unset).
if [[ "${HAMMERDECK_SKIP_TESTS:-0}" == "1" ]]; then
  echo "==> WARNING: skipping the test gate (HAMMERDECK_SKIP_TESTS=1)"
else
  echo "==> swift test (pre-package gate)"
  swift test
fi

# 2. Release build.
echo "==> swift build -c release"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
[[ -x "$BIN" ]] || { echo "error: build did not produce $BIN" >&2; exit 1; }

# 3. Assemble the .app tree.
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/design"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Lua payload: the app/ tree MINUS the compiled swift/ dirs (the runtime loads
# only .lua + feature.json + assets; the Swift is already inside the binary).
# resourceRoot() looks for Resources/app/hammerdeck.lua to detect a bundle.
rsync -a --exclude 'swift/' "$ROOT/app/" "$APP/Contents/Resources/app/"

# Runtime app icon (just the one asset, not the dev mockups in design/). The
# live Dock icon is set at runtime by makeDockIcon() from this PNG.
cp "$ROOT/design/AppIcon.png" "$APP/Contents/Resources/design/AppIcon.png"

# Finder / Get-Info / launch tile icon: build a real .icns from the same PNG so a
# downloaded app doesn't show the generic blank-app icon (looks broken).
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -z "$sz" "$sz" "$ROOT/design/AppIcon.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sips -z "$((sz*2))" "$((sz*2))" "$ROOT/design/AppIcon.png" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Info.plist. No LSUIElement: the app manages its Dock presence at runtime
# (DockPreference, default shown), so it launches as a regular app and can demote
# itself to a menubar accessory live -- matching `swift run`.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 4. Ad-hoc codesign (deep): signs the bundled binary so the app runs locally.
#    Tier B replaces "-" with the Developer ID identity + adds notarize/staple.
echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

# 5. Zip the bundle (ditto preserves the .app structure, symlinks, signature).
echo "==> zipping $ZIP"
rm -f "$ZIP"
( cd "$DIST" && ditto -c -k --keepParent "$APP_NAME.app" "$(basename "$ZIP")" )

echo "==> done"
echo "    app: $APP"
echo "    zip: $ZIP"

#!/usr/bin/env bash
#
# Package Hammerdeck into a runnable macOS .app bundle and the .dmg that ships.
#
# This is the version-controlled package recipe -- run it locally OR from CI
# (.github/workflows/release.yml calls this exact script on a v* tag).
#
# It picks its own tier from what is available on the machine, so a clone with no
# Apple Developer account still produces a working local build:
#
#   Tier B  a Developer ID Application identity is in the keychain -> hardened
#           runtime + Developer ID signature + notarization + stapled ticket. The
#           image opens on a stranger's Mac with no Gatekeeper wall.
#   Tier A  no such identity -> ad-hoc signature. Runs on THIS machine only; a
#           browser download is Gatekeeper-blocked and needs
#           `xattr -dr com.apple.quarantine`. The script says so, loudly.
#
# Usage:
#   scripts/package.sh [VERSION]
#     VERSION  marketing version for Info.plist (e.g. 1.2.0). Defaults to
#              `git describe` (the nearest tag), else 0.0.0-dev. A leading "v" is
#              stripped, so a `v1.2.0` tag yields 1.2.0.
#
# Environment:
#   HAMMERDECK_RELEASE_IDENTITY  Developer ID Application identity to sign with.
#              Defaults to the first one found in the keychain. Distinct from
#              HAMMERDECK_SIGN_IDENTITY, which app.sh uses for the *dev* cert.
#   HAMMERDECK_NOTARY_PROFILE    notarytool keychain profile (default
#              "hammerdeck-notary"); see `xcrun notarytool store-credentials`.
#              Used only when the ASC_* variables below are unset.
#   ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH
#              App Store Connect API key passed explicitly, for CI, which has no
#              login keychain to hold a stored profile. ASC_KEY_PATH defaults to
#              ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8. Same names
#              the studio's Fastfile uses, so one convention covers both.
#              The key id and issuer id are identifiers, not secrets; the .p8
#              itself is the credential and never belongs in this repo.
#   HAMMERDECK_UNIVERSAL=0       build arm64-only (faster; local iteration).
#   HAMMERDECK_SKIP_NOTARIZE=1   Tier B signing without the notarization round
#              trip -- for checking the signature without waiting on Apple.
#
# Output: dist/Hammerdeck.app and dist/Hammerdeck-<version>.dmg
#
# The DMG is the only shippable artifact. A zip is still made partway through,
# because notarytool takes an archive rather than a bundle, but it is deleted
# before this script exits so nothing downstream can pick it up by accident.
set -euo pipefail

APP_NAME="Hammerdeck"
# Settled 2026-08-11: `com.peach-studio` is a domain actually owned, and the name
# stays Hammerdeck. This id is FROZEN -- it is the UserDefaults domain, and a
# public download has shipped under it, so changing it orphans the settings of
# every installed copy. Treat it like the Sparkle feed URL below: not movable.
BUNDLE_ID="${HAMMERDECK_BUNDLE_ID:-com.peach-studio.hammerdeck}"
MIN_MACOS="13.0"   # must match Package.swift `platforms: [.macOS(.v13)]`

NOTARY_PROFILE="${HAMMERDECK_NOTARY_PROFILE:-hammerdeck-notary}"

# Sparkle. The feed URL is baked into EVERY build and old copies poll it forever --
# an installed build never learns a new address -- so this hostname must keep
# resolving for as long as any install survives. Treat it like the bundle id.
#
# Both URLs are CONSTANTS here, and the public key below is not overridable at all.
# An override on a value that must never vary can only produce a silently wrong
# build: ship the wrong public key and the app rejects every update it is ever
# offered, with nothing in the pipeline noticing. Change them here, in a reviewed
# commit.
#
# The STAGING feed exists so the update/recovery rehearsal has somewhere to run:
# install A, offer B, watch the replacement happen, without pointing a single real
# client at a test feed. `HAMMERDECK_FEED` selects between two reviewed constants
# -- it cannot introduce a third address. And the choice is not merely labelled in
# the bundle, it IS the baked `SUFeedURL`: publish-site.sh reads that value back
# out of the archive and derives the destination from it, so a staging build
# cannot be published to production even by someone who means to.
SPARKLE_FEED_URL_RELEASE="https://hammerdeck.peach-studio.com/appcast.xml"
SPARKLE_FEED_URL_STAGING="https://hammerdeck-staging.web.app/appcast.xml"
case "${HAMMERDECK_FEED:-release}" in
  release) SPARKLE_FEED_URL="$SPARKLE_FEED_URL_RELEASE" ;;
  staging) SPARKLE_FEED_URL="$SPARKLE_FEED_URL_STAGING" ;;
  *)
    echo "error: HAMMERDECK_FEED='$HAMMERDECK_FEED' -- expected 'release' or 'staging'." >&2
    exit 1 ;;
esac
# Public half of the EdDSA update-signing key; the private half is in the login
# Keychain and backed up outside this repo. Public by design -- it ships in every
# Info.plist, and its whole job is to let a user verify what we signed.
SPARKLE_PUBLIC_KEY="iQGMnp62O+kFU3jtfZaFfNFpmDe70W6P+NPWXPG5ojE="

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

# Provenance: which source this artifact was built from. Stamped into the bundle
# AND written beside the image, because the two answer different questions -- the
# plist travels with an installed copy ("which commit is this app I am testing?"),
# the sidecar records the bytes ("which archive did that evidence belong to?").
# Without both, provenance can only be argued from timestamps, which is how a
# whole day of real-lock evidence became unusable: nothing tied the running app
# to the commit whose fix it was supposed to be demonstrating.
#
# `--porcelain` non-empty means DIRTY, untracked files included -- not pedantry:
# step 3 rsyncs the whole `app/` tree into the bundle, so an untracked .lua in
# there ships, and a build containing code that is in no commit is exactly what
# this stamp exists to disclose. A clone with no git present stamps "unknown",
# which publish-site.sh refuses.
SRC_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ "$SRC_COMMIT" == "unknown" ]]; then
  SRC_STATUS="unknown"
elif [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  SRC_STATUS="dirty"
else
  SRC_STATUS="clean"
fi

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
# Notarization input only -- notarytool will not take a bundle. Deleted at the end.
ZIP="$DIST/$APP_NAME-$VERSION.notarize.zip"
PROVENANCE="$DIST/$APP_NAME-$VERSION.provenance.txt"

echo "==> Packaging $APP_NAME $VERSION (bundle id $BUNDLE_ID)"
echo "    source: $SRC_COMMIT ($SRC_STATUS)"
echo "    feed:   $SPARKLE_FEED_URL"

# 0. Validate the entitlements XML, in BOTH tiers and before the slow build.
#
#    Use xmllint, NOT `plutil -lint`. plutil accepts a double hyphen inside an XML
#    comment and reports OK; the parser codesign hands the file to (AMFI) rejects
#    the whole file.
#
#    Only Tier B consumes the entitlements (the Tier A branch signs ad-hoc without
#    them), so this does not protect a Tier A build -- it protects the Tier B one
#    from discovering the problem AFTER `swift test` and a universal release build.
#    Failing at step 0 costs seconds; failing at step 4 costs the whole run.
ENTITLEMENTS="$ROOT/scripts/$APP_NAME.entitlements"
if ! xmllint --noout "$ENTITLEMENTS"; then
  echo "error: $ENTITLEMENTS is not well-formed XML (see above); codesign would reject it" >&2
  exit 1
fi

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

# 2. Release build. Universal by default: Hammerdeck's floor is macOS 13, which
#    still runs on Intel, and an arm64-only bundle downloaded onto an Intel Mac
#    fails to launch with nothing on screen that explains why.
BUILD_FLAGS=(-c release)
if [[ "${HAMMERDECK_UNIVERSAL:-1}" == "1" ]]; then
  BUILD_FLAGS+=(--arch arm64 --arch x86_64)
  echo "==> swift build -c release (universal: arm64 + x86_64)"
else
  echo "==> swift build -c release (arm64 only -- HAMMERDECK_UNIVERSAL=0)"
fi
swift build "${BUILD_FLAGS[@]}"
BIN="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/$APP_NAME"
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
  <!-- Provenance, read by scripts/publish-site.sh and by anyone holding a copy:
       defaults read /path/to/Hammerdeck.app/Contents/Info HDSourceCommit
       An installed app can then name the commit it was built from, which is the
       one thing a manual test cannot establish about itself. -->
  <key>HDSourceCommit</key><string>$SRC_COMMIT</string>
  <key>HDSourceStatus</key><string>$SRC_STATUS</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- The string macOS puts in the Automation consent prompt. Without the key
       there is no prompt to present, so the Apple Event is denied outright and
       every AppleScript/JXA path (volume, appearance, power, browser reads)
       fails silently. Pairs with the apple-events entitlement. -->
  <key>NSAppleEventsUsageDescription</key><string>Hammerdeck controls other apps and system settings on your behalf -- adjusting volume and appearance, and reading the frontmost browser tab -- for the features you enable.</string>
  <!-- Sparkle. Both keys are read at runtime by Updater.swift; an unbundled dev
       run has no plist, finds no SUFeedURL, and starts no updater at all. -->
  <key>SUFeedURL</key><string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

# 3b. Embed Sparkle.framework.
#
#     SwiftPM LINKS the xcframework but never embeds it -- it builds no .app at
#     all -- so the copy has to happen here. The binary references
#     @rpath/Sparkle.framework/..., and Package.swift adds
#     @executable_path/../Frameworks to the executable's rpaths; without BOTH
#     halves the app builds, signs and notarizes clean and then dies at launch.
#
#     Take the macos-arm64_x86_64 slice: it is universal, so one copy serves the
#     universal build. `-print -quit` rather than `| head -1` -- head closes the
#     pipe early, and under `set -o pipefail` find's SIGPIPE would fail the script.
echo "==> embedding Sparkle.framework"
SPARKLE_SRC="$(find "$ROOT/.build/artifacts" -type d -name 'Sparkle.framework' -path '*macos-arm64_x86_64*' -print -quit)"
[[ -n "$SPARKLE_SRC" && -d "$SPARKLE_SRC" ]] || {
  echo "error: Sparkle.framework not found under .build/artifacts -- run 'swift build' first" >&2
  exit 1
}
mkdir -p "$APP/Contents/Frameworks"
# -R preserves the version symlinks a framework needs to stay valid to codesign.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
cp -R "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"

# The license notices travel with the BINARY, not merely with the repo. Most
# people who ever hold this app will have downloaded a disk image and never see the
# source, and all three obligations are addressed to them: GPLv3 s6 requires the
# License be conveyed with the object code, and both MIT notices require the
# permission text "in all copies". Into Resources rather than inside Sparkle's
# framework, because the framework is signed as a nested bundle below and adding
# files to it afterwards would break that seal.
echo "==> bundling license notices"
LICENSES="$APP/Contents/Resources/Licenses"
mkdir -p "$LICENSES"

# Hammerdeck's own terms.
cp "$ROOT/LICENSE" "$LICENSES/Hammerdeck-LICENSE-GPLv3.txt"

# Lua ships its notice only as the comment block closing lua.h, so extract it
# rather than keeping a hand-copied duplicate that a version bump would leave
# stale. Fails loudly if a future Lua moves it.
LUA_HEADER="$ROOT/Sources/CLua/include/lua.h"
awk '/^\* Copyright \(C\) .* Lua\.org/,/^\*+\/$/' "$LUA_HEADER" \
  | sed -e 's|^\* \{0,1\}||' -e 's|^\*\{3,\}/$||' > "$LICENSES/Lua-LICENSE.txt"
grep -q "Permission is hereby granted" "$LICENSES/Lua-LICENSE.txt" || {
  echo "error: could not extract Lua's MIT notice from $LUA_HEADER -- we ship Lua compiled in, so the notice must ship too" >&2
  exit 1
}

# Sparkle's, from the artifact the framework itself came out of.
SPARKLE_LICENSE="$(dirname "$(dirname "$(dirname "$SPARKLE_SRC")")")/LICENSE"
[[ -f "$SPARKLE_LICENSE" ]] || {
  echo "error: Sparkle LICENSE not found at $SPARKLE_LICENSE -- we ship the framework, so the notice must ship too" >&2
  exit 1
}
cp "$SPARKLE_LICENSE" "$LICENSES/Sparkle-LICENSE.txt"

# Drop Sparkle's XPC services. They exist to let a SANDBOXED app hand privileged
# work to a separate process; Sparkle's own sandboxing guide says to remove them
# when you are not sandboxed. This app is not: scripts/Hammerdeck.entitlements
# declares no com.apple.security.app-sandbox, and the Info.plist above sets no
# SUEnableInstallerLauncherService, so nothing can ever launch them.
# Keeping them would mean signing and notarizing two executables that cannot run.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
# ...and the top-level alias that pointed at them, or the bundle ships a dangling
# symlink: harmless at runtime, but it is a broken link inside a notarized artifact
# and it makes the framework look damaged to anyone inspecting it.
rm -f "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

# 4. Codesign. Tier B when a Developer ID Application identity exists, else Tier A.
#
#    `--deep` is deliberately gone: Apple deprecated it, and it was never the right
#    tool. Sparkle brings four nested Mach-Os that must each be signed BEFORE the
#    framework, and the framework before the app -- codesign seals each container
#    over the hashes of what it holds, so signing outside-in invalidates the outer
#    signature the moment an inner one changes. Order here is load-bearing.
#
#    These helpers DO ship entitlements -- `Autoupdate` carries
#    com.apple.application-identifier -- so they are re-signed with
#    --preserve-metadata=entitlements, which is what Sparkle's own manual-signing
#    recipe does. A plain --force --sign silently empties that dict, producing a
#    notarized updater helper stripped of an identity entitlement with nothing in
#    the pipeline noticing.
#    (An earlier version of this comment claimed the helpers shipped none. That
#    came from reading `codesign -d --entitlements -` output through a grep that
#    did not match its format -- no output was mistaken for no entitlements. The
#    invocation that actually prints them is `--entitlements :-`.)
#    Only the app itself gets our own entitlements FILE.
#    The XPC services are absent by the time we get here (removed above), so the
#    list is just the two helpers a non-sandboxed app actually launches.
SPARKLE_INNER=(
  "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
  "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
)
IDENTITY="${HAMMERDECK_RELEASE_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  # Match across ALL codesigning identities, not `-v` (valid only) -- same reason
  # app.sh does: a cert can sign fine while `-v` hides it. Read the whole listing
  # into a variable first; piping it into an early-exiting filter under
  # `pipefail` turns a SIGPIPE into a spurious build failure.
  ALL_IDS="$(security find-identity -p codesigning 2>/dev/null || true)"
  IDENTITY="$(printf '%s\n' "$ALL_IDS" \
    | awk -F'"' '/Developer ID Application:/ { if (!found) found = $2 } END { print found }')"
fi

if [[ -n "$IDENTITY" ]]; then
  TIER="B"
  echo "==> Tier B codesign: $IDENTITY"
  # --options runtime  hardened runtime; notarization refuses the bundle without it
  # --timestamp        secure timestamp; also a notarization requirement
  for inner in "${SPARKLE_INNER[@]}"; do
    echo "    inner: ${inner##*/}"
    codesign --force --options runtime --timestamp \
             --preserve-metadata=entitlements --sign "$IDENTITY" "$APP/$inner"
  done
  echo "    framework: Sparkle.framework"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" \
           "$APP/Contents/Frameworks/Sparkle.framework"
  # --entitlements only on the app: apple-events, or every AppleScript/JXA path
  # dies silently under the hardened runtime.
  echo "    app: $APP_NAME.app"
  codesign --force --options runtime --timestamp \
           --entitlements "$ENTITLEMENTS" \
           --sign "$IDENTITY" "$APP"
  # --deep on VERIFY (unlike on sign) is correct and wanted: it walks into the
  # framework and confirms every nested signature, which is exactly what
  # notarization will check.
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  TIER="A"
  echo "==> Tier A codesign (ad-hoc): no Developer ID Application identity found"
  echo "    The .app will run on THIS machine only. A browser download is"
  echo "    Gatekeeper-blocked and needs: xattr -dr com.apple.quarantine <app>"
  echo "    Set HAMMERDECK_RELEASE_IDENTITY, or create a Developer ID cert, for Tier B."
  # Same inside-out order: an ad-hoc bundle with an unsigned nested framework
  # fails to launch just as hard as a Developer ID one would.
  for inner in "${SPARKLE_INNER[@]}"; do
    codesign --force --preserve-metadata=entitlements --sign - "$APP/$inner"
  done
  codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force --sign - "$APP"
  codesign --verify --deep --strict "$APP"
fi

# 5. Wrap the bundle for notarytool, which takes an archive and not a bundle.
#    ditto preserves the .app structure, symlinks and signature. This archive is
#    a courier: the ticket staples onto the .app, not onto the thing submitted,
#    and the DMG built in step 6 is what ships.
echo "==> zipping $ZIP (notarization carrier)"
rm -f "$ZIP"
( cd "$DIST" && ditto -c -k --keepParent "$APP_NAME.app" "$(basename "$ZIP")" )

# `hdiutil create` fails intermittently on GitHub's macOS runners with
# "Resource busy" (exit 49168) when another process is still settling a mount.
# It is transient and a re-run succeeds, so a bounded retry here is the
# difference between a flaky release job and a reliable one.
make_dmg() {
  local attempt
  # Captured rather than `-quiet`, which closes stderr too: a DETERMINISTIC
  # failure (disk full, unreadable source, an unsupported filesystem) would
  # otherwise print five identical retry lines and nothing about the cause.
  for attempt in 1 2 3 4 5; do
    rm -f "$DMG"
    if hdiutil create "$DMG" -volname "$APP_NAME $VERSION" \
         -srcfolder "$DMG_ROOT" -fs APFS -format ULFO > "$DIST/hdiutil.log" 2>&1; then
      rm -f "$DIST/hdiutil.log"
      return 0
    fi
    echo "==> hdiutil create failed (attempt $attempt); retrying in $((attempt * 3))s"
    sleep $((attempt * 3))
  done
  echo "error: hdiutil create did not succeed after 5 attempts. Last output:" >&2
  cat "$DIST/hdiutil.log" >&2
  return 1
}

# 6. Notarize + staple (Tier B only).
if [[ "$TIER" == "B" && "${HAMMERDECK_SKIP_NOTARIZE:-0}" != "1" ]]; then
  # Auth: an explicit API key when the ASC_* vars are set (CI has no login
  # keychain to hold a stored profile), else the local keychain profile.
  if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
    KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
    if [[ ! -f "$KEY_PATH" ]]; then
      echo "error: ASC_KEY_ID is set but no key file at $KEY_PATH" >&2
      echo "       set ASC_KEY_PATH, or unset ASC_KEY_ID to use the keychain profile" >&2
      exit 1
    fi
    NOTARY_AUTH=(--key "$KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
    echo "==> notarytool submit (API key $ASC_KEY_ID) -- this waits on Apple"
  else
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
    echo "==> notarytool submit (keychain profile: $NOTARY_PROFILE) -- this waits on Apple"
  fi

  # No pipe: a pipeline reports the LAST command's status, so `| tee` here would
  # report success on a rejected submission and ship an unnotarized build.
  if ! xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait; then
    echo "error: notarization failed. For the per-issue detail, run:" >&2
    echo "  xcrun notarytool history ${NOTARY_AUTH[*]}" >&2
    echo "  xcrun notarytool log <submission-id> ${NOTARY_AUTH[*]}" >&2
    exit 1
  fi

  # Stapled onto the .app and not only onto the DMG below. Gatekeeper ingests a
  # mounted DMG's own ticket, so an ONLINE first launch works either way -- but a
  # copy dragged to /Applications and first opened with no network (a plane, a
  # captive portal) has nothing to check and is refused. One extra submission
  # buys the unconditional promise this file makes at the top.
  echo "==> stapling the ticket onto $APP"
  xcrun stapler staple "$APP"

  # The real acceptance test: what Gatekeeper itself says about the bundle.
  # `codesign --verify` only proves the signature is intact -- it says nothing
  # about whether Apple notarized it, which is the entire point of Tier B.
  echo "==> spctl assessment"
  spctl --assess --type execute --verbose=4 "$APP"
elif [[ "$TIER" == "B" ]]; then
  echo "==> SKIPPING notarization (HAMMERDECK_SKIP_NOTARIZE=1) -- signed but Gatekeeper-blocked"
fi

# 6b. The disk image, built from the app as it now stands (stapled, in Tier B).
#     The /Applications symlink is the whole user interface of a DMG: it is what
#     makes "drag it across" a gesture rather than an instruction. Sparkle
#     ignores symlinks when it extracts an update, so it costs nothing there.
DMG_ROOT="$DIST/dmg"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"

echo "==> building $DMG"
make_dmg
rm -rf "$DMG_ROOT"

if [[ "$TIER" == "B" ]]; then
  # Signed because stapling needs a signature to attach the ticket to -- NOT
  # because an unsigned image fails to mount, which it does not.
  echo "==> signing $DMG"
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"

  if [[ "${HAMMERDECK_SKIP_NOTARIZE:-0}" != "1" ]]; then
    echo "==> notarytool submit (disk image) -- this waits on Apple"
    if ! xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait; then
      echo "error: the disk image was not notarized. For the per-issue detail, run:" >&2
      echo "  xcrun notarytool history ${NOTARY_AUTH[*]}" >&2
      exit 1
    fi
    echo "==> stapling the ticket onto $DMG"
    xcrun stapler staple "$DMG"

    # `--type open --context context:primary-signature` is the assessment macOS
    # performs when a person double-clicks a downloaded image; `--type execute`
    # asks a question about an executable and does not apply to a container.
    echo "==> spctl assessment (disk image)"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
  fi
fi

# The carrier has done its job. Removed rather than left beside the DMG so no
# publish step, glob or human can pick up the wrong artifact.
rm -f "$ZIP"

# 7. The provenance record, written LAST -- after the image is built, signed and
#    stapled, so the digest below is the digest of what ships. Written for
#    every tier: a Tier A build is not publishable, and saying which commit an
#    unpublishable build came from is how a local trial stays attributable.
#
#    Artifact facts only. This file gets pasted into audit records in a public
#    repo, so no hostname, no user, no signing-identity name.
NOTARIZED="no"
if [[ "$TIER" == "B" && "${HAMMERDECK_SKIP_NOTARIZE:-0}" != "1" ]]; then NOTARIZED="yes"; fi
{
  echo "app:        $APP_NAME $VERSION"
  echo "bundle id:  $BUNDLE_ID"
  echo "commit:     $SRC_COMMIT"
  echo "tree:       $SRC_STATUS"
  echo "tier:       $TIER"
  echo "notarized:  $NOTARIZED"
  echo "feed:       $SPARKLE_FEED_URL"
  echo "min macOS:  $MIN_MACOS"
  echo "built:      $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "archive:    $(basename "$DMG")"
  echo "sha256:     $(shasum -a 256 "$DMG" | awk '{print $1}')"
  echo "bytes:      $(stat -f%z "$DMG")"
} > "$PROVENANCE"

echo "==> done (Tier $TIER)"
echo "    app: $APP"
echo "    dmg: $DMG"
echo "    provenance: $PROVENANCE"

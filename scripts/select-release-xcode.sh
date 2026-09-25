#!/usr/bin/env bash
#
# Select the Xcode a release is built with: the newest one on the runner image.
# release.yml runs it before packaging, and ci.yml's release-build job runs it
# before the same packaging, so the per-push check builds with exactly the
# toolchain the next tag will -- two copies of this choice could disagree, and
# a toolchain the release meets first is what that job exists to catch.
#
# Newest rather than a pinned series: pinning breaks silently the day the image
# stops shipping that series, and the real requirement is the compiler version,
# not the Xcode number -- so the Swift version is ASSERTED after selecting.
#
# No pipefail, deliberately: the `ls | sort | tail` below must not abort when the
# image has no /Applications/Xcode_*.app; the `-n` guard handles that case and
# the image default stays selected.
set -eu

latest="$(ls -d /Applications/Xcode_*.app 2>/dev/null | sort -V | tail -1)"
if [ -n "$latest" ]; then
  sudo xcode-select -s "$latest"
fi
echo "Xcode: $(xcode-select -p)"
swift --version

# Package.swift is swift-tools-version 6.0, so the toolchain must be Swift 6+.
ver="$(swift -version 2>&1)"
major="$(printf '%s\n' "$ver" | sed -n 's/.*Swift version \([0-9][0-9]*\).*/\1/p' | tail -1)"
if [ "${major:-0}" -lt 6 ]; then
  echo "error: Package.swift needs Swift 6+, toolchain reports major version '${major:-unknown}'" >&2
  exit 1
fi
echo "Swift major version $major -- ok"

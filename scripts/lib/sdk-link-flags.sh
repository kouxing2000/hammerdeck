# shellcheck shell=bash
# Sourced by every script that builds or tests Hammerdeck (app.sh, test-swift.sh,
# package.sh, CI). Sets SWIFT_SDK_LINK_FLAGS and defines hd_check_binary_sdk.
#
# Swift Build -- SwiftPM's default engine as of Xcode 27 -- links the binary with
# the DEPLOYMENT target recorded as its SDK version (LC_BUILD_VERSION `sdk 13.0`
# while MacOSX27.0.sdk is what it linked against). AppKit and SwiftUI choose
# behaviour by the SDK a program was linked against, so SDK-gated behaviour drops
# to its macOS 13 form: the visible case is a SwiftUI popover that opens at its
# default size and never shrinks to fit. Handing the linker both versions
# explicitly restores the real SDK; `--build-system native` does not, because
# SwiftPM routes a multi-architecture (universal release) build to Swift Build
# regardless.
#
# Both versions are DERIVED, never typed: the minimum from Package.swift, the SDK
# from xcrun. A copied number would silently mis-stamp the day either moves --
# and the minimum passed here overrides the one the compiler would record.
#
# Remove the flags once SwiftPM records the real SDK; keep hd_check_binary_sdk,
# which is what notices if it ever regresses.

HD_PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HD_MIN_MACOS="$(swift package --package-path "$HD_PACKAGE_ROOT" describe --type json \
  | jq -er '.platforms[] | select(.name == "macos") | .version')" || {
  echo "error: could not read the macOS minimum from Package.swift" >&2
  return 1 2>/dev/null || exit 1
}
HD_MACOS_SDK="$(xcrun --sdk macosx --show-sdk-version)" || {
  echo "error: xcrun could not report the macOS SDK version" >&2
  return 1 2>/dev/null || exit 1
}
SWIFT_SDK_LINK_FLAGS=(
  -Xlinker -platform_version -Xlinker macos
  -Xlinker "$HD_MIN_MACOS" -Xlinker "$HD_MACOS_SDK"
)

# "13" and "13.0" are the same version; vtool prints one, xcrun the other.
hd_norm_version() { local v="$1"; while [[ "$v" == *.0 ]]; do v="${v%.0}"; done; echo "$v"; }

# Fail (return 1, naming each bad slice) unless EVERY architecture slice of
# binary $1 records minos == HD_MIN_MACOS and sdk == HD_MACOS_SDK.
hd_check_binary_sdk() {
  local bin="$1" out line key val arch="" minos="" bad=0 slices=0
  out="$(vtool -show-build "$bin" 2>&1)" || {
    echo "error: vtool could not read $bin: $out" >&2; return 1
  }
  # Match the field NAME exactly: vtool's header line is the binary's path, which
  # may itself contain "sdk" or "minos".
  while IFS= read -r line; do
    read -r key val _ <<< "$line"
    case "$key" in
      minos) minos="$val" ;;
      sdk)
        slices=$((slices + 1))
        if [[ "$(hd_norm_version "$minos")" != "$(hd_norm_version "$HD_MIN_MACOS")" \
           || "$(hd_norm_version "$val")" != "$(hd_norm_version "$HD_MACOS_SDK")" ]]; then
          echo "error: $bin${arch:+ ($arch)} records minos $minos / sdk $val," \
               "expected minos $HD_MIN_MACOS / sdk $HD_MACOS_SDK" >&2
          bad=1
        fi ;;
      *) case "$line" in
           *"(architecture "*) arch="${line##*(architecture }"; arch="${arch%%)*}" ;;
         esac ;;
    esac
  done <<< "$out"
  if (( slices == 0 )); then
    echo "error: vtool reported no build version for $bin -- nothing was checked" >&2
    return 1
  fi
  return "$bad"
}

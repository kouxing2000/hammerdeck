#!/usr/bin/env bash
#
# Publish the download page, the update feed, and the release archive Sparkle
# hands to installed copies of the app.
#
# WHERE it publishes is not an argument: it is read off the `SUFeedURL` baked
# into the app inside `dist/<name>-<version>.dmg`. A release build goes to
# hammerdeck.peach-studio.com; a staging build (HAMMERDECK_FEED=staging at
# package time) goes to the staging site, which is where the update/recovery
# rehearsal runs. Nothing can send one to the other's feed.
#
# Run it on an archive scripts/package.sh already produced. On the RELEASE
# channel the ANNOTATED tag for the version must exist -- `git tag -a v0.1.0` --
# because the tag's message is where the notes come from (scripts/release-notes.py)
# and because the archive's recorded commit is checked against it. A staging
# rehearsal needs no tag: it is thrown away after the run, and burning a real
# version number on practice is worse than having no durable record of it.
#
#   scripts/publish-site.sh 0.1.0                publish to the BETA channel
#   scripts/publish-site.sh 0.1.0 --promote      move it to the default channel
#   scripts/publish-site.sh 0.1.0 --stage-only   sign + verify, deploy nothing
#
# Beta is the default and there is no argument for "straight to everyone": a
# version reaches the default channel only by being promoted after it has been
# on beta, which is the whole point of the ladder.
#
# `.github/workflows/publish.yml` calls this by hand, against the archive
# release.yml already built and attached to the GitHub Release -- so the bytes
# published are the bytes tested. It is standalone on purpose, so a release can
# still go out by hand when CI is down. Everything it deploys is generated into
# dist/site/ -- nothing in the tracked tree carries a version number that can go
# stale.
#
# Credentials, both optional locally:
#   SPARKLE_PRIVATE_KEY        the EdDSA key, as text. If unset, it is read from
#                              the file named by SPARKLE_KEY_FILE (the maintainer's
#                              local key store; there is no key in this repo).
#   FIREBASE_SERVICE_ACCOUNT   service-account JSON. Falls back to whatever
#                              `firebase login` left on this machine.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Hammerdeck"
FIREBASE_PROJECT="peach-studio"
# SITE_HOST and the Hosting site are NOT constants here: they are derived below
# from the feed URL baked into the app inside the archive. See "which feed".

DIST="$ROOT/dist"
STAGE="$DIST/site"
SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
# Where the EdDSA private key sits when it is not passed in the environment.
# DELIBERATELY has no default: a path here names someone's key store to every
# reader of a public repo, and this file is public. Only the maintainer holds the
# key for this feed -- a fork signs its own feed with its own key -- so both the
# env var and the file path are supplied by whoever runs this.
SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:-}"

# Read, never re-declared. package.sh is the single source for both: the bundle id
# it stamps into Info.plist, and the EdDSA public key it bakes in as SUPublicEDKey
# -- the one installed copies verify every update against. A second copy here
# could drift, and the drift would only surface as a feed the whole install base
# silently refuses.
PACKAGE_SH="$ROOT/scripts/package.sh"
# Pull a constant out of package.sh. Handles both shapes it uses: a bare literal
# (SPARKLE_PUBLIC_KEY) and an env-overridable default (BUNDLE_ID, written
# "${HAMMERDECK_BUNDLE_ID:-com.peach-studio.hammerdeck}") -- the second would
# otherwise come back as the literal text of the expression, which then fails
# every comparison it is used in and reads like a mismatched artifact.
read_package_const() {
  awk -F'"' -v k="^$1=" '$0 ~ k {print $2; exit}' "$PACKAGE_SH" \
    | sed -E 's/^\$\{[A-Za-z_][A-Za-z0-9_]*:-(.*)\}$/\1/'
}
# Read from package.sh like the key, rather than re-spelled here: a second copy
# of an identity string is a second thing to forget when it changes, and this
# script's whole job is to notice when two artifacts disagree.
BUNDLE_ID="${HAMMERDECK_BUNDLE_ID:-$(read_package_const BUNDLE_ID)}"
BUNDLE_ID="${BUNDLE_ID:-com.peach-studio.hammerdeck}"
SHIPPED_PUBKEY="$(read_package_const SPARKLE_PUBLIC_KEY)"
if [[ -z "$SHIPPED_PUBKEY" ]]; then
  echo "error: could not read SPARKLE_PUBLIC_KEY out of $PACKAGE_SH." >&2
  echo "       That constant is what installed copies verify against; refusing to" >&2
  echo "       publish a feed this script cannot check against it." >&2
  exit 1
fi
FEED_RELEASE="$(read_package_const SPARKLE_FEED_URL_RELEASE)"
FEED_STAGING="$(read_package_const SPARKLE_FEED_URL_STAGING)"
if [[ -z "$FEED_RELEASE" || -z "$FEED_STAGING" ]]; then
  echo "error: could not read both feed URLs out of $PACKAGE_SH." >&2
  echo "       Without them this script cannot tell a release build from a staging one," >&2
  echo "       which is the check that keeps a rehearsal off the production feed." >&2
  exit 1
fi

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: scripts/publish-site.sh <version>   (e.g. 0.1.0)" >&2
  exit 1
fi
VERSION="${VERSION#v}"
DMG="$DIST/$APP_NAME-$VERSION.dmg"

# Everything up to the deploy, so what is about to go live can be inspected
# while it is still only on disk. The signature verification below is the part
# worth seeing pass before an update feed reaches anyone.
#
# RELEASE_STAGE is the ladder, and it only moves one way. A publish is a
# BETA by default -- there is deliberately no way to spell "straight to
# everyone", because the point of the ladder is that no bytes reach the default
# channel that were not offered to beta subscribers first. `--promote` moves a
# version that is ALREADY on beta into the default channel, and refuses anything
# else (see the promote gate below).
STAGE_ONLY=0
RELEASE_STAGE="beta"
for arg in "${@:2}"; do
  case "$arg" in
    --stage-only) STAGE_ONLY=1 ;;
    --promote)    RELEASE_STAGE="production" ;;
    *)
      echo "error: unknown argument '$arg' (expected --promote and/or --stage-only)" >&2
      exit 1 ;;
  esac
done

echo "==> Publishing $APP_NAME $VERSION to the $RELEASE_STAGE channel"

# --- gates -------------------------------------------------------------------

# The ARCHIVE is the only input. `dist/Hammerdeck.app` used to be required here
# too, and is not: since REL-1 every gate asks the app inside the image, and the
# publish job downloads that image from the GitHub Release with no loose build
# anywhere beside it.
if [[ ! -f "$DMG" ]]; then
  echo "error: $DMG not found -- run scripts/package.sh $VERSION first" >&2
  exit 1
fi

# --- inspect the archive we are actually shipping ----------------------------

# Every gate below asks its question of the app INSIDE the image, not of
# dist/Hammerdeck.app sitting beside it. They are separate objects: package.sh
# produces both, but nothing downstream re-checks that they still agree, so
# validating the loose app certified a build no user would ever receive and a
# stale or hand-dropped image passed on its neighbour's reputation. The image is
# what the appcast points at, so the image is what has to answer.
VERIFY_DIR="$DIST/.verify.$$"
# ONE handler, registered once. bash keeps a single trap per signal, so a second
# `trap ... EXIT` further down REPLACES this rather than adding to it -- and the
# thing it would drop is the extracted app bundle, on the deploy path only, where
# a --stage-only rehearsal never reaches the second registration and so looks
# clean. Everything that needs cleaning is torn down here.
#
# `if`, never `[[ -n "$CREDS" ]] && rm ...`: under `set -e` a false test as the
# function's LAST statement trips errexit inside the function, which exits the
# script 1 on a completely successful run.
CREDS=""
MOUNT=""
cleanup() {
  # CREDENTIALS FIRST. Everything after this can fail -- `rm -rf` on a directory
  # that still holds a live mount does -- and under `set -e` a failure here ends
  # the function, so anything below a failing line never runs. The service
  # account JSON is the one thing that must not be left in /tmp.
  if [[ -n "$CREDS" ]]; then rm -f "$CREDS"; fi
  # -force because the image has been attached across signing, a download, a
  # compile and a deploy, which is ample time for Spotlight to hold it open.
  # A leaked attachment outlives the script; the mountpoint itself cannot
  # collide, since VERIFY_DIR is PID-suffixed.
  if [[ -n "$MOUNT" ]]; then hdiutil detach "$MOUNT" -force -quiet 2>/dev/null || true; fi
  rm -rf "$VERIFY_DIR" || true
}
trap cleanup EXIT
rm -rf "$VERIFY_DIR"
mkdir -p "$VERIFY_DIR"
# Mounted read-only and out of the way: -nobrowse keeps it off the Finder
# sidebar and -noautoopen stops a window appearing on the maintainer's desktop
# mid-publish. The gates below read the app in place; nothing is copied out.
MOUNT="$VERIFY_DIR/mnt"
mkdir -p "$MOUNT"
# Output captured, not silenced: `-quiet` closes stderr as well as stdout, so a
# failure here would otherwise be asserted as "not a readable disk image" with
# the actual cause -- a busy mountpoint, no free /dev/disk, an unsupported
# filesystem -- thrown away.
if ! hdiutil attach "$DMG" -mountpoint "$MOUNT" -readonly -nobrowse -noautoopen \
     > "$VERIFY_DIR/hdiutil.log" 2>&1; then
  echo "error: $DMG could not be mounted." >&2
  cat "$VERIFY_DIR/hdiutil.log" >&2
  # NOT cleared: attach can bind the image and still fail to mount it where we
  # asked, and the cleanup trap is the only thing that will detach it.
  exit 1
fi

# Exactly one app, at the top level. An image carrying two (or one nested
# somewhere unexpected) is not the shape package.sh produces, and guessing which
# one Sparkle would install is not a judgement this script should make.
#
# `-maxdepth 1`, not 2: the image holds an /Applications SYMLINK, and a deeper
# walk would follow it and count every app the maintainer has installed.
ARCHIVED_APP="$MOUNT/$APP_NAME.app"
APP_COUNT="$(find "$MOUNT" -maxdepth 1 -name '*.app' | wc -l | tr -d ' ')"
if [[ ! -d "$ARCHIVED_APP" || "$APP_COUNT" != "1" ]]; then
  echo "error: expected exactly one $APP_NAME.app in $DMG, found $APP_COUNT:" >&2
  find "$MOUNT" -maxdepth 1 -name '*.app' >&2
  exit 1
fi

ARCHIVED_PLIST="$ARCHIVED_APP/Contents/Info.plist"
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$ARCHIVED_PLIST" 2>/dev/null || true; }

# The version the archive CLAIMS must be the version the feed advertises -- this
# is the check that catches a rebuilt-but-not-repackaged release, where the feed
# offers 0.1.3 and hands the user 0.1.2 which then never updates again.
ARCHIVED_VERSION="$(plist_value CFBundleShortVersionString)"
ARCHIVED_BUILD="$(plist_value CFBundleVersion)"
ARCHIVED_ID="$(plist_value CFBundleIdentifier)"
if [[ "$ARCHIVED_VERSION" != "$VERSION" || "$ARCHIVED_BUILD" != "$VERSION" ]]; then
  echo "error: $DMG contains version $ARCHIVED_VERSION (build $ARCHIVED_BUILD), not $VERSION." >&2
  echo "       Re-run scripts/package.sh $VERSION; the archive is stale." >&2
  exit 1
fi
if [[ "$ARCHIVED_ID" != "$BUNDLE_ID" ]]; then
  echo "error: $DMG contains bundle id '$ARCHIVED_ID', expected '$BUNDLE_ID'." >&2
  exit 1
fi
echo "    archive contents: $APP_NAME $ARCHIVED_VERSION ($ARCHIVED_ID)"

# --- which feed this build polls, and therefore where it may be published -----
#
# Not a flag, and not a label stamped alongside: the destination is READ OFF the
# `SUFeedURL` baked into the app, which is the address installed copies will
# actually poll for the rest of their lives. A label could say "release" on a
# build wired to staging, and publishing that would point the whole install base
# at a test feed. The baked URL cannot lie about itself.
#
# Same shape as the SUPublicEDKey check below -- read from the artifact, compared
# against package.sh's constants, so this is a check rather than an assumption.
# An address matching neither constant is refused: it is either an archive older
# than the staging split or one built by something that is not package.sh.
ARCHIVED_FEED="$(plist_value SUFeedURL)"
case "$ARCHIVED_FEED" in
  "$FEED_RELEASE")
    CHANNEL="release"; FIREBASE_SITE="hammerdeck"
    SITE_HOST="https://hammerdeck.peach-studio.com" ;;
  "$FEED_STAGING")
    CHANNEL="staging"; FIREBASE_SITE="hammerdeck-staging"
    SITE_HOST="https://hammerdeck-staging.web.app" ;;
  *)
    echo "error: the app inside $DMG polls a feed this script does not publish:" >&2
    echo "       archive's SUFeedURL: ${ARCHIVED_FEED:-<none>}" >&2
    echo "       release: $FEED_RELEASE" >&2
    echo "       staging: $FEED_STAGING" >&2
    exit 1 ;;
esac
echo "    channel: $CHANNEL -> $SITE_HOST (hosting site '$FIREBASE_SITE')"

# The staging site is NOT on the ladder. Its whole job is to offer an update to
# an ordinary copy, and an ordinary copy has never opted into beta -- so a
# rehearsal published to the beta channel is invisible to the one thing it
# exists to test, and the drill reports "up to date" while proving nothing.
# Forced here rather than left to the caller: release.yml's staging dispatch
# passes no flag, and a rehearsal that silently tests nothing is the failure
# mode this whole file is written against.
if [[ "$CHANNEL" == "staging" ]]; then
  if [[ "$RELEASE_STAGE" == "production" ]]; then
    echo "error: --promote has no meaning on the staging site: there is no ladder" >&2
    echo "       there, only the single item a rehearsal copy must be offered." >&2
    exit 1
  fi
  RELEASE_STAGE="rehearsal"
  echo "    stage: rehearsal (staging is a rig, so its one item is unchannelled)"
fi

# Which SOURCE is in there. A version string is a label anyone can pass to
# package.sh; it says nothing about the code inside, so two archives claiming
# 0.1.2 can hold different builds and a test run against one proves nothing
# about the other. package.sh stamps HDSourceCommit, and the release tag is the
# only commit this feed is allowed to advertise -- asked of the app inside the
# image, like every other gate here.
ARCHIVED_COMMIT="$(plist_value HDSourceCommit)"
ARCHIVED_TREE="$(plist_value HDSourceStatus)"
if [[ -z "$ARCHIVED_COMMIT" || "$ARCHIVED_COMMIT" == "unknown" ]]; then
  echo "error: the app inside $DMG names no source commit (HDSourceCommit)." >&2
  echo "       It predates provenance stamping, or was built outside a git checkout." >&2
  echo "       Re-run scripts/package.sh $VERSION on the tagged commit." >&2
  exit 1
fi
if [[ "$ARCHIVED_TREE" != "clean" ]]; then
  echo "error: the app inside $DMG was built from a '$ARCHIVED_TREE' working tree." >&2
  echo "       Its contents are not in any commit, so nothing can be re-built or" >&2
  echo "       re-reviewed from the record. Commit, then re-package." >&2
  exit 1
fi
# The TAG match is a release-channel gate only. A staging build exists for one
# rehearsal and is thrown away after it, so requiring a tag would burn a real
# version number on every practice run -- and a tag is a durable public record of
# something that was never released. Provenance itself (a commit, a clean tree)
# still holds on both channels: a rehearsal whose build cannot be reproduced
# teaches nothing either.
if [[ "$CHANNEL" == "release" ]]; then
  TAG_COMMIT="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/v$VERSION^{commit}" 2>/dev/null || true)"
  if [[ -z "$TAG_COMMIT" ]]; then
    echo "error: no tag v$VERSION in this checkout, so there is nothing to match the" >&2
    echo "       archive's commit against (and no source for the release notes)." >&2
    exit 1
  fi
  if [[ "$ARCHIVED_COMMIT" != "$TAG_COMMIT" ]]; then
    echo "error: the app inside $DMG was built from a different commit than v$VERSION." >&2
    echo "       archive's HDSourceCommit:  $ARCHIVED_COMMIT" >&2
    echo "       v$VERSION points at:       $TAG_COMMIT" >&2
    echo "       Publishing would ship bytes no reviewed commit produced." >&2
    exit 1
  fi
  echo "    provenance: built from ${ARCHIVED_COMMIT:0:12} (clean tree), matching v$VERSION"
else
  echo "    provenance: built from ${ARCHIVED_COMMIT:0:12} (clean tree), untagged -- staging"
fi

# The hard one. An appcast entry is an INSTRUCTION to every installed copy to
# download and run this archive, so publishing an un-notarized build does not
# just ship something rough -- it pushes users an update macOS then refuses to
# open, and the app that would have offered them a working one has already been
# replaced. Asked of the artifact, never of whether a signing secret was set.
if ! xcrun stapler validate "$ARCHIVED_APP" > /dev/null 2>&1; then
  echo "error: the app inside $DMG carries no notarization ticket." >&2
  echo "       Refusing to publish an update feed for an unsigned build -- it would" >&2
  echo "       hand every installed copy an app that will not open." >&2
  exit 1
fi
if ! codesign --verify --deep --strict "$ARCHIVED_APP" > /dev/null 2>&1; then
  echo "error: the app inside $DMG fails codesign --verify --deep --strict." >&2
  exit 1
fi
echo "    notarization ticket: present; signature intact"

if [[ ! -x "$SIGN_UPDATE" ]]; then
  echo "error: sign_update not at $SIGN_UPDATE" >&2
  echo "       It ships inside the Sparkle SPM artifact bundle; 'swift package resolve'" >&2
  echo "       fetches it (measured: it lands at that exact path, no compile needed)." >&2
  exit 1
fi

KEY_SOURCE=""
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  KEY_SOURCE="env"
elif [[ -f "$SPARKLE_KEY_FILE" ]]; then
  SPARKLE_PRIVATE_KEY="$(cat "$SPARKLE_KEY_FILE")"
  KEY_SOURCE="key file"
else
  echo "error: no Sparkle signing key. Set SPARKLE_PRIVATE_KEY, or point SPARKLE_KEY_FILE at the key." >&2
  exit 1
fi
echo "    signing key: $KEY_SOURCE"

if [[ "$STAGE_ONLY" -eq 0 ]] && ! command -v firebase > /dev/null 2>&1; then
  echo "error: the firebase CLI is not on PATH (npm install -g firebase-tools)" >&2
  exit 1
fi

# Read the notes with the other gates, before signing: a bad tag should not cost
# a signature and a staged archive first. A non-zero exit must abort here --
# the whole point is that an empty <description> is an EMPTY dialog at the moment
# a user decides whether to trust an auto-update -- so the generator runs as a
# bare command substitution, where errexit fires on its own rather than on
# `pipefail` still being set 80 lines further up.
#
# A staging build has no tag to read them from, and inventing prose for a
# rehearsal would put a sentence in the update dialog that describes nothing. It
# says what it is instead -- the tester is the only reader it will ever have.
if [[ "$CHANNEL" == "release" ]]; then
  NOTES_HTML="$("$ROOT/scripts/release-notes.py" "$VERSION" --format html)"
  NOTES_SOURCE="the v$VERSION tag"
else
  NOTES_HTML="<p>Staging rehearsal build ${ARCHIVED_COMMIT:0:12}. Not a release.</p>"
  NOTES_SOURCE="the staging placeholder"
fi
echo "    release notes: $(printf '%s' "$NOTES_HTML" | wc -c | tr -d ' ') bytes from $NOTES_SOURCE"

# --- sign --------------------------------------------------------------------

# Sign the FINAL archive: package.sh builds the image from the app only after
# stapling, so this is the one carrying the ticket. Signing a pre-staple image
# would produce a signature that verifies against a file nobody will download.
ED_SIG="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - -p "$DMG")"
if [[ -z "$ED_SIG" ]]; then
  echo "error: sign_update produced no signature" >&2
  exit 1
fi
LENGTH="$(stat -f%z "$DMG")"
echo "    signature: ${ED_SIG:0:16}...  length: $LENGTH"

# The one archive value with no comparison behind it: version, bundle id and
# public key are each checked against something, so a soft read shows up there as
# a mismatch. An empty MIN_OS would sail through into
# <sparkle:minimumSystemVersion></sparkle:minimumSystemVersion> and render
# "macOS +" on the download page -- and the page's token guard only catches
# UNREPLACED tokens, never an empty replacement. So ask explicitly.
MIN_OS="$(plist_value LSMinimumSystemVersion)"
if [[ -z "$MIN_OS" ]]; then
  echo "error: the app inside $DMG declares no LSMinimumSystemVersion." >&2
  echo "       Publishing would advertise an update with no minimum OS." >&2
  exit 1
fi
PUB_DATE="$(date '+%a, %d %b %Y %H:%M:%S %z')"
DMG_NAME="$APP_NAME-$VERSION.dmg"

# --- stage -------------------------------------------------------------------

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$DMG" "$STAGE/$DMG_NAME"

# The live feed is INPUT, not just output: a beta publish has to carry the
# current production item forward, and a promote has to check this version
# against the beta the feed already advertises. Absent or unreachable comes back
# empty, which appcast.py reads as "no items" -- correct for a first publish,
# and refused by the promote gate, which cannot pass without a beta to match.
# Triaged by HTTP STATUS, not by curl's exit code: a 404 over HTTP/2 exits 56,
# the same family as a truncated transfer, so the codes cannot separate "there
# is no feed yet" from "I could not read the feed". Only a real 404 is allowed
# to mean the former. Getting this wrong is not cosmetic -- a DNS hiccup read as
# "first publish" drops the production item from a beta publish, and `firebase
# deploy` then deletes its archive from hosting too.
#
# no-cache because the production feed is served `max-age=300`, and a promote
# run minutes after its beta publish would otherwise read a pre-publish copy
# and refuse on state that is already stale.
LIVE_FEED="$VERIFY_DIR/live-appcast.xml"
FEED_HTTP="$(curl -sS --max-time 30 -H 'Cache-Control: no-cache' \
  -o "$LIVE_FEED" -w '%{http_code}' "$SITE_HOST/appcast.xml" || echo 000)"
case "$FEED_HTTP" in
  200) echo "    live feed: $(grep -c '<item>' "$LIVE_FEED" | tr -d ' ') item(s)" ;;
  404) : > "$LIVE_FEED"; echo "    live feed: none yet (404)" ;;
  *)
    echo "error: could not read the live feed at $SITE_HOST/appcast.xml (HTTP $FEED_HTTP)." >&2
    echo "       Refusing to rebuild the feed from a guess: treating this as an" >&2
    echo "       empty feed would drop the current release from both the appcast" >&2
    echo "       and hosting." >&2
    exit 1 ;;
esac

# `firebase deploy` replaces site content wholesale, so an item kept in the XML
# whose archive is not re-uploaded becomes an offer to download a 404. Only a
# beta publish carries one: a promote emits a single item, pointing at the
# archive staged just above.
#
# The download page follows the PRODUCTION item too, not this build: a beta is
# for a copy that opted in, and publishing one must not change what a stranger
# who visits the site downloads. On a promote, and on the very first publish
# when there is no production item yet, the page is this build.
PAGE_VERSION="$VERSION"
PAGE_ARCHIVE="$DMG_NAME"
PAGE_LENGTH="$LENGTH"
PAGE_MIN_OS="$MIN_OS"
PAGE_DATE=""
if [[ "$RELEASE_STAGE" == "beta" ]]; then
  CARRIED="$("$ROOT/scripts/appcast.py" carried --live "$LIVE_FEED")"
  if [[ -n "$CARRIED" ]]; then
    # Every field from the SAME build. Mixing them is how the page ends up
    # advertising the production version beside the beta's minimum OS, telling
    # a macOS 13 user not to download a build that runs fine for them.
    # Read as an array and COUNT, rather than into six named variables. Tab is
    # IFS whitespace whatever IFS is set to, so a run of them collapses and one
    # empty field shifts every later one along -- the page would then advertise
    # a byte count as its version number. The count is what catches that
    # (measured: an empty field yields 5, not 6); the split alone cannot.
    IFS=$'\t' read -r -d '' -a CARRIED_FIELDS < <(printf '%s\0' "$CARRIED") || true
    if [[ "${#CARRIED_FIELDS[@]}" -ne 6 ]]; then
      echo "error: the production item yielded ${#CARRIED_FIELDS[@]} fields, expected 6." >&2
      echo "       Refusing to guess which one is the version." >&2
      exit 1
    fi
    PAGE_VERSION="${CARRIED_FIELDS[0]}"
    PAGE_LENGTH="${CARRIED_FIELDS[1]}"
    CARRIED_URL="${CARRIED_FIELDS[2]}"
    PAGE_MIN_OS="${CARRIED_FIELDS[3]}"
    PAGE_DATE="${CARRIED_FIELDS[4]}"
    CARRIED_SIG="${CARRIED_FIELDS[5]}"
    PAGE_ARCHIVE="$(basename "$CARRIED_URL")"

    # The URL is carried into the new feed VERBATIM while the file is uploaded
    # to the site root, so the two must already agree. If they ever stop
    # agreeing the feed points at something nobody uploaded.
    if [[ "$CARRIED_URL" != "$SITE_HOST/$PAGE_ARCHIVE" ]]; then
      echo "error: the production enclosure is not hosted at this site's root:" >&2
      echo "       $CARRIED_URL" >&2
      exit 1
    fi

    echo "    carrying the production release forward: $PAGE_VERSION ($PAGE_ARCHIVE)"
    if ! curl -fsS --max-time 300 -o "$STAGE/$PAGE_ARCHIVE" "$CARRIED_URL"; then
      echo "error: could not re-download the current production archive at" >&2
      echo "       $CARRIED_URL" >&2
      echo "       Publishing without it would leave every non-beta copy pointed" >&2
      echo "       at a 404 for the release they are being offered." >&2
      exit 1
    fi

    # The new archive is checked four ways before it is published. This one is
    # what the ENTIRE non-beta install base downloads, and until now it was
    # trusted on the strength of a 200. Its length and signature are being
    # copied forward verbatim, so if hosting has drifted from what the feed
    # claims, every copy would fail Sparkle's check and be stuck.
    if [[ "$(stat -f%z "$STAGE/$PAGE_ARCHIVE")" != "$PAGE_LENGTH" ]]; then
      echo "error: the carried archive is $(stat -f%z "$STAGE/$PAGE_ARCHIVE") bytes," >&2
      echo "       but the live feed advertises $PAGE_LENGTH." >&2
      exit 1
    fi
    if ! printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --verify \
         "$STAGE/$PAGE_ARCHIVE" "$CARRIED_SIG" --ed-key-file - > /dev/null; then
      echo "error: the carried archive does not match the signature the live feed" >&2
      echo "       advertises for it. Hosting and the feed have drifted apart." >&2
      exit 1
    fi
    echo "    carried archive verifies against its published signature"
  fi
fi

NOTES_FILE="$VERIFY_DIR/notes.html"
printf '%s\n' "$NOTES_HTML" > "$NOTES_FILE"
"$ROOT/scripts/appcast.py" build \
  --stage "$RELEASE_STAGE" --version "$VERSION" --app-name "$APP_NAME" \
  --site-host "$SITE_HOST" --archive "$DMG_NAME" --length "$LENGTH" \
  --signature "$ED_SIG" --min-os "$MIN_OS" --notes-file "$NOTES_FILE" \
  --pub-date "$PUB_DATE" --live "$LIVE_FEED" > "$STAGE/appcast.xml"

VERSION="$PAGE_VERSION" DMG_NAME="$PAGE_ARCHIVE" LENGTH="$PAGE_LENGTH" \
MIN_OS="$PAGE_MIN_OS" PUB_DATE="$PAGE_DATE" \
python3 - "$ROOT/site/index.html" "$STAGE/index.html" <<'PY'
import os, sys, datetime
src, dst = sys.argv[1], sys.argv[2]
mb = int(os.environ["LENGTH"]) / (1024 * 1024)
subs = {
    "{{VERSION}}": os.environ["VERSION"],
    "{{DMG}}":     "/" + os.environ["DMG_NAME"],
    "{{SIZE}}":    f"{mb:.1f} MB",
    "{{DATE}}":    datetime.date.today().strftime("%B %-d, %Y"),
    "{{MINOS}}":   os.environ["MIN_OS"],
}
html = open(src, encoding="utf-8").read()
for token, value in subs.items():
    html = html.replace(token, value)
# A token left behind renders as literal braces on the live page, which looks
# broken to every visitor. Fail here instead, while it is still a build error.
leftover = [t for t in subs if t in html] + (["{{"] if "{{" in html else [])
if leftover:
    sys.exit(f"error: unrendered token(s) in index.html: {leftover}")
open(dst, "w", encoding="utf-8").write(html)
print(f"    page: {subs['{{VERSION}}']}, {subs['{{SIZE}}']}, macOS {subs['{{MINOS}}']}+")
PY

# --- verify before deploying -------------------------------------------------

# Round-trip the signature against the staged archive.
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --verify "$STAGE/$DMG_NAME" "$ED_SIG" --ed-key-file - > /dev/null
echo "    signature verifies against the staged archive"

# ...which on its own proves nothing about the CLIENT. sign_update derives its
# verification key from the private key it was just handed, so --verify is
# self-consistent by construction and passes for ANY well-formed key. Sparkle on
# the user's machine checks against SUPublicEDKey in the app's Info.plist. Sign
# with a different key and this script reports success while every installed copy
# refuses the update -- the feed is then broken for the whole install base until
# somebody notices by hand.
#
# So verify the way the client will: the archived app's OWN public key, over the
# exact bytes being published. Reading the key from the archive rather than from
# package.sh is what makes this a check and not an assumption -- then confirm the
# archive carries the key package.sh believes it stamped.
ARCHIVED_PUBKEY="$(plist_value SUPublicEDKey)"
if [[ -z "$ARCHIVED_PUBKEY" ]]; then
  echo "error: the app inside $DMG declares no SUPublicEDKey -- it can never accept an update." >&2
  exit 1
fi
if [[ "$ARCHIVED_PUBKEY" != "$SHIPPED_PUBKEY" ]]; then
  echo "error: the archived app trusts a different key than $PACKAGE_SH declares." >&2
  echo "       archive's SUPublicEDKey:  $ARCHIVED_PUBKEY" >&2
  echo "       package.sh's constant:    $SHIPPED_PUBKEY" >&2
  exit 1
fi

# Gated on a POSITIVE LANDMARK, not on the exit status. A missing toolchain, a
# compile error in the snippet, or a sandbox denial all exit non-zero too, and
# reporting any of those as "the signature is wrong" blocks a release with a
# confidently false cause pointing at the signing key. Only the word VERIFIED,
# which nothing but a completed check can print, is taken as a pass -- and the
# output stays visible so the real reason is on screen when it is something else.
VERIFY_OUT="$(ED_SIG="$ED_SIG" PUBKEY="$ARCHIVED_PUBKEY" DMG_PATH="$STAGE/$DMG_NAME" \
  swift -e '
import Foundation
import CryptoKit
let env = ProcessInfo.processInfo.environment
guard let keyData = Data(base64Encoded: env["PUBKEY"]!),
      let sigData = Data(base64Encoded: env["ED_SIG"]!),
      let payload = FileManager.default.contents(atPath: env["DMG_PATH"]!),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    print("MALFORMED")
    exit(2)
}
print(key.isValidSignature(sigData, for: payload) ? "VERIFIED" : "REJECTED")
' 2>&1 || true)"
case "$VERIFY_OUT" in
  *VERIFIED*)
    echo "    signature verifies against the archived app's SUPublicEDKey" ;;
  *REJECTED*)
    echo "error: the signature does NOT verify against the archived app's own public key." >&2
    echo "       The signing key's public half is not $ARCHIVED_PUBKEY." >&2
    echo "       Publishing would hand every installed copy an update it refuses." >&2
    exit 1 ;;
  *MALFORMED*)
    echo "error: the archived app's SUPublicEDKey or the signature is not valid base64/ed25519." >&2
    echo "       key: $ARCHIVED_PUBKEY" >&2
    exit 1 ;;
  *)
    echo "error: the signature check did not RUN -- so nothing here says the update is installable." >&2
    echo "       This is not a signature failure, it is a missing verdict. Output was:" >&2
    printf '%s\n' "$VERIFY_OUT" | sed 's/^/         /' >&2
    exit 1 ;;
esac

# --- deploy ------------------------------------------------------------------

if [[ "$STAGE_ONLY" -eq 1 ]]; then
  echo
  echo "==> --stage-only: nothing deployed. Staged in $STAGE:"
  ls -la "$STAGE"
  exit 0
fi

# CREDS and the EXIT trap that removes it are set up with the extraction cleanup
# at the top -- one handler for both, since a second `trap ... EXIT` would replace
# the first rather than join it.
if [[ -n "${FIREBASE_SERVICE_ACCOUNT:-}" ]]; then
  CREDS="$(mktemp)"
  printf '%s' "$FIREBASE_SERVICE_ACCOUNT" > "$CREDS"
  export GOOGLE_APPLICATION_CREDENTIALS="$CREDS"
  echo "    auth: service account"
else
  echo "    auth: local firebase login"
fi

# Named target, never a bare `--only hosting`: firebase.json now declares two
# sites, and the unqualified form deploys BOTH -- which would overwrite the live
# download page with a staging rehearsal's.
firebase deploy --only "hosting:$FIREBASE_SITE" --project "$FIREBASE_PROJECT" --non-interactive

echo
echo "==> Live:"
echo "    $SITE_HOST/"
echo "    $SITE_HOST/appcast.xml"

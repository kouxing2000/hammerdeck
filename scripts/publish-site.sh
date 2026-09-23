#!/usr/bin/env bash
#
# Publish the download page and the update feed installed copies poll.
#
# It does NOT publish the archive. Both sites serve HTML and XML only; every
# enclosure and every download button points at a GitHub Release asset of this
# repo. So the archive must already be UPLOADED to its Release before this runs
# -- the last gate before deploy fetches that URL anonymously and refuses if it
# does not serve the signed bytes. `publish.yml` has necessarily satisfied this
# (it downloads the asset it is publishing); by hand, `gh release upload` first.
#
# There is ONE site and ONE feed. A pre-release is not a second address, it is
# `<sparkle:channel>beta</sparkle:channel>` on this one, which a copy opts into
# with a toggle in Settings. The `SUFeedURL` baked into the archive is still
# read back and checked against package.sh's constant -- with nothing to choose
# between, that is a check that the archive came from package.sh at all.
#
# Run it on an archive scripts/package.sh already produced. The ANNOTATED tag
# for the version must exist -- `git tag -a v0.1.0` -- because the tag's message
# is where the notes come from (scripts/release-notes.py) and because the
# archive's recorded commit is checked against it.
#
#   scripts/publish-site.sh 0.1.0                publish to the BETA channel
#   scripts/publish-site.sh 0.1.0 --promote      move it to the default channel
#   scripts/publish-site.sh 0.1.0 --stage-only   sign + verify, deploy nothing
#   scripts/publish-site.sh --page-only          redeploy the PAGE only; the live
#                                                feed is re-served byte-for-byte
#   scripts/publish-site.sh --page-only --stage-only   ...stage it, deploy nothing
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
FIREBASE_SITE="hammerdeck"
SITE_HOST="https://hammerdeck.peach-studio.com"

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
if [[ -z "$FEED_RELEASE" ]]; then
  echo "error: could not read the feed URL out of $PACKAGE_SH." >&2
  echo "       It is what the archive's baked SUFeedURL is checked against, so" >&2
  echo "       without it nothing here can tell this build polls the feed being" >&2
  echo "       published." >&2
  exit 1
fi
# SITE_HOST is where this script READS the live feed and deploys the new one;
# package.sh's constant is where installed copies POLL. --page-only never sees an
# archive's SUFeedURL, so this is the only thing tying its SITE_HOST to them.
if [[ "$FEED_RELEASE" != "$SITE_HOST/appcast.xml" ]]; then
  echo "error: package.sh's feed ($FEED_RELEASE) is not $SITE_HOST/appcast.xml," >&2
  echo "       the feed this script reads and deploys." >&2
  exit 1
fi

# Where the ARCHIVES live. The sites serve the page and the feed; every enclosure
# points into this repo's Releases, which `firebase deploy` cannot reach and
# which costs no Hosting egress.
#
# Taken from the environment first so a fork is correct for free: GitHub Actions
# sets GITHUB_REPOSITORY, and a fork publishing its own feed would otherwise
# advertise this repo's binaries under its own signature.
GITHUB_REPO="${GITHUB_REPOSITORY:-kouxing2000/hammerdeck}"
GITHUB_DOWNLOAD_PREFIX="https://github.com/$GITHUB_REPO/releases/download"

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
#
# --page-only takes no version: it publishes no build, so the page follows the
# production item the live feed already advertises.
VERSION=""
STAGE_ONLY=0
PAGE_ONLY=0
RELEASE_STAGE="beta"
for arg in "$@"; do
  case "$arg" in
    --stage-only) STAGE_ONLY=1 ;;
    --promote)    RELEASE_STAGE="production" ;;
    --page-only)  PAGE_ONLY=1 ;;
    -*)
      echo "error: unknown argument '$arg' (expected --promote, --page-only and/or --stage-only)" >&2
      exit 1 ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "error: more than one version given ('$VERSION', '$arg')" >&2
        exit 1
      fi
      VERSION="${arg#v}" ;;
  esac
done
if [[ "$PAGE_ONLY" -eq 1 ]]; then
  if [[ -n "$VERSION" || "$RELEASE_STAGE" != "beta" ]]; then
    echo "error: --page-only publishes no build; it takes no version and no --promote." >&2
    exit 1
  fi
elif [[ -z "$VERSION" ]]; then
  echo "usage: scripts/publish-site.sh <version> [--promote] [--stage-only]   (e.g. 0.1.0)" >&2
  echo "       scripts/publish-site.sh --page-only [--stage-only]" >&2
  exit 1
fi
DMG="$DIST/$APP_NAME-$VERSION.dmg"

if [[ "$PAGE_ONLY" -eq 0 ]]; then
  echo "==> Publishing $APP_NAME $VERSION to the $RELEASE_STAGE channel"
fi

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

# --- shared by a release publish and --page-only ------------------------------

# GET the live feed into $1, echoing the HTTP status. The CALLER triages the
# status: a release publish treats 404 as "first publish"; --page-only refuses
# anything but 200, since it has no feed of its own to put in its place.
fetch_live_feed() {
  curl -sS --max-time 30 -H 'Cache-Control: no-cache' \
    -o "$1" -w '%{http_code}' "$SITE_HOST/appcast.xml" || echo 000
}

# Download archive URL $1, ANONYMOUSLY, into $2 and check it is $3 bytes -- what
# a client that follows the feed or the page's button actually receives. $4
# labels the errors. Returns 1 on a failed fetch or a length mismatch; the file
# is left at $2 for the caller to check further (or remove).
#
# Anonymous is the point. `gh release download` sends a token and succeeds
# against a draft release and against a private repo, so a tokenized check would
# pass while every user's Sparkle got a 404. `-q` and `--no-netrc` stop a
# ~/.curlrc or a netrc entry from quietly supplying the credentials this check
# exists to do without.
fetch_archive() {
  local url="$1" dest="$2" expect_len="$3" label="$4"
  local code got
  code="$(curl -q -sSL --no-netrc --max-time 300 -o "$dest" -w '%{http_code}' "$url" || echo 000)"
  if [[ "$code" != "200" ]]; then
    echo "error: the $label archive is not anonymously downloadable (HTTP $code):" >&2
    echo "       $url" >&2
    echo "       Installed copies fetch this with no credentials. A draft release," >&2
    echo "       a missing asset or a private repo all look like this, and" >&2
    echo "       publishing anyway offers everyone a download that fails." >&2
    return 1
  fi
  got="$(stat -f%z "$dest")"
  if [[ "$got" != "$expect_len" ]]; then
    echo "error: the $label archive is $got bytes; the feed advertises $expect_len." >&2
    echo "       $url" >&2
    return 1
  fi
}

# Read the PRODUCTION item out of the live feed at $1 into PAGE_VERSION,
# PAGE_LENGTH, PAGE_MIN_OS, PAGE_DATE, PAGE_ARCHIVE, CARRIED_URL and
# CARRIED_SIG. Returns 1 when the feed has no production item. Exits on a
# malformed item or an enclosure outside this repo's Releases.
load_production_item() {
  local carried
  # Checked by hand: callers test this function with `if`, and bash suspends
  # errexit for the whole body there -- so a crashing appcast.py would read as
  # "no production item", and a beta publish would drop it from the feed.
  if ! carried="$("$ROOT/scripts/appcast.py" carried --live "$1")"; then
    echo "error: appcast.py could not read the production item out of $1." >&2
    exit 1
  fi
  [[ -n "$carried" ]] || return 1
  # Every field from the SAME build. Mixing them is how the page ends up
  # advertising the production version beside the beta's minimum OS, telling
  # a macOS 13 user not to download a build that runs fine for them.
  # Read as an array and COUNT, rather than into six named variables. Tab is
  # IFS whitespace whatever IFS is set to, so a run of them collapses and one
  # empty field shifts every later one along -- the page would then advertise
  # a byte count as its version number. The count is what catches that
  # (measured: an empty field yields 5, not 6); the split alone cannot.
  local -a fields
  IFS=$'\t' read -r -d '' -a fields < <(printf '%s\0' "$carried") || true
  if [[ "${#fields[@]}" -ne 6 ]]; then
    echo "error: the production item yielded ${#fields[@]} fields, expected 6." >&2
    echo "       Refusing to guess which one is the version." >&2
    exit 1
  fi
  PAGE_VERSION="${fields[0]}"
  PAGE_LENGTH="${fields[1]}"
  CARRIED_URL="${fields[2]}"
  PAGE_MIN_OS="${fields[3]}"
  PAGE_DATE="${fields[4]}"
  CARRIED_SIG="${fields[5]}"
  PAGE_ARCHIVE="$(basename "$CARRIED_URL")"

  # A feed published while the archives were hosted on the site carries a site
  # URL. Retarget it at the Release for that version -- same filename, same
  # bytes, and the caller's download check is what proves the second half
  # rather than assuming it. Once a publish has run, the live feed already
  # holds the Release URL and this branch does nothing.
  if [[ "$CARRIED_URL" == "$SITE_HOST/"* ]]; then
    CARRIED_URL="$GITHUB_DOWNLOAD_PREFIX/v$PAGE_VERSION/$PAGE_ARCHIVE"
    echo "    retargeting the production archive at its Release: $CARRIED_URL"
  fi

  # Anchored PREFIX, never a substring: this value comes out of a document
  # fetched over the network, and `https://evil.example/?x=github.com/...`
  # contains every substring a looser test would look for.
  case "$CARRIED_URL" in
    "$GITHUB_DOWNLOAD_PREFIX"/*) ;;
    *)
      echo "error: the production enclosure is not a Release asset of $GITHUB_REPO:" >&2
      echo "       $CARRIED_URL" >&2
      echo "       Refusing to carry a feed entry pointing somewhere this repo" >&2
      echo "       does not control." >&2
      exit 1 ;;
  esac
  return 0
}

# Render site/index.html into $STAGE from PAGE_VERSION / PAGE_URL / PAGE_LENGTH
# / PAGE_MIN_OS / PAGE_DATE, and stage the page's images beside it.
render_page() {
VERSION="$PAGE_VERSION" DMG_URL="$PAGE_URL" LENGTH="$PAGE_LENGTH" \
MIN_OS="$PAGE_MIN_OS" PUB_DATE="$PAGE_DATE" \
"$ROOT/scripts/render-page.py" "$ROOT/site/index.html" "$STAGE/index.html"
# The page's images. site/assets/ is also where README.md points, so the page
# and the README show the same files. `firebase deploy` replaces the whole site,
# so anything not staged here is deleted from it.
cp -R "$ROOT/site/assets" "$STAGE/assets"
echo "    page assets: $(find "$STAGE/assets" -type f | wc -l | tr -d ' ') file(s)"
}

# Refuse while a publish.yml run is queued or in flight. --page-only re-serves
# the live feed; a release publish that lands before this deploy finalizes would
# be rolled back by it, and the end state (live feed == staged feed) looks
# exactly like success -- so the only guard is not to overlap at all.
# Unknown counts as busy: without gh there is no way to tell.
refuse_if_publish_running() {
  local status n
  for status in in_progress queued; do
    if ! n="$(gh run list --repo "$GITHUB_REPO" --workflow publish.yml \
                --status "$status" --json databaseId --jq length 2>&1)"; then
      echo "error: could not ask GitHub whether a publish is running:" >&2
      echo "       $n" >&2
      exit 1
    fi
    if [[ "$n" != "0" ]]; then
      echo "error: $n publish.yml run(s) $status on $GITHUB_REPO. Deploying the page" >&2
      echo "       now could roll back the feed that run publishes. Re-run after it." >&2
      exit 1
    fi
  done
  echo "    no publish.yml run queued or in progress"
}

# Checked with the other gates, long before the deploy: a missing CLI should
# not cost a signed, verified stage first. A --stage-only run never deploys.
require_firebase() {
  if [[ "$STAGE_ONLY" -eq 0 ]] && ! command -v firebase > /dev/null 2>&1; then
    echo "error: the firebase CLI is not on PATH (npm install -g firebase-tools)" >&2
    exit 1
  fi
}

# Deploy $STAGE -- the WHOLE site. `firebase deploy` replaces every file, so
# whatever is not staged is deleted from the live site: the feed must be in
# $STAGE even when this run did not change it.
deploy_site() {
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
  # download page if a second site is ever added back.
  firebase deploy --only "hosting:$FIREBASE_SITE" --project "$FIREBASE_PROJECT" --non-interactive

  echo
  echo "==> Live:"
  echo "    $SITE_HOST/"
  echo "    $SITE_HOST/appcast.xml"
}

# --- --page-only -------------------------------------------------------------
#
# Redeploys the download page WITHOUT publishing anything to the update feed.
# The feed cannot simply be left out: `firebase deploy` replaces the whole site,
# so a stage without appcast.xml deletes the feed every installed copy polls.
# It is therefore re-served BYTE-FOR-BYTE from the live site, and compared
# against the live one again immediately before deploying: a release published
# in between would otherwise be silently rolled back by this run.
#
# Needs no archive, no tag and no signing key -- it signs nothing.
if [[ "$PAGE_ONLY" -eq 1 ]]; then
  echo "==> Publishing the $APP_NAME download page only (the feed is not changed)"
  require_firebase

  # The release path renders a tagged, CI-gated checkout; this runs from a
  # working tree. Publish only what a commit holds -- otherwise the live page
  # shows content no commit has, and the next release silently reverts it.
  if ! "$ROOT/scripts/gen-readme-features.py" --check > /dev/null; then
    echo "error: site/index.html's generated blocks are stale -- run scripts/gen-readme-features.py." >&2
    exit 1
  fi
  if ! git -C "$ROOT" diff --quiet HEAD -- site/ \
     || [[ -n "$(git -C "$ROOT" ls-files --others --exclude-standard -- site/)" ]]; then
    echo "error: site/ differs from HEAD (uncommitted or untracked files):" >&2
    git -C "$ROOT" status --short -- site/ >&2
    echo "       Commit it first: the page publishes only what a commit holds." >&2
    exit 1
  fi
  echo "    site/: matches HEAD $(git -C "$ROOT" rev-parse --short HEAD), generated blocks in sync"

  LIVE_FEED="$VERIFY_DIR/live-appcast.xml"
  FEED_HTTP="$(fetch_live_feed "$LIVE_FEED")"
  if [[ "$FEED_HTTP" != "200" ]]; then
    echo "error: could not read the live feed at $SITE_HOST/appcast.xml (HTTP $FEED_HTTP)." >&2
    echo "       --page-only re-serves the live feed unchanged, so it cannot run" >&2
    echo "       without one: deploying anyway would delete the feed from the site." >&2
    exit 1
  fi
  if ! grep -q '<rss' "$LIVE_FEED"; then
    echo "error: $SITE_HOST/appcast.xml answered 200 but is not an RSS feed." >&2
    exit 1
  fi
  echo "    live feed: $(grep -c '<item>' "$LIVE_FEED" | tr -d ' ') item(s), $(stat -f%z "$LIVE_FEED") bytes"

  if ! load_production_item "$LIVE_FEED"; then
    echo "error: the live feed has no production item, so there is no build for" >&2
    echo "       the page to offer. Promote one first (publish-site.sh <v> --promote)." >&2
    exit 1
  fi
  PAGE_URL="$CARRIED_URL"
  echo "    page follows production: $PAGE_VERSION ($PAGE_ARCHIVE)"

  # The download button must work. LENGTH rather than the signature, because
  # this mode holds no key -- and it publishes no signature either, so the
  # feed's signature is not this run's claim to check.
  DL_DEST="$VERIFY_DIR/page-archive"
  fetch_archive "$PAGE_URL" "$DL_DEST" "$PAGE_LENGTH" "page's" || exit 1
  rm -f "$DL_DEST"
  echo "    download: 200 anonymous, $PAGE_LENGTH bytes (matches the feed)"

  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  cp "$LIVE_FEED" "$STAGE/appcast.xml"
  if ! cmp -s "$LIVE_FEED" "$STAGE/appcast.xml"; then
    echo "error: the staged appcast.xml differs from the live feed it was copied from." >&2
    exit 1
  fi
  render_page

  # Last gate: is the staged feed STILL the live one? Asked right before the
  # deploy, not only at fetch time, because the gap between the two is where a
  # concurrent release publish would land -- and this deploy would revert it.
  refuse_if_publish_running
  RECHECK="$VERIFY_DIR/live-appcast.recheck.xml"
  RECHECK_HTTP="$(fetch_live_feed "$RECHECK")"
  if [[ "$RECHECK_HTTP" != "200" ]]; then
    echo "error: could not re-read the live feed before deploying (HTTP $RECHECK_HTTP)." >&2
    exit 1
  fi
  if ! cmp -s "$RECHECK" "$STAGE/appcast.xml"; then
    echo "error: the live feed changed while this ran -- the staged appcast.xml no" >&2
    echo "       longer matches it. Deploying would roll back whatever was published." >&2
    echo "       Re-run once the other publish has finished." >&2
    exit 1
  fi
  echo "    staged appcast.xml is byte-identical to the live feed ($(stat -f%z "$STAGE/appcast.xml") bytes)"

  if [[ "$STAGE_ONLY" -eq 1 ]]; then
    echo
    echo "==> --stage-only: nothing deployed. Staged in $STAGE:"
    ls -la "$STAGE"
    exit 0
  fi
  deploy_site
  exit 0
fi

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

# --- the feed this build polls, which must be the one being published --------
#
# There is one feed, so this is no longer a choice -- but it is still a CHECK,
# and a load-bearing one. The address is READ OFF the `SUFeedURL` baked into the
# app, which is what installed copies will poll for the rest of their lives, and
# compared against package.sh's constant. An archive that polls somewhere else
# was built by something that is not package.sh, or predates this constant; in
# either case publishing it would advertise an update to copies that are
# listening to a different address entirely.
#
# Same shape as the SUPublicEDKey check below: read from the artifact, compared
# against the source of truth, so it is a check rather than an assumption.
ARCHIVED_FEED="$(plist_value SUFeedURL)"
if [[ "$ARCHIVED_FEED" != "$FEED_RELEASE" ]]; then
  echo "error: the app inside $DMG polls a feed this script does not publish:" >&2
  echo "       archive's SUFeedURL: ${ARCHIVED_FEED:-<none>}" >&2
  echo "       expected:            $FEED_RELEASE" >&2
  exit 1
fi
echo "    feed: $SITE_HOST/appcast.xml (hosting site '$FIREBASE_SITE')"

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
# Everything published is a release, so the tag match is unconditional. It is
# the gate that stops a rebuild of the same version number reaching the feed:
# two archives can both call themselves 0.1.2, and a test run against one proves
# nothing about the other.
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

require_firebase

# Read the notes with the other gates, before signing: a bad tag should not cost
# a signature and a staged archive first. A non-zero exit must abort here --
# the whole point is that an empty <description> is an EMPTY dialog at the moment
# a user decides whether to trust an auto-update -- so the generator runs as a
# bare command substitution, where errexit fires on its own rather than on
# `pipefail` still being set 80 lines further up.
NOTES_HTML="$("$ROOT/scripts/release-notes.py" "$VERSION" --format html)"
echo "    release notes: $(printf '%s' "$NOTES_HTML" | wc -c | tr -d ' ') bytes from the v$VERSION tag"

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
# --- what a client will actually get -----------------------------------------

# Prove an enclosure URL serves, ANONYMOUSLY, the exact bytes the feed signs for:
# fetch_archive's download and length, then the signature.
#
# It downloads instead of reading Content-Length, and that is where its value
# is: re-running a release tag rebuilds and `--clobber`s the asset, and a
# rebuild of the same commit differs only by notarization timestamps inside an
# image whose size is quantized -- so the length is very likely UNCHANGED while
# the signature every installed copy checks no longer matches. Only verifying
# the signature sees that.
verify_published_archive() {
  local url="$1" expect_len="$2" expect_sig="$3" label="$4"
  local dest="$VERIFY_DIR/published-$(basename "$url")"
  fetch_archive "$url" "$dest" "$expect_len" "$label" || return 1
  if ! printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --verify \
       "$dest" "$expect_sig" --ed-key-file - > /dev/null; then
    echo "error: the $label archive does not match the signature published for it." >&2
    echo "       The bytes on the Release changed after they were signed, so every" >&2
    echo "       copy offered this update would download it and refuse to install." >&2
    echo "       $url" >&2
    return 1
  fi
  rm -f "$dest"
  echo "    $label archive: 200 anonymous, $expect_len bytes, signature verifies"
}

PUB_DATE="$(date '+%a, %d %b %Y %H:%M:%S %z')"

# The name the archive carries ON THE RELEASE, which is also the last path
# component every user sees in their Downloads folder.
DMG_NAME="$APP_NAME-$VERSION.dmg"
ARCHIVE_URL="$GITHUB_DOWNLOAD_PREFIX/v$VERSION/$DMG_NAME"
echo "    archive url: $ARCHIVE_URL"

# --- stage -------------------------------------------------------------------
#
# Only the page and the feed are staged. The archive is NOT copied here: it is
# already on the Release this URL names, and deploying a second copy would put
# the two on different hosts with nothing keeping them identical.

rm -rf "$STAGE"
mkdir -p "$STAGE"

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
FEED_HTTP="$(fetch_live_feed "$LIVE_FEED")"
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

# Only a beta publish carries an item forward: a promote emits a single item,
# pointing at the archive named above. The carried entry's archive needs no
# re-upload -- it is on a GitHub Release, which this deploy does not touch --
# but it is still re-verified below, because "nobody here touched it" is not
# the same as "nothing touched it".
#
# The download page follows the PRODUCTION item too, not this build: a beta is
# for a copy that opted in, and publishing one must not change what a stranger
# who visits the site downloads. On a promote, and on the very first publish
# when there is no production item yet, the page is this build.
PAGE_VERSION="$VERSION"
PAGE_ARCHIVE="$DMG_NAME"
PAGE_URL="$ARCHIVE_URL"
PAGE_LENGTH="$LENGTH"
PAGE_MIN_OS="$MIN_OS"
PAGE_DATE="$PUB_DATE"
if [[ "$RELEASE_STAGE" == "beta" ]]; then
  if load_production_item "$LIVE_FEED"; then
    echo "    carrying the production release forward: $PAGE_VERSION ($PAGE_ARCHIVE)"
    # What the ENTIRE non-beta install base downloads. Its length and signature
    # are copied into the new feed verbatim, so if the asset has drifted from
    # what the feed claims, every one of those copies fails Sparkle's check and
    # is stuck with no way back.
    verify_published_archive "$CARRIED_URL" "$PAGE_LENGTH" "$CARRIED_SIG" "carried" || exit 1
    PAGE_URL="$CARRIED_URL"
  fi
fi

NOTES_FILE="$VERIFY_DIR/notes.html"
printf '%s\n' "$NOTES_HTML" > "$NOTES_FILE"
"$ROOT/scripts/appcast.py" build \
  --stage "$RELEASE_STAGE" --version "$VERSION" --app-name "$APP_NAME" \
  --site-host "$SITE_HOST" --archive-url "$ARCHIVE_URL" --length "$LENGTH" \
  --carried-url "${CARRIED_URL:-}" \
  --signature "$ED_SIG" --min-os "$MIN_OS" --notes-file "$NOTES_FILE" \
  --pub-date "$PUB_DATE" --live "$LIVE_FEED" > "$STAGE/appcast.xml"

render_page

# --- verify before deploying -------------------------------------------------

# Round-trip the signature against the local archive -- the same file that was
# uploaded to the Release, and the one the anonymous check below re-fetches.
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --verify "$DMG" "$ED_SIG" --ed-key-file - > /dev/null
echo "    signature verifies against the local archive"

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
VERIFY_OUT="$(ED_SIG="$ED_SIG" PUBKEY="$ARCHIVED_PUBKEY" DMG_PATH="$DMG" \
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
  echo "    (the enclosure is NOT checked here: --stage-only runs before a"
  echo "     Release exists, which is most of why anyone uses it)"
  exit 0
fi

# The last gate, and the only one that asks the question a user's Sparkle asks:
# does this URL, with no credentials, hand back the bytes this feed signs for.
# Everything above this line verifies a file on THIS disk. Nothing above it
# proves the URL about to be published resolves at all -- and it is pure string
# construction, so a wrong tag or a never-uploaded asset looks identical.
verify_published_archive "$ARCHIVE_URL" "$LENGTH" "$ED_SIG" "published" || {
  echo "       Upload it to the Release first:" >&2
  echo "         gh release upload v$VERSION \"$DMG\" --clobber" >&2
  exit 1
}

deploy_site

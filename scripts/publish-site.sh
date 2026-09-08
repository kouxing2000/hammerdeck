#!/usr/bin/env bash
#
# Publish hammerdeck.peach-studio.com: the download page, the update feed, and
# the release archive Sparkle hands to installed copies of the app.
#
# Run it AFTER scripts/package.sh has produced a Tier B build, and after the
# ANNOTATED tag for this version exists -- `git tag -a v0.1.0` -- because the
# tag's message is where the release notes come from (scripts/release-notes.py).
# An untagged version cannot be published, which is the intent: the feed's notes
# have no other source, and a release with no tag has no durable record either.
#
#   scripts/publish-site.sh 0.1.0
#   scripts/publish-site.sh 0.1.0 --stage-only   build + sign + verify, deploy nothing
#
# CI calls this; it is standalone on purpose, so a release can still go out by
# hand when CI is down. Everything it deploys is generated into dist/site/ --
# nothing in the tracked tree carries a version number that can go stale.
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
SITE_HOST="https://hammerdeck.peach-studio.com"
FIREBASE_PROJECT="peach-studio"

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
STAGE="$DIST/site"
SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
# Where the EdDSA private key sits when it is not passed in the environment.
# DELIBERATELY has no default: a path here names someone's key store to every
# reader of a public repo, and this file is public. Only the maintainer holds the
# key for this feed -- a fork signs its own feed with its own key -- so both the
# env var and the file path are supplied by whoever runs this.
SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:-}"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: scripts/publish-site.sh <version>   (e.g. 0.1.0)" >&2
  exit 1
fi
VERSION="${VERSION#v}"
ZIP="$DIST/$APP_NAME-$VERSION.zip"

# Everything up to the deploy, so what is about to go live can be inspected
# while it is still only on disk. The signature verification below is the part
# worth seeing pass before an update feed reaches anyone.
STAGE_ONLY=0
if [[ "${2:-}" == "--stage-only" ]]; then
  STAGE_ONLY=1
elif [[ -n "${2:-}" ]]; then
  echo "error: unknown argument '${2}' (expected --stage-only or nothing)" >&2
  exit 1
fi

echo "==> Publishing $APP_NAME $VERSION to $SITE_HOST"

# --- gates -------------------------------------------------------------------

if [[ ! -f "$ZIP" ]]; then
  echo "error: $ZIP not found -- run scripts/package.sh $VERSION first" >&2
  exit 1
fi
if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found -- run scripts/package.sh $VERSION first" >&2
  exit 1
fi

# The hard one. An appcast entry is an INSTRUCTION to every installed copy to
# download and run this archive, so publishing an un-notarized build does not
# just ship something rough -- it pushes users an update macOS then refuses to
# open, and the app that would have offered them a working one has already been
# replaced. Asked of the artifact, never of whether a signing secret was set.
if ! xcrun stapler validate "$APP" > /dev/null 2>&1; then
  echo "error: $APP carries no notarization ticket." >&2
  echo "       Refusing to publish an update feed for an unsigned build -- it would" >&2
  echo "       hand every installed copy an app that will not open." >&2
  exit 1
fi
echo "    notarization ticket: present"

if [[ ! -x "$SIGN_UPDATE" ]]; then
  echo "error: sign_update not at $SIGN_UPDATE" >&2
  echo "       It ships inside the Sparkle SPM artifact bundle; run 'swift build' first." >&2
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
NOTES_HTML="$("$ROOT/scripts/release-notes.py" "$VERSION" --format html)"
# Indented here rather than in the generator: the indentation belongs to the XML
# heredoc below, not to the HTML.
NOTES_HTML="$(printf '%s\n' "$NOTES_HTML" | sed 's/^/                /')"
echo "    release notes: $(printf '%s' "$NOTES_HTML" | wc -c | tr -d ' ') bytes from the v$VERSION tag"

# --- sign --------------------------------------------------------------------

# Sign the FINAL archive: for a Tier B build package.sh re-zips after stapling,
# so this is the one carrying the ticket. Signing the pre-staple zip would
# produce a signature that verifies against a file nobody will ever download.
ED_SIG="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - -p "$ZIP")"
if [[ -z "$ED_SIG" ]]; then
  echo "error: sign_update produced no signature" >&2
  exit 1
fi
LENGTH="$(stat -f%z "$ZIP")"
echo "    signature: ${ED_SIG:0:16}...  length: $LENGTH"

MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
PUB_DATE="$(date '+%a, %d %b %Y %H:%M:%S %z')"
ZIP_NAME="$APP_NAME-$VERSION.zip"

# --- stage -------------------------------------------------------------------

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$ZIP" "$STAGE/$ZIP_NAME"

# The feed carries the NEWEST release only, and that is deliberate. `firebase
# deploy` replaces site content wholesale, so older archives stop being hosted
# whatever the feed says -- an entry for one would be an offer to download a
# 404. Sparkle needs only the newest item to offer an update.
cat > "$STAGE/appcast.xml" <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>$APP_NAME</title>
        <link>$SITE_HOST/appcast.xml</link>
        <description>Updates for $APP_NAME</description>
        <language>en</language>
        <item>
            <title>$VERSION</title>
            <description><![CDATA[
$NOTES_HTML
            ]]></description>
            <pubDate>$PUB_DATE</pubDate>
            <link>$SITE_HOST/</link>
            <sparkle:version>$VERSION</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
            <enclosure url="$SITE_HOST/$ZIP_NAME" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$ED_SIG"/>
        </item>
    </channel>
</rss>
XML

VERSION="$VERSION" ZIP_NAME="$ZIP_NAME" LENGTH="$LENGTH" MIN_OS="$MIN_OS" \
python3 - "$ROOT/site/index.html" "$STAGE/index.html" <<'PY'
import os, sys, datetime
src, dst = sys.argv[1], sys.argv[2]
mb = int(os.environ["LENGTH"]) / (1024 * 1024)
subs = {
    "{{VERSION}}": os.environ["VERSION"],
    "{{ZIP}}":     "/" + os.environ["ZIP_NAME"],
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

# Round-trip the signature against the staged archive. sign_update --verify is
# the same check Sparkle performs on the user's machine, so a pass here means a
# working update rather than a well-formed XML file.
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --verify "$STAGE/$ZIP_NAME" "$ED_SIG" --ed-key-file - > /dev/null
echo "    signature verifies against the staged archive"

# --- deploy ------------------------------------------------------------------

if [[ "$STAGE_ONLY" -eq 1 ]]; then
  echo
  echo "==> --stage-only: nothing deployed. Staged in $STAGE:"
  ls -la "$STAGE"
  exit 0
fi

CREDS=""
# `if`, never `[[ -n "$CREDS" ]] && rm ...`: under `set -e` a false test as a
# function's LAST statement trips errexit inside the function, which here exits
# the script 1 on a completely successful run. Traps are not special -- this bites
# any function or sourced script ending in a `&&` list whose test can be false.
cleanup() { if [[ -n "$CREDS" ]]; then rm -f "$CREDS"; fi; }
trap cleanup EXIT

if [[ -n "${FIREBASE_SERVICE_ACCOUNT:-}" ]]; then
  CREDS="$(mktemp)"
  printf '%s' "$FIREBASE_SERVICE_ACCOUNT" > "$CREDS"
  export GOOGLE_APPLICATION_CREDENTIALS="$CREDS"
  echo "    auth: service account"
else
  echo "    auth: local firebase login"
fi

firebase deploy --only hosting --project "$FIREBASE_PROJECT" --non-interactive

echo
echo "==> Live:"
echo "    $SITE_HOST/"
echo "    $SITE_HOST/appcast.xml"

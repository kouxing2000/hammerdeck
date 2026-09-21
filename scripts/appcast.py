#!/usr/bin/env python3
"""The Sparkle appcast, which carries two channels on one feed.

Every installed copy polls ONE feed. What separates a beta tester from everyone
else is not the URL they poll but the `<sparkle:channel>` on an item: an item
tagged `beta` is visible only to a copy whose `allowedChannelsForUpdater`
includes it, and an item with no channel tag is the default channel, which
Sparkle always includes for everybody. So the ladder is a property of the feed,
not of the hosting:

    publish V            feed = [current production item] + [V, channel beta]
    promote V            feed = [V]

The STAGING site is not on this ladder and takes a third mode, `rehearsal`: it
is a rig for proving the update mechanism against a normal copy, and a normal
copy is not subscribed to beta, so a rehearsal published to the beta channel
would be invisible to the very thing it exists to test. A rehearsal feed is one
default-channel item and nothing else.

`firebase deploy` replaces site content wholesale, so the production item is not
merely COPIED FORWARD in the XML -- its archive has to be re-uploaded too, or
the entry becomes an offer to download a 404. `carried` is what tells the
publish script which file to fetch.

The promote gate lives here rather than in the caller because it is a question
about the feed's own contents: a version may only enter the default channel if
the live feed already advertises it, byte-identically, on beta. Ed25519 is
deterministic, so comparing the published signature against the one computed
over the local file is a byte-identity check that downloads nothing.

Usage:
  appcast.py carried --live live.xml
  appcast.py build --stage beta|production|rehearsal --version V --site-host URL \\
      --archive NAME --length N --signature SIG --min-os 13.0 \\
      --notes-file F [--live live.xml] [--pub-date STR]
  appcast.py --self-test
"""

import argparse
import os
import sys
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
S = f"{{{SPARKLE_NS}}}"
BETA = "beta"

# Every child an item of ours may carry. An unknown one is a refusal rather than
# a silent drop: this script REBUILDS each carried item from named fields instead
# of splicing raw XML, so anything it does not know about would vanish from the
# feed without a trace -- a delta-update entry, a phased-rollout interval, a
# `sparkle:criticalUpdate`. Losing one of those quietly is worse than stopping.
KNOWN_CHILDREN = {
    "title", "description", "pubDate", "link", "enclosure",
    f"{S}version", f"{S}shortVersionString", f"{S}minimumSystemVersion",
    f"{S}channel",
}

# Same reasoning one level down. `type` is re-emitted as a constant, so it is
# known-and-ignored rather than carried; anything else on the enclosure would be
# dropped by the rebuild exactly as an unknown child would.
KNOWN_ENCLOSURE_ATTRS = {"url", "length", "type", f"{S}edSignature"}

# A channel this script does not model is matched by neither selector below, so
# a rebuild would drop its item silently. Sparkle compares channel names
# case-sensitively, so `Beta` is a DIFFERENT channel, not a typo to forgive.
KNOWN_CHANNELS = {None, BETA}


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


class Item:
    """One appcast entry, reduced to the fields this feed uses."""

    def __init__(self, version: str, notes: str, pub_date: str, link: str,
                 min_os: str, url: str, length: str, signature: str,
                 channel: str | None):
        self.version = version
        self.notes = notes
        self.pub_date = pub_date
        self.link = link
        self.min_os = min_os
        self.url = url
        self.length = length
        self.signature = signature
        self.channel = channel

    @property
    def is_beta(self) -> bool:
        return self.channel == BETA


def _text(item: ET.Element, tag: str) -> str:
    found = item.find(tag)
    if found is None:
        return ""
    if len(found) > 0:
        # `.text` stops at the first child element, so markup written as real
        # XML rather than CDATA would come back truncated -- and release notes
        # silently losing their second half is worse than a refusal.
        die(f"<{tag}> in the live appcast contains child elements; this script "
            "reads it as text and would truncate it.")
    return "" if found.text is None else found.text.strip()


def parse_items(xml_text: str) -> list[Item]:
    """The items of a live feed. An empty or absent feed is an empty list."""
    if not xml_text.strip():
        return []
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as exc:
        die(f"the live appcast is not parseable XML: {exc}")

    items = []
    for el in root.iter("item"):
        unknown = {c.tag for c in el} - KNOWN_CHILDREN
        if unknown:
            die("the live appcast carries an element this script would drop when "
                f"it rebuilds the feed: {sorted(unknown)}. Teach appcast.py about "
                "it before publishing, or the next publish deletes it silently.")
        enclosure = el.find("enclosure")
        if enclosure is None:
            die("an item in the live appcast has no <enclosure>; refusing to "
                "rebuild a feed whose existing entry points nowhere.")
        stray = set(enclosure.keys()) - KNOWN_ENCLOSURE_ATTRS
        if stray:
            die("the live appcast's enclosure carries an attribute this script "
                f"would drop when it rebuilds the feed: {sorted(stray)}.")
        channel = el.find(f"{S}channel")
        items.append(Item(
            version=_text(el, f"{S}version"),
            notes=_text(el, "description"),
            pub_date=_text(el, "pubDate"),
            link=_text(el, "link"),
            min_os=_text(el, f"{S}minimumSystemVersion"),
            url=enclosure.get("url", ""),
            length=enclosure.get("length", ""),
            signature=enclosure.get(f"{S}edSignature", ""),
            channel=None if channel is None else (channel.text or "").strip(),
        ))
    for i in items:
        if i.channel not in KNOWN_CHANNELS:
            die(f"the live appcast has an item on channel '{i.channel}', which "
                "this script neither publishes nor carries -- rebuilding the feed "
                "would delete it. Teach appcast.py about that channel first.")
    return items


def default_item(items: list[Item]) -> Item | None:
    """The one every copy can see. There is at most one by construction."""
    plain = [i for i in items if not i.channel]
    if len(plain) > 1:
        die(f"the live appcast has {len(plain)} default-channel items; this feed "
            "is built to carry exactly one and cannot choose between them.")
    return plain[0] if plain else None


def beta_item(items: list[Item]) -> Item | None:
    """The candidate on offer. At most one, for the same reason as the default:
    two would make "is this version on beta?" a question with two answers, and
    the promote gate's whole job is to answer it."""
    betas = [i for i in items if i.is_beta]
    if len(betas) > 1:
        die(f"the live appcast has {len(betas)} beta items; this feed carries at "
            "most one and cannot tell which was promoted.")
    return betas[0] if betas else None


def _escape(text: str) -> str:
    # `"` included because this escapes ATTRIBUTE values as well as text -- a
    # quote in a URL or signature would otherwise close the attribute early.
    return (text.replace("&", "&amp;").replace("<", "&lt;")
                .replace(">", "&gt;").replace('"', "&quot;"))


def render_item(item: Item) -> str:
    """One <item>. Notes go in CDATA, which is how the HTML survives the trip.

    A carried item's notes were read back out of CDATA already unescaped, so they
    go straight back in -- no double round of escaping, and the reader sees the
    same bytes it saw before.
    """
    if "]]>" in item.notes:
        # It would close the CDATA section early and hand every installed copy a
        # feed it cannot parse. release-notes.py refuses this at the tag too;
        # carried notes have not been through that check in this process.
        die("release notes contain ']]>', which cannot go inside CDATA. Reword them.")
    channel = (f"\n            <sparkle:channel>{_escape(item.channel)}</sparkle:channel>"
               if item.channel else "")
    return f"""        <item>
            <title>{_escape(item.version)}</title>
            <description><![CDATA[
{item.notes}
            ]]></description>
            <pubDate>{_escape(item.pub_date)}</pubDate>
            <link>{_escape(item.link)}</link>
            <sparkle:version>{_escape(item.version)}</sparkle:version>
            <sparkle:shortVersionString>{_escape(item.version)}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{_escape(item.min_os)}</sparkle:minimumSystemVersion>{channel}
            <enclosure url="{_escape(item.url)}" length="{_escape(item.length)}" type="application/octet-stream" sparkle:edSignature="{_escape(item.signature)}"/>
        </item>"""


def render_feed(app_name: str, site_host: str, items: list[Item]) -> str:
    body = "\n".join(render_item(i) for i in items)
    return f"""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="{SPARKLE_NS}" version="2.0">
    <channel>
        <title>{_escape(app_name)}</title>
        <link>{_escape(site_host)}/appcast.xml</link>
        <description>Updates for {_escape(app_name)}</description>
        <language>en</language>
{body}
    </channel>
</rss>
"""


def build(args) -> str:
    live = parse_items(_read(args.live) if args.live else "")
    notes = _read(args.notes_file)
    pub_date = args.pub_date or datetime.now(timezone.utc).strftime(
        "%a, %d %b %Y %H:%M:%S +0000")

    fresh = Item(
        version=args.version, notes=notes, pub_date=pub_date,
        link=f"{args.site_host}/", min_os=args.min_os,
        url=f"{args.site_host}/{args.archive}",
        length=str(args.length), signature=args.signature,
        channel=BETA if args.stage == "beta" else None,
    )

    if args.stage == "rehearsal":
        # No ladder, no carry, no gate: the staging feed is a rig, and its one
        # item has to be visible to a copy that never opted into anything.
        fresh.channel = None
        return render_feed(args.app_name, args.site_host, [fresh])

    if args.stage == "beta":
        # The production entry rides along untouched. Dropping it would strand
        # everyone NOT on beta on whatever they have, with the feed advertising
        # a version they are not allowed to see.
        current = default_item(live)
        if current and current.version == args.version:
            die(f"{args.version} is already the production release; publishing it "
                "to beta would advertise one version in two channels at once.")
        return render_feed(args.app_name, args.site_host,
                           [fresh] + ([current] if current else []))

    # --- promote -------------------------------------------------------------
    staged = beta_item(live)
    if staged is None:
        die(f"the live feed advertises no beta, so {args.version} cannot be "
            "promoted. Publish it to beta first -- that is the whole ladder.")
    if staged.version != args.version:
        die(f"the live feed's beta is {staged.version}, not {args.version}. "
            "Promote that one, or publish this one to beta first.")
    if staged.signature != args.signature:
        # Ed25519 signs deterministically, so a mismatch means the bytes differ
        # -- a rebuild, a re-download, a truncated asset. Promoting would put
        # untested bytes in front of everyone under a tested version number.
        die(f"the beta {args.version} on the live feed was signed over different "
            "bytes than the local archive. Promote the artifact that was tested, "
            "not a rebuild of it.")
    # Same item, minus the channel tag: the enclosure URL and signature carry
    # over verbatim, so promotion re-publishes rather than re-signs.
    fresh.url = staged.url
    fresh.length = staged.length
    fresh.pub_date = staged.pub_date
    fresh.channel = None
    return render_feed(args.app_name, args.site_host, [fresh])


def _read(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except FileNotFoundError:
        return ""


def carried(args) -> str:
    """The production item, tab-separated: version, length, url, min_os,
    pub_date, signature.

    All five at once because they are read together and re-parsing the feed per
    field is how two of them end up from different builds. The page must keep
    advertising the PRODUCTION release while a beta is out -- publishing a
    candidate is not supposed to change what a stranger downloads -- and that
    means its minimum OS and its date too, not just its version: a beta that
    raises the minimum would otherwise tell a macOS 13 user not to download a
    build that runs fine for them.
    """
    current = default_item(parse_items(_read(args.live)))
    if not current:
        return ""
    return "\t".join([current.version, current.length, current.url,
                       current.min_os, current.pub_date, current.signature])


# --- tests -------------------------------------------------------------------

class _Args:
    """The argparse namespace `build`/`carried` read, without argparse.

    Deliberately feeding the REAL entry points: a test that re-derives the
    ladder would pass while build() disagreed with it.
    """

    def __init__(self, live_xml="", **kw):
        self.app_name = "Hammerdeck"
        self.site_host = "https://example.test"
        self.archive = f"Hammerdeck-{kw.get('version', '0')}.dmg"
        self.length = "100"
        self.min_os = "13.0"
        self.pub_date = "Thu, 01 Jan 2026 00:00:00 +0000"
        self.notes_file = os.devnull
        # A real file, because `build` reads one -- the point is to exercise the
        # same path the publish script takes, including the parse.
        handle = tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False)
        handle.write(live_xml)
        handle.close()
        self.live = handle.name
        for k, v in kw.items():
            setattr(self, k, v)


def self_test() -> None:
    checks: list[tuple[str, bool]] = []

    def ok(label: str, condition: bool) -> None:
        checks.append((label, condition))

    def feed(*items) -> str:
        return render_feed("Hammerdeck", "https://example.test", list(items))

    def item(version, channel=None, sig="SIG", url=None):
        return Item(version=version, notes="<p>notes</p>", pub_date="Thu, 01 Jan 2026 00:00:00 +0000",
                    link="https://example.test/", min_os="13.0",
                    url=url or f"https://example.test/Hammerdeck-{version}.dmg",
                    length="100", signature=sig, channel=channel)

    prod, beta = item("1.0.0"), item("1.1.0", channel=BETA)
    both = parse_items(feed(beta, prod))
    ok("a rendered feed parses back into the same two items", len(both) == 2)
    ok("the untagged item is the default one", default_item(both).version == "1.0.0")
    ok("the tagged item is the beta", beta_item(both).version == "1.1.0")
    ok("a feed with no items yields nothing", parse_items(feed()) == [])
    ok("an absent feed is not an error", parse_items("") == [])

    ok("the beta item carries a channel tag",
       "<sparkle:channel>beta</sparkle:channel>" in feed(beta))
    ok("the production item carries none",
       "sparkle:channel" not in feed(prod))
    ok("notes survive the round trip as HTML, not as escaped text",
       parse_items(feed(prod))[0].notes == "<p>notes</p>")
    ok("the signature survives the round trip",
       parse_items(feed(prod))[0].signature == "SIG")

    # Refusals. `die` writes to stderr, which would otherwise print above these
    # results and read as a failure on a passing run.
    def refuses(thunk) -> bool:
        err, sys.stderr = sys.stderr, open(os.devnull, "w")
        try:
            thunk()
            return False
        except SystemExit:
            return True
        finally:
            sys.stderr.close()
            sys.stderr = err

    # The guards: anything this script cannot rebuild must stop the publish
    # rather than disappear from the feed.
    ok("an unknown element refuses rather than being dropped",
       refuses(lambda: parse_items(
           feed(prod).replace("</item>", "  <sparkle:deltas/>\n        </item>"))))
    ok("an unknown enclosure attribute refuses",
       refuses(lambda: parse_items(
           feed(prod).replace('<enclosure url=', '<enclosure sparkle:os="macos" url='))))
    ok("an item on an unmodelled channel refuses rather than being dropped",
       refuses(lambda: parse_items(feed(item("2.0.0", channel="Beta")))))
    ok("two beta items refuse rather than one winning silently",
       refuses(lambda: beta_item(parse_items(feed(beta, item("1.2.0", channel=BETA))))))
    ok("notes carrying ]]> refuse rather than breaking the feed for everyone",
       refuses(lambda: render_item(Item("1.0.0", "a ]]> b", "d", "l", "13.0",
                                        "u", "1", "s", None))))

    # The ladder. These five branches ARE the promote gate.
    live = feed(beta, prod)

    def promote(version, signature, live_xml=live):
        return build(_Args(stage="production", version=version, signature=signature,
                           live_xml=live_xml))

    ok("promoting a version the feed never offered on beta refuses",
       refuses(lambda: promote("9.9.9", "SIG")))
    ok("promoting bytes the feed did not advertise refuses",
       refuses(lambda: promote("1.1.0", "OTHER-SIG")))
    ok("promoting the advertised beta succeeds and drops the channel tag",
       "sparkle:channel" not in promote("1.1.0", "SIG"))
    ok("a promoted feed carries exactly one item",
       promote("1.1.0", "SIG").count("<item>") == 1)
    ok("promoting against a feed with no beta at all refuses",
       refuses(lambda: promote("1.0.0", "SIG", feed(prod))))
    ok("publishing the current production version to beta refuses",
       refuses(lambda: build(_Args(stage="beta", version="1.0.0", signature="SIG",
                                   live_xml=feed(prod)))))
    ok("a beta publish keeps the production item beside it",
       build(_Args(stage="beta", version="2.0.0", signature="S",
                   live_xml=feed(prod))).count("<item>") == 2)
    ok("a rehearsal publishes one item on no channel, ignoring the live feed",
       "sparkle:channel" not in build(_Args(stage="rehearsal", version="9.9.8",
                                            signature="S", live_xml=live)))

    ok("carried reports the production version, length and url",
       carried(_Args(live_xml=feed(prod))).split("\t")[:3]
       == ["1.0.0", "100", "https://example.test/Hammerdeck-1.0.0.dmg"])
    ok("carried reports the production minimum OS, not the beta's",
       carried(_Args(live_xml=feed(beta, prod))).split("\t")[3] == "13.0")
    ok("carried reports the signature, so the caller can verify what it re-hosts",
       carried(_Args(live_xml=feed(prod))).split("\t")[5] == "SIG")
    ok("carried reports nothing when only a beta is on the feed",
       carried(_Args(live_xml=feed(beta))) == "")

    failed = [label for label, condition in checks if not condition]
    for label, condition in checks:
        print(f"  {'ok  ' if condition else 'FAIL'}  {label}")
    print(f"{len(checks) - len(failed)}/{len(checks)} passed")
    raise SystemExit(1 if failed else 0)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true")
    sub = ap.add_subparsers(dest="command")

    carried_cmd = sub.add_parser("carried")
    carried_cmd.add_argument("--live", required=True)

    b = sub.add_parser("build")
    b.add_argument("--stage", choices=["beta", "production", "rehearsal"], required=True)
    b.add_argument("--version", required=True)
    b.add_argument("--app-name", default="Hammerdeck")
    b.add_argument("--site-host", required=True)
    b.add_argument("--archive", required=True)
    b.add_argument("--length", required=True)
    b.add_argument("--signature", required=True)
    b.add_argument("--min-os", required=True)
    b.add_argument("--notes-file", required=True)
    b.add_argument("--pub-date")
    b.add_argument("--live")

    args = ap.parse_args()
    if args.self_test:
        self_test()
    if args.command == "carried":
        print(carried(args))
    elif args.command == "build":
        print(build(args), end="")
    else:
        ap.error("a command is required (carried, build) or --self-test")


if __name__ == "__main__":
    main()

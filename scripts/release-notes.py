#!/usr/bin/env python3
"""Release notes for one version, read from its annotated git tag.

The tag message is the single source. It is written once, at the moment of
tagging, by the person who knows what shipped, and it is already the only
per-version prose anywhere in the repo -- see `git tag -l v0.1.2
--format='%(contents)'`. A CHANGELOG.md would be a second place to remember,
and the pipeline's standing rule is that nothing in the tracked tree carries a
version number that can go stale (see publish-site.sh's header: everything it
deploys is generated into dist/site/).

Two channels, one source:

  scripts/publish-site.sh --format html   the appcast <description>, which
                                          Sparkle renders in the update dialog.
  .github/workflows/release.yml           the GitHub Release body, as text.
                                          NOT gh's own --notes-from-tag, which
                                          answers a lightweight tag with the
                                          tagged COMMIT's message; this refuses
                                          one instead (see notes_for).

Usage:
  scripts/release-notes.py 0.1.2                  the prose, as written
  scripts/release-notes.py 0.1.2 --format html    for the appcast
  scripts/release-notes.py --self-test            the conversion's own tests
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

EM_DASH = "—"

# Sparkle injects ONE rule into release-notes HTML -- `body { font-family: ...;
# font-size: ...; }` (verified in the framework binary) -- and no colours. With
# no `color-scheme` the WebView keeps its light-mode default of black text, and
# Sparkle sets drawsBackground:NO so the dark panel shows through: in dark mode
# the notes render black-on-dark, unreadable at the one moment they exist to be
# read. Declaring the SCHEME rather than a colour pair lets the UA pick both,
# which is what keeps this right in either appearance.
STYLE = "<style>:root { color-scheme: light dark; }</style>"


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def _escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _inline(text: str) -> str:
    # ` -- ` only with a space on BOTH sides: the house style writes prose
    # dashes that way, while `--stage-only` and `--generate-notes` appear in
    # these notes too and must survive as themselves.
    return _escape(text).replace(" -- ", f" {EM_DASH} ")


def to_html(body: str) -> str:
    """Plain-text release prose -> the minimal HTML Sparkle's WebView renders.

    Hard-wrapped lines rejoin into one paragraph, blank lines separate
    paragraphs, and `- ` lines become a list. Without the list arm a bulleted
    tag message would render as one run-on paragraph -- wrong, and silently so.
    """
    blocks: list[str] = []
    para: list[str] = []
    items: list[list[str]] = []

    def flush_para() -> None:
        if para:
            blocks.append("<p>" + _inline(" ".join(para)) + "</p>")
            para.clear()

    def flush_list() -> None:
        if items:
            cells = "".join("<li>" + _inline(" ".join(i)) + "</li>" for i in items)
            blocks.append("<ul>" + cells + "</ul>")
            items.clear()

    for raw in body.splitlines():
        line = raw.strip()
        if not line:
            flush_para()
            flush_list()
            continue
        bullet = re.match(r"^[-*]\s+(.*)$", line)
        if bullet:
            flush_para()
            items.append([bullet.group(1)])
        elif items:
            items[-1].append(line)   # a wrapped continuation of the bullet above
        else:
            para.append(line)
    flush_para()
    flush_list()
    return "\n".join(blocks)


def parse(contents: str, version: str) -> str:
    """The tag's message -> the prose, with the redundant subject line dropped.

    The convention these tags follow is a subject naming the release
    ("Hammerdeck 0.1.2"), a blank line, then the prose. Both channels already
    display the version beside the notes, so a subject that only RESTATES it is
    noise -- but a subject carrying anything else is kept, because dropping real
    content is the worse failure and a one-line tag message has no other home.
    """
    lines = contents.strip("\n").split("\n")
    restates = rf"\s*(Hammerdeck\s+)?v?{re.escape(version)}\s*"
    if lines and re.fullmatch(restates, lines[0], re.IGNORECASE):
        lines = lines[1:]
    return "\n".join(lines).strip()


# The repo this script lives in, NOT the caller's working directory. Without
# `-C`, running it from anywhere else reads whatever repo the shell happens to be
# in: from a non-repo it reports "no tag" and advises re-tagging a tag that
# exists, and from ANOTHER repo carrying the same tag name it prints that
# project's notes and exits 0, which publish-site.sh would then deploy.
# publish-site.sh is cwd-independent everywhere else, and its header exists to
# support a hand-run release when CI is down.
REPO = Path(__file__).resolve().parent.parent


def _git(args: list[str]) -> tuple[int, str]:
    run = subprocess.run(["git", "-C", str(REPO)] + args,
                         capture_output=True, text=True)
    return run.returncode, run.stdout.strip()


def notes_for(version: str) -> str:
    version = version.removeprefix("v")
    tag = "v" + version

    code, kind = _git(["cat-file", "-t", tag])
    if code != 0:
        die(f"no tag {tag}. The release notes live in the tag's own annotation; "
            f"create it with `git tag -a {tag}` before releasing.")
    if kind != "tag":
        # `git tag -l --format='%(contents)'` answers a lightweight tag with the
        # tagged COMMIT's message, so this would otherwise ship a commit subject
        # to every user as release notes, looking entirely plausible.
        die(f"{tag} is a LIGHTWEIGHT tag and carries no annotation. Re-tag with "
            f"`git tag -a -f {tag}` and force-push it.")

    code, contents = _git(["tag", "-l", tag, "--format=%(contents)"])
    if code != 0:
        die(f"could not read the annotation of {tag}")

    body = parse(contents, version)
    if not body:
        # The defect this whole script exists to close: an empty <description>
        # is an empty dialog at the moment a user decides whether to trust an
        # auto-update. Fail the release instead, while it is still a build error.
        die(f"{tag}'s annotation carries no prose beyond the version line. "
            f"Write what shipped into the tag message -- it is what Sparkle "
            f"shows the user before they accept the update.")
    if "]]>" in body:
        # Today the HTML path escapes `>` before this reaches CDATA, so this
        # cannot break the feed as written. It is a fence against the obvious
        # simplification: `sparkle:format="markdown"` (Sparkle 2.9+) puts the
        # prose into the CDATA RAW, and then this sequence closes the section
        # early and every installed copy gets a feed it cannot parse.
        die(f"{tag}'s annotation contains ']]>', which cannot go inside the "
            f"appcast's CDATA section. Reword it.")
    return body


def self_test() -> None:
    checks: list[tuple[str, bool]] = []

    def ok(label: str, condition: bool) -> None:
        checks.append((label, condition))

    ok("wrapped lines rejoin into one paragraph",
       to_html("one two\nthree four") == "<p>one two three four</p>")
    ok("a blank line starts a new paragraph",
       to_html("a\n\nb") == "<p>a</p>\n<p>b</p>")
    ok("`- ` lines become a list, not run-on prose",
       to_html("- one\n- two") == "<ul><li>one</li><li>two</li></ul>")
    ok("a wrapped bullet stays in its own item",
       to_html("- one\n  still one\n- two")
       == "<ul><li>one still one</li><li>two</li></ul>")
    ok("a lead-in paragraph flushes before the list",
       to_html("intro\n- one") == "<p>intro</p>\n<ul><li>one</li></ul>")
    ok("markup characters are escaped",
       to_html("a <b> & c") == "<p>a &lt;b&gt; &amp; c</p>")
    ok("a spaced -- becomes an em dash",
       to_html("a -- b") == f"<p>a {EM_DASH} b</p>")
    ok("a --flag survives as itself",
       to_html("pass --stage-only here") == "<p>pass --stage-only here</p>")
    ok("the subject line is dropped when it only restates the version",
       parse("Hammerdeck 0.1.2\n\nWhat shipped.", "0.1.2") == "What shipped.")
    ok("a subject carrying real content is kept",
       parse("Fixes the updater\n\nDetail.", "0.1.2")
       == "Fixes the updater\n\nDetail.")
    ok("a version-only subject is dropped too",
       parse("v0.1.2\n\nWhat shipped.", "0.1.2") == "What shipped.")
    ok("an annotation that is only a version line yields nothing",
       parse("Hammerdeck 0.1.2\n", "0.1.2") == "")

    failed = [label for label, condition in checks if not condition]
    for label, condition in checks:
        print(f"  {'ok  ' if condition else 'FAIL'}  {label}")
    print(f"{len(checks) - len(failed)}/{len(checks)} passed")
    raise SystemExit(1 if failed else 0)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("version", nargs="?", help="e.g. 0.1.2 (a leading v is fine)")
    ap.add_argument("--format", choices=["text", "html"], default="text")
    ap.add_argument("--self-test", action="store_true",
                    help="run the conversion's assertions; needs no git or tag")
    args = ap.parse_args()

    if args.self_test:
        self_test()
    if not args.version:
        ap.error("a version is required (or --self-test)")

    body = notes_for(args.version)
    print(body if args.format == "text" else STYLE + "\n" + to_html(body))


if __name__ == "__main__":
    main()

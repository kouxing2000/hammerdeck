#!/usr/bin/env python3
"""Render the download page: site/index.html's {{TOKENS}} -> a deployable page.

usage: VERSION=... DMG_URL=... LENGTH=... MIN_OS=... PUB_DATE=... \\
       scripts/render-page.py <src index.html> <dst index.html>

publish-site.sh calls this for every deploy; CI calls it with sample values so a
token the template gains without a substitution fails on push, not on release.
"""
import os, sys
from email.utils import parsedate_to_datetime
src, dst = sys.argv[1], sys.argv[2]
# The date of the BUILD the page offers (its feed pubDate), never the day of
# this deploy: a page that carries production forward, or a --page-only run,
# offers a build published earlier.
try:
    built = parsedate_to_datetime(os.environ["PUB_DATE"])
except (TypeError, ValueError):
    sys.exit(f"error: the page's build has no readable pubDate: {os.environ['PUB_DATE']!r}")
mb = int(os.environ["LENGTH"]) / (1024 * 1024)
subs = {
    "{{VERSION}}": os.environ["VERSION"],
    # An absolute URL off-site, not a site-root path: the page is on hosting
    # and the archive is on a GitHub Release.
    "{{DMG}}":     os.environ["DMG_URL"],
    "{{SIZE}}":    f"{mb:.1f} MB",
    "{{DATE}}":    built.strftime("%B %-d, %Y"),
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

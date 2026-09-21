#!/usr/bin/env python3
"""Check that every archive the live feeds advertise is still there, and still
the file that was signed.

The publish path verifies an archive on its way out. Nothing verified it
afterwards, and since the archives moved to GitHub Releases there is a whole
class of change that happens AFTER a publish and that no publish-time gate can
see: a release deleted or re-drafted, an asset replaced with `--clobber`, the
repository flipped private. Each one silently breaks updates for every installed
copy still on that version, while the feed and the download page look perfectly
healthy.

It runs ANONYMOUSLY -- urllib sends no credentials and reads no netrc -- because
that is the only interesting question. A tokenized fetch succeeds against a
draft release and against a private repo, which are two of the failures being
looked for.

It verifies the SIGNATURE, not just the length, and that is the whole reason it
is worth running. Re-running a release tag rebuilds and replaces the asset, and
a rebuild of the same commit differs only by notarization timestamps inside a
size-quantized disk image: measured on this repo's own 0.1.2 archive, flipping a
single byte leaves the length identical (8558121 both ways) and fails the
signature. A length check would report that asset healthy.

The feed parser is appcast.py's, deliberately: two parsers would eventually
disagree about what this project's feed is, and the generator's is the one that
defines it. Its strictness is a feature here -- a feed shape it refuses is
itself worth an alert.

Verification shells out to OpenSSL 3 because there is no Ed25519 in the standard
library. The raw 32-byte key from package.sh is wrapped in the fixed
SubjectPublicKeyInfo prefix for Ed25519; `-rawin` is required, since Ed25519
signs the message rather than a digest of it.

  scripts/feed-watch.py
"""

import argparse
import base64
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from appcast import parse_items  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGE_SH = os.path.join(ROOT, "scripts", "package.sh")

# Ed25519 SubjectPublicKeyInfo: SEQUENCE { SEQUENCE { OID 1.3.101.112 },
# BIT STRING (32 bytes) }. Fixed for every Ed25519 key, so the only variable
# part is the key itself.
ED25519_SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")


def package_const(name: str) -> str:
    """Read a constant out of package.sh -- the single source for the feed URLs
    and the public key, exactly as publish-site.sh reads them. A second copy
    here would drift, and the drift would only show up as an alert nobody can
    explain."""
    pattern = re.compile(rf'^{re.escape(name)}="([^"]*)"')
    with open(PACKAGE_SH, encoding="utf-8") as handle:
        for line in handle:
            match = pattern.match(line)
            if match:
                return match.group(1)
    sys.exit(f"error: {name} is not in {PACKAGE_SH}")


def public_key_pem() -> str:
    raw = base64.b64decode(package_const("SPARKLE_PUBLIC_KEY"))
    if len(raw) != 32:
        sys.exit(f"error: SPARKLE_PUBLIC_KEY decodes to {len(raw)} bytes, not 32")
    body = base64.b64encode(ED25519_SPKI_PREFIX + raw).decode()
    return f"-----BEGIN PUBLIC KEY-----\n{body}\n-----END PUBLIC KEY-----\n"


def fetch(url: str) -> bytes:
    # No credentials, no netrc, no curlrc: see the module docstring.
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read()


def check_feed(name: str, feed_url: str, key_pem: str) -> list[str]:
    """Returns the failures. An empty list means every enclosure resolved and
    verified -- said explicitly, because 'no output' is also what a checker that
    never ran looks like."""
    failures = []
    try:
        feed = fetch(feed_url).decode("utf-8")
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as err:
        return [f"{name}: the feed itself is unreadable at {feed_url} -- {err}"]

    items = parse_items(feed)
    if not items:
        # Not a pass. A feed with no items offers nobody anything, and on the
        # production host that is an outage rather than a quiet day.
        return [f"{name}: the feed parsed to ZERO items -- {feed_url}"]

    print(f"{name}: {len(items)} item(s) on {feed_url}")
    for item in items:
        channel = item.channel or "default"
        label = f"{name} {item.version} ({channel})"
        try:
            payload = fetch(item.url)
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as err:
            failures.append(f"{label}: archive unreachable ANONYMOUSLY -- {err}\n"
                            f"    {item.url}\n"
                            f"    A deleted release, a re-drafted one, or a private "
                            f"repo all look like this. Every copy offered this "
                            f"update gets the same error.")
            continue

        if str(len(payload)) != item.length:
            failures.append(f"{label}: {len(payload)} bytes, feed advertises "
                            f"{item.length}\n    {item.url}")
            continue

        with tempfile.TemporaryDirectory() as workdir:
            archive = os.path.join(workdir, "archive")
            signature = os.path.join(workdir, "sig")
            keyfile = os.path.join(workdir, "key.pem")
            with open(archive, "wb") as handle:
                handle.write(payload)
            with open(signature, "wb") as handle:
                handle.write(base64.b64decode(item.signature))
            with open(keyfile, "w", encoding="utf-8") as handle:
                handle.write(key_pem)
            done = subprocess.run(
                ["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", keyfile,
                 "-rawin", "-in", archive, "-sigfile", signature],
                capture_output=True, text=True, check=False)

        # Only a clean exit counts. A missing openssl, a build without Ed25519,
        # or a malformed key all exit non-zero too -- reporting any of those as
        # "the archive was tampered with" would be a confidently wrong alarm, so
        # the tool's own words go into the failure.
        if done.returncode != 0:
            failures.append(f"{label}: signature does NOT verify over the bytes "
                            f"being served, at the length the feed claims\n"
                            f"    {item.url}\n"
                            f"    openssl: {(done.stderr or done.stdout).strip()}\n"
                            f"    An asset replaced after it was signed looks "
                            f"exactly like this. Copies offered this update will "
                            f"download it and refuse to install.")
            continue

        print(f"  ok  {item.version} ({channel})  {len(payload)} bytes, signature verifies")
    return failures


def main() -> int:
    argparse.ArgumentParser(description=__doc__).parse_args()
    failures = check_feed("release", package_const("SPARKLE_FEED_URL_RELEASE"),
                          public_key_pem())
    if failures:
        print()
        for failure in failures:
            print(f"FAIL {failure}", file=sys.stderr)
        return 1
    print("\nevery enclosure on the live feed resolves anonymously and verifies")
    return 0


if __name__ == "__main__":
    sys.exit(main())

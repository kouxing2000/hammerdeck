#!/usr/bin/env python3
"""The Homebrew cask in kouxing2000/homebrew-tap: read it, and point it at a build.

The cask follows PRODUCTION, never GitHub's "Latest" release. A notarized tag
becomes Latest the moment release.yml publishes it, while the build is still
only on the beta channel, so anything keyed off Latest would hand
`brew install` a beta. The bump therefore runs from publish.yml's production
path -- the same event that moves the download page -- and feed-watch.py holds
the cask to the live feed's default-channel item every day, which catches a
bump that failed or never ran.

  scripts/cask.py bump <version> <archive.dmg> <path/to/Casks/hammerdeck.rb>
      Rewrites `version` and `sha256` in place from the archive's bytes. Prints
      "unchanged" and leaves the file alone when it already matches.
"""

import hashlib
import re
import sys

CASK_RAW_URL = ("https://raw.githubusercontent.com/kouxing2000/homebrew-tap/"
                "main/Casks/hammerdeck.rb")

# Anchored to the stanza's own indentation so a `version` inside livecheck or
# a string elsewhere can never be the one rewritten.
VERSION_RE = re.compile(r'^(  version ")([^"]+)(")$', re.MULTILINE)
SHA_RE = re.compile(r'^(  sha256 ")([0-9a-f]{64})(")$', re.MULTILINE)


def read(text: str) -> tuple[str, str]:
    """(version, sha256) of a cask. Raises ValueError on a shape it does not
    recognise, so a reformatted cask fails loudly instead of reading as drift."""
    versions, shas = VERSION_RE.findall(text), SHA_RE.findall(text)
    if len(versions) != 1 or len(shas) != 1:
        raise ValueError(f"expected exactly one version and one sha256 stanza in "
                         f"the cask, found {len(versions)} and {len(shas)}")
    return versions[0][1], shas[0][1]


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def bump(version: str, archive: str, cask_path: str) -> int:
    if not re.fullmatch(r"\d+(\.\d+)*", version):
        sys.exit(f"error: '{version}' is not a release version")
    sha = sha256_of(archive)
    with open(cask_path, encoding="utf-8") as handle:
        text = handle.read()
    try:
        old = read(text)
    except ValueError as err:
        sys.exit(f"error: {cask_path}: {err}")
    if old == (version, sha):
        print(f"cask: unchanged, already {version} ({sha})")
        return 0
    text = VERSION_RE.sub(rf"\g<1>{version}\g<3>", text)
    text = SHA_RE.sub(rf"\g<1>{sha}\g<3>", text)
    if read(text) != (version, sha):
        sys.exit("error: the rewritten cask does not read back as the new build")
    with open(cask_path, "w", encoding="utf-8") as handle:
        handle.write(text)
    print(f"cask: {old[0]} -> {version} ({sha})")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 4 and argv[0] == "bump":
        return bump(*argv[1:])
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

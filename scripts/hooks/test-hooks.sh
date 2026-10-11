#!/usr/bin/env bash
#
# test-hooks.sh -- prove the publication hooks (pre-commit, commit-msg) block what
# they must and pass what they must. A hook that silently passes everything looks
# exactly like a clean repo, so CI runs this. Everything happens in a throwaway repo
# with a made-up private-name list; the real repo is never committed to.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-hooks.$$.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
git init -q "$repo" && cd "$repo" || exit 1
git config user.email hooks@example.invalid
git config user.name hooks-test
git config commit.gpgsign false
mkdir -p scripts/hooks
cp "$here/pre-commit" "$here/commit-msg" scripts/hooks/
git config core.hooksPath scripts/hooks
printf '# made-up names for this test\nsecretrepo\n/home/someone\n' > .git/info/private-names
git add scripts
git commit -q -m "init" || { echo "FAIL: the hooks refused their own clean commit"; exit 1; }

# Split so this file does not trip the very hook it tests.
banned="pri""cing"
fails=0
expect() {   # expect <want-rc> <label> <command...>
    local want="$1" label="$2"; shift 2
    "$@" > /dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq "$want" ]; then
        echo "ok   $label"
    else
        echo "FAIL $label (exit $rc, want $want)"
        fails=$((fails + 1))
    fi
}

expect 1 "a message naming a private repo"     git commit -q --allow-empty -m "fix: from secretrepo"
expect 1 "a private name in another case"      git commit -q --allow-empty -m "fix: see SecretRepo"
expect 1 "a private path"                      git commit -q --allow-empty -m "fix: in /home/someone/x"
expect 1 "a banned word in the message"        git commit -q --allow-empty -m "fix: our $banned"
expect 1 "a '#' line, which -m keeps"          git commit -q --allow-empty -m "# secretrepo notes"
expect 0 "a clean message"                     git commit -q --allow-empty -m "fix: plain"

echo "notes on secretrepo" > a.txt && git add a.txt
expect 1 "a private name in a staged file"     git commit -q -m "add a"
git rm -q --cached a.txt && rm a.txt

# CLAUDE.md is exempt from the word scan (it states the policy), never from names.
echo "see secretrepo" > CLAUDE.md && git add CLAUDE.md
expect 1 "a private name in a word-exempt file" git commit -q -m "docs: notes"
git rm -q --cached CLAUDE.md && rm CLAUDE.md

# commit -v appends the staged diff below a scissors line; it is not the message.
# CLAUDE.md is exempt from the word scan, so only a message-side scan could trip.
echo "the $banned rule lives here" > CLAUDE.md && git add CLAUDE.md
expect 0 "the diff below commit -v's scissors" env GIT_EDITOR=true git commit -q -v -e -m "docs: rule"

git worktree add -q "$tmp/wt" -b wt > /dev/null 2>&1 || { echo "FAIL: could not add a worktree"; exit 1; }
expect 1 "a private name from a linked worktree" git -C "$tmp/wt" commit -q --allow-empty -m "wt: secretrepo"

mv .git/info/private-names "$tmp/names"
expect 0 "no list: the private-name check is off" git commit -q --allow-empty -m "fix: secretrepo"
mv "$tmp/names" .git/info/private-names

if [ "$fails" -ne 0 ]; then
    echo "test-hooks: $fails case(s) failed"
    exit 1
fi
echo "test-hooks: all cases passed"

#!/usr/bin/env bash
#
# test-hooks.sh -- prove the publication hooks (pre-commit, commit-msg, pre-push)
# block what they must and pass what they must. A hook that silently passes
# everything looks exactly like a clean repo, so CI runs this. Everything happens in
# a throwaway repo, with a made-up private-name list and a throwaway remote; the
# real repo is never committed to or pushed from.

set -uo pipefail

# Hermetic: git exports GIT_DIR and friends to the hooks it runs, and a global
# config can change the comment character. Either would aim this test at another
# repo, or turn a case red for reasons of its own.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# A UTF-8 locale, so the non-UTF-8 case proves the hook sets its own.
export LC_ALL=en_US.UTF-8

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-hooks.$$.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
git init -q -b master "$repo" && cd "$repo" || exit 1
git config user.email hooks@example.invalid
git config user.name hooks-test
git config commit.gpgsign false
git config tag.gpgsign false
mkdir -p scripts/hooks
cp "$here/pre-commit" "$here/commit-msg" "$here/pre-push" scripts/hooks/
git config core.hooksPath scripts/hooks
printf '# made-up names for this test\nsecretrepo\n/home/someone\n' > .git/info/private-names
git add scripts
git commit -q -m "init" || { echo "FAIL: the hooks refused their own clean commit"; exit 1; }
git init -q --bare "$tmp/remote.git" && git remote add origin "$tmp/remote.git"

# Split so this file does not trip the very hook it tests.
banned="pri""cing"
fails=0
expect() {   # expect <0|1> <label> <command...> -- 1 means a hook refused it
    local want="$1" label="$2"; shift 2
    local out rc ok=0
    out=$("$@" 2>&1); rc=$?
    if [ "$want" -eq 0 ]; then
        [ "$rc" -eq 0 ] && ok=1
    else
        # Any failure is not a refusal: a crashing hook or a broken command also
        # exits non-zero. Only the hook's own report counts.
        [ "$rc" -ne 0 ] && printf '%s' "$out" | LC_ALL=C grep -q BLOCKED && ok=1
    fi
    if [ "$ok" -eq 1 ]; then
        echo "ok   $label"
    else
        echo "FAIL $label (exit $rc, want $want)"
        printf '%s\n' "$out" | sed 's/^/       /'
        fails=$((fails + 1))
    fi
}

# --- commit-msg: the message as it is written
expect 1 "a message naming a private repo"     git commit -q --allow-empty -m "fix: from secretrepo"
expect 1 "a private name in another case"      git commit -q --allow-empty -m "fix: see SecretRepo"
expect 1 "a private path"                      git commit -q --allow-empty -m "fix: in /home/someone/x"
expect 1 "a banned word in the message"        git commit -q --allow-empty -m "fix: our $banned"
expect 1 "a '#' line, which -m keeps"          git commit -q --allow-empty -m "# secretrepo notes"
printf 'fix: caf\351 secretrepo\n' > "$tmp/latin1"
expect 1 "a name after a non-UTF-8 byte"       git commit -q --allow-empty -F "$tmp/latin1"
printf 'fix: \001 secretrepo\n' > "$tmp/ctrl"
expect 1 "a name beside a control byte"        git commit -q --allow-empty -F "$tmp/ctrl"
expect 0 "a clean message"                     git commit -q --allow-empty -m "fix: plain"

# --- pre-commit: the staged files
echo "notes on secretrepo" > a.txt && git add a.txt
expect 1 "a private name in a staged file"     git commit -q -m "add a"
git rm -q --cached a.txt && rm a.txt

echo "see secretrepo" > "caf$(printf '\303\251').txt" && git add .
expect 1 "a private name in a non-ASCII path"  git commit -q -m "add cafe"
git reset -q --hard

echo "plain" > secretrepo-notes.md && git add secretrepo-notes.md
expect 1 "a private name in a file's path"     git commit -q -m "add notes"
git reset -q --hard

# A rename and a type change publish new bytes at a path git does not call "added".
seq 1 40 > long.txt && echo "plain" > link.txt && git add long.txt link.txt
git commit -q -m "add files"
git mv long.txt moved.txt && echo "see secretrepo" >> moved.txt && git add moved.txt
expect 1 "a private name added in a rename"    git commit -q -m "move"
git reset -q --hard
rm link.txt && ln -s /home/someone/x link.txt && git add link.txt
expect 1 "a symlink to a private path"         git commit -q -m "link"
git reset -q --hard

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

before=$(git rev-parse HEAD)
mv .git/info/private-names "$tmp/names"
expect 0 "no list: the private-name check is off" git commit -q --allow-empty -m "fix: secretrepo"
mv "$tmp/names" .git/info/private-names
git reset -q --hard "$before"

# --- pre-push: every message about to publish, however its commit was made
expect 0 "a clean push"                        git push -q origin master
base=$(git rev-parse HEAD)

git checkout -q -b side
git commit -q --allow-empty --no-verify -m "side: secretrepo"
git checkout -q master
expect 1 "a --no-verify commit, on a new branch" git push -q origin side

git cherry-pick --allow-empty side > /dev/null 2>&1   # git runs no commit-msg here
expect 1 "a cherry-picked message"             git push -q origin master
git reset -q --hard "$base"

echo one > s.txt && git add s.txt && git commit -q -m "s: one"
echo two >> s.txt && git commit -q -am "s: two"
# Nor on a squash's final message.
GIT_SEQUENCE_EDITOR="sed -i.bak '2s/^pick/squash/'" GIT_EDITOR="printf 'squashed secretrepo\n' >" \
    git rebase -q -i "$base" > /dev/null 2>&1 || git rebase --abort > /dev/null 2>&1
expect 1 "a squash's final message"            git push -q origin master
git reset -q --hard "$base"

git tag -a v9 -m "release secretrepo"
expect 1 "an annotated tag's message"          git push -q origin v9
git tag -d v9 > /dev/null

expect 0 "nothing private reached the remote" \
    sh -c '! git -C "$1" log --all --format=%B | grep -qi secretrepo' _ "$tmp/remote.git"

if [ "$fails" -ne 0 ]; then
    echo "test-hooks: $fails case(s) failed"
    exit 1
fi
echo "test-hooks: all cases passed"

#!/usr/bin/env bash
# Regression for core PR 5246: the PR's commits were made BEFORE the last green deploy, the merge
# commit landed AFTER it. Counting without --first-parent saw 0 changes; the gate must see 1.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
cd "$t"; git init -q -b main .; git config user.email t@example.invalid; git config user.name t
mkdir -p ventures/opsjuice/landing other
fail=0; check() { if [ "$2" != "$3" ]; then echo "FAIL $1: want $3 got $2"; fail=1; else echo "ok   $1"; fi; }
gate() { bash "$here/oj-landing-gate.sh" "$t" "$1"; }
at() { GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" "${@:2}"; }
echo a > ventures/opsjuice/landing/index.html; echo a > other/x; git add -A
at "2026-01-01T00:00:00Z" git commit -qm base
git checkout -q -b pr
echo b > ventures/opsjuice/landing/index.html; at "2026-01-02T00:00:00Z" git commit -qam "landing edit"
echo c > ventures/opsjuice/landing/two.html; git add -A; at "2026-01-02T01:00:00Z" git commit -qm "landing two"
git checkout -q main; echo m > other/x; at "2026-01-02T02:00:00Z" git commit -qam "main moves"
last="2026-01-03T00:00:00Z"   # the last green deploy, after the PR commits, before the merge
at "2026-01-04T00:00:00Z" git merge -q --no-ff pr -m "merge pr"
old=$(git log --since="$last" --oneline -- ventures/opsjuice/landing | wc -l | tr -d ' ')
check "bug reproduced: counting without --first-parent sees the merge as 0 or branch-only" "$old" "0"
check "merge of a landing PR after the last deploy counts 1" "$(gate "$last")" "1"
git checkout -q -b noop; echo n > other/y; git add -A; at "2026-01-04T01:00:00Z" git commit -qm other
git checkout -q main; at "2026-01-04T02:00:00Z" git merge -q --no-ff noop -m "merge noop"
check "merge touching no landing input adds 0" "$(gate "$last")" "1"
git checkout -q -b sq; echo s > ventures/opsjuice/landing/index.html; at "2026-01-05T00:00:00Z" git commit -qam sq
git checkout -q main; git merge -q --squash sq >/dev/null; at "2026-01-05T01:00:00Z" git commit -qm "squash sq"
check "a squash commit counts 1 more" "$(gate "$last")" "2"
check "nothing after the cutoff counts 0" "$(gate "2026-02-01T00:00:00Z")" "0"
exit $fail

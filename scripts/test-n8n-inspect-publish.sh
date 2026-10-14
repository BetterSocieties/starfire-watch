#!/usr/bin/env bash
# Offline regression: runs the real "publish inspect report" step of n8n-inspect-workflow.yml against a fake git.
# The fake git rejects every push after a rejection until a rebase (pull) has run, like a moved main.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d "${TMPDIR:-/tmp}/n8n-inspect-test.XXXXXXXX")"
trap 'rm -rf -- "$t"' EXIT
mkdir -p "$t/bin" "$t/project/data"
echo '{}' > "$t/project/data/n8n-workflow-inspect.json"

python3 - "$repo/.github/workflows/n8n-inspect-workflow.yml" "$t/publish.sh" <<'PY'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
start = lines.index('      - name: publish inspect report')
run = lines.index('        run: |', start) + 1
body = []
for line in lines[run:]:
    if line and not line.startswith('          '):
        break
    body.append(line[10:] if line else '')
assert body, 'publish step not found'
pathlib.Path(sys.argv[2]).write_text('set -eo pipefail\n' + '\n'.join(body) + '\n')
PY
# Retry sleeps are real in CI; shorten them here.
printf '#!/usr/bin/env bash\nexit 0\n' > "$t/bin/sleep"

cat > "$t/bin/git" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$GIT_CALL_LOG"
case "${1:-}" in
  diff) exit 1 ;;
  push)
    if [ -e "$NEEDS_REBASE" ]; then echo 'rejected: non-fast-forward, rebase first' >&2; exit 1; fi
    n=$(cat "$PUSH_COUNT" 2>/dev/null || echo 0)
    if [ "$n" -lt "$FAIL_PUSHES" ]; then
      echo $((n + 1)) > "$PUSH_COUNT"; : > "$NEEDS_REBASE"; echo 'rejected: non-fast-forward' >&2; exit 1
    fi ;;
  pull)
    if [ "$FAIL_REBASE" = 1 ]; then echo 'CONFLICT (content): rebase stopped' >&2; exit 1; fi
    rm -f "$NEEDS_REBASE" ;;
esac
exit 0
STUB
chmod +x "$t/bin/git" "$t/bin/sleep"
export GIT_CALL_LOG="$t/calls" PUSH_COUNT="$t/push-count" NEEDS_REBASE="$t/needs-rebase"

# Letters: P push, R rebase (pull), A rebase --abort.
run_case() { # fail_pushes fail_rebase
  rm -f "$PUSH_COUNT" "$NEEDS_REBASE"; : > "$GIT_CALL_LOG"; rc=0
  (cd "$t/project" && PATH="$t/bin:$PATH" FAIL_PUSHES="$1" FAIL_REBASE="$2" bash "$t/publish.sh") > "$t/log" 2>&1 || rc=$?
  seq="$(awk '$1 == "push" { printf "P" } $1 == "pull" { printf "R" } $1 == "rebase" { printf "A" }' "$GIT_CALL_LOG")"
}
fail() { echo "FAIL: $1 (rc=$rc seq=$seq)"; cat "$t/log"; exit 1; }

run_case 1 0
[ "$rc" -eq 0 ] && [ "$seq" = PRP ] || fail 'rejected once then ok must exit 0 with a rebase before the retry'
run_case 3 0
[ "$rc" -eq 1 ] && [ "$seq" = PRPRP ] || fail '3 rejections must exit 1 after 3 pushes, each retry after a rebase'
grep -qF 'inspect report publication failed' "$t/log" || fail 'missing publication failed message'
grep -qF 'rejected: non-fast-forward' "$t/log" || fail 'last git error not printed'
run_case 1 1
[ "$rc" -eq 1 ] && [ "$seq" = PRA ] || fail 'rebase conflict must abort, exit 1 and not push again'
grep -qF 'inspect report publication failed' "$t/log" && grep -qF 'CONFLICT' "$t/log" || fail 'rebase conflict output missing'
echo 'PASS: inspect publish: retry recovers, 3 rejections fail, rebase conflict aborts and fails'

#!/usr/bin/env bash
# Offline check: the never-activate guard treats 404 as absent (no failure) and any other non-200 as failed.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d "${TMPDIR:-/tmp}/n8n-404-test.XXXXXXXX")"
trap 'rm -rf -- "$t"' EXIT
mkdir -p "$t/bin" "$t/project/scripts" "$t/project/config" "$t/project/data" "$t/project/core/STATE"
cp "$repo/scripts/n8n-activate.sh" "$t/project/scripts/"
printf 'gone123 removed workflow\n' > "$t/project/config/never-activate.txt"
cat > "$t/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=/dev/null
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -X|-H|-w|--data-urlencode|--data-binary) shift 2 ;; *) url="$1"; shift ;; esac; done
case "$url" in
  */workflows/gone123) printf '{"message":"x"}' > "$out"; printf '%s' "$GUARD_CODE" ;;
  */workflows*) printf '{"data":[],"nextCursor":null}' > "$out"; printf 200 ;;
  *) printf '{}' > "$out"; printf 599 ;;
esac
STUB
chmod +x "$t/bin/curl"
run() {
  local code="$1" want_rc="$2" want_line="$3" rc=0
  (cd "$t/project" && GUARD_CODE="$code" PATH="$t/bin:$PATH" N8N_URL=https://invalid.example N8N_API_KEY=fake \
    GITHUB_RUN_ID=t1 GITHUB_RUN_ATTEMPT=1 N8N_PUBLIC_REPORT="$t/project/data/s.json" \
    N8N_PRIVATE_REPORT="$t/project/core/STATE/r.json" bash scripts/n8n-activate.sh) > "$t/log" 2>&1 || rc=$?
  [ "$rc" -eq "$want_rc" ] || { echo "FAIL code=$code rc=$rc want $want_rc"; cat "$t/log"; exit 1; }
  grep -qF "$want_line" "$t/log" || { echo "FAIL code=$code missing: $want_line"; cat "$t/log"; exit 1; }
  python3 - "$t/project/data/s.json" "$2" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))['never_activate_guard']
absent, failed = (1, 0) if sys.argv[2] == '0' else (0, 1)
assert g['absent'] == absent and g['failed'] == failed, g
PY
  echo "PASS http=$code: $want_line"
}
run 404 0 'NEVER-ACTIVATE GUARD: checked=1 corrected=0 failed=0 absent=1'
run 500 1 'NEVER-ACTIVATE GUARD: checked=1 corrected=0 failed=1 absent=0'
run 401 1 'NEVER-ACTIVATE GUARD: checked=1 corrected=0 failed=1 absent=0'
run 403 1 'NEVER-ACTIVATE GUARD: checked=1 corrected=0 failed=1 absent=0'

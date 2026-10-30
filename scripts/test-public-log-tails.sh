#!/usr/bin/env bash
# Offline check that the OJ jobs print no row data into this public repo's Actions log on a failure:
# every log tail goes through the job's SAFE_LINES allow-list, and that list drops name and site lines
# while keeping the error and count lines a failed run needs.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS: $1"; else fail=$((fail+1)); echo "FAIL: $1 (got $2, want $3)"; fi; }

for wf in "$repo"/.github/workflows/core-oj-*.yml; do
  name="$(basename "$wf")"
  tails="$(grep -c 'tail -n' "$wf")"
  [ "$tails" -eq 0 ] && continue
  safe="$(grep -c 'tail -n [0-9]* "[^"]*" | { grep -E "\$SAFE_LINES" || true; } |' "$wf")"
  check "$name: every log tail is filtered" "$safe" "$tails"
  pattern="$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1])).get("env",{}).get("SAFE_LINES",""))' "$wf")"
  check "$name: defines SAFE_LINES" "$([ -n "$pattern" ] && echo yes || echo no)" yes
  [ -n "$pattern" ] || continue
  leaked="$(printf '%s\n' "[3/40] 'Acme Plumbing LLC' (plumbing)" "  refused: Acme Plumbing LLC (the store refused it (HTTP 403))" \
    "  deferred to the next run: Bob HVAC (the store answered HTTP 520)" "  FOUND Acme Plumbing <https://acme.example>" \
    "  SKIP  Bob HVAC <https://bobhvac.example>" | { grep -E "$pattern" || true; } | wc -l | tr -d ' ')"
  check "$name: name and site lines are dropped" "$leaked" 0
  kept="$(printf '%s\n' "Traceback (most recent call last):" "oj_d1.D1Error: HTTP 400: D1 error 7500 daily read limit" \
    "KeyError: 'niche'" "found=1 written=1 write_failed=0 skipped=1 dnc=1" "D1 statements this run: 4" | { grep -E "$pattern" || true; } | wc -l | tr -d ' ')"
  check "$name: error and count lines are kept" "$kept" 5
  shapes="$(printf '%s\n' "D1 Joe" "end of Joe Smith Plumbing" "exit Joe Smith Plumbing, Mesa AZ" | { grep -E "$pattern" || true; } | wc -l | tr -d ' ')"
  check "$name: loose shapes carrying a name are dropped" "$shapes" 0
  rows="$(grep -cE 'cat "\$RUNNER_TEMP/screened' "$wf")"
  check "$name: the public run summary carries no row list" "$rows" 0
done

# The gmaps step's own script, run with the scraper call swapped for a fake that writes a log and exits.
gmaps_wf="$repo/.github/workflows/core-oj-source-daily.yml"
gmaps_step="$(python3 - "$gmaps_wf" <<'PY'
import re, sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["gmaps"]["steps"]
run = next(s["run"] for s in steps if "oj-source-gmaps.py" in s.get("run", ""))
fake, n = re.subn(r"python3 scripts/vault-get\.py.*?--apply", 'sh "$FAKE"', run, count=1, flags=re.S)
assert n == 1, "scraper call not found"
print(fake)
PY
)"
gmaps_case() {  # $1 = fake log text, $2 = fake exit code; prints the step's exit code
  local dir="$repo/.test-gmaps"; mkdir -p "$dir"
  printf '%s\n' "$1" > "$dir/log.txt"
  printf 'cat "%s"; exit %s\n' "$dir/log.txt" "$2" > "$dir/fake.sh"
  SAFE_LINES="$gmaps_pattern" RUNNER_TEMP="$dir" FAKE="$dir/fake.sh" bash -c "$gmaps_step" >/dev/null 2>&1
  echo $?
}
gmaps_pattern="$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1])).get("env",{}).get("SAFE_LINES",""))' "$gmaps_wf")"
check "gmaps: empty scrape exits 4" "$(gmaps_case '{"queries": 8, "places": 0, "inserted": 0}' 0)" 4
check "gmaps: good scrape exits 0" "$(gmaps_case '{"queries": 8, "places": 31, "inserted": 12}' 0)" 0
check "gmaps: exit 0 with no counts line exits 5" "$(gmaps_case 'Metros today: 3' 0)" 5
check "gmaps: a crash keeps the script's exit code" "$(gmaps_case 'exit=2 gmaps scraper timed out after 3600 s' 2)" 2
# Reuses the exit-2 fake the crash case above wrote; only the log changes.
leak="$(SAFE_LINES="$gmaps_pattern" RUNNER_TEMP="$repo/.test-gmaps" FAKE="$repo/.test-gmaps/fake.sh" bash -c \
  "printf '%s\n' 'someone@example.invalid' 'Acme Plumbing 12 Test St' 'exit=2 gmaps scraper failed' > \"\$RUNNER_TEMP/log.txt\"; $gmaps_step" 2>&1)"
check "gmaps: a crash prints the exit line" "$(printf '%s\n' "$leak" | grep -c '^exit=2 gmaps scraper failed$')" 1
check "gmaps: a crash prints no name, street or address" "$(printf '%s\n' "$leak" | grep -cE 'Acme|Test St|@')" 0
rm -rf "${repo:?}/.test-gmaps"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# Offline check that the OJ jobs print no row data into this public repo's Actions log on a failure:
# every log tail goes through the job's SAFE_LINES allow-list, and that list drops name and site lines
# while keeping the error and count lines a failed run needs.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS: $1"; else fail=$((fail+1)); echo "FAIL: $1 (got $2, want $3)"; fi; }

first_filter=""
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
  cut="$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1])).get("env",{}).get("SAFE_CUT",""))' "$wf")"
  check "$name: defines SAFE_CUT" "$([ -n "$cut" ] && echo yes || echo no)" yes
  [ -n "$first_filter" ] || first_filter="$pattern|$cut"
  check "$name: the filter is the one every job uses" "$pattern|$cut" "$first_filter"
  check "$name: every filtered tail is cut" "$(grep -c '{ grep -E "\$SAFE_LINES" || true; } |.*sed -E "\$SAFE_CUT"' "$wf")" "$tails"
  filtered() { { grep -E "$pattern" || true; } | sed -E "$cut"; }
  # The exact lines the scripts print, one per kept shape; each must come out byte for byte.
  while IFS= read -r line; do
    check "$name: kept whole: $line" "$(printf '%s\n' "$line" | filtered)" "$line"
  done <<'KEEP'
Traceback (most recent call last):
  File "/home/runner/work/core/scripts/oj-source-overture.py", line 12, in main
  File "<frozen runpy>", line 198, in _run_module_as_main
exit=2
exit=1 gmaps scraper failed
exit=2 gmaps scraper timed out after 3600 s
exit=2 gmaps scraper wrote no output
exit=3 gmaps scraper returned 0 places for 8 queries
exit=2 bad depth
HTTP 403
D1 statements this run: 4
found=1 written=1 write_failed=0 skipped=1 dnc=1
wrote 12 new businesses into the OpsJuice pool
read 40 rows carrying a fit and no verdict
read 200 queued rows after ; 12 due a quote; skipped 3; site_read 9, no_website 3 (apply=True)
read 200 queued rows after 4f1c-9a_2; 0 due a quote; skipped 0; none (apply=False)
read 200 queued or unscreened rows after 4f1c; 12 owed a screen; 3 held for the quote step (site read, quote, then screen)
end of the queued rows
end of the queued and unscreened rows
refused: --after-id must be a row id
refused: --batch must be 1 to 500
{"probed": 3, "verdicts": {"deliverable": 2, "unknown": 1}, "written": 3, "applied": true}
KEEP
  # Error lines keep the type and the fixed diagnosis, never the free text after the colon.
  check "$name: read budget keeps its diagnosis" "$(printf '%s\n' 'oj_d1.D1Error: daily read budget reached: 4954142 of 4500000 rows read today' | filtered)" 'oj_d1.D1Error daily read budget reached'
  check "$name: write budget keeps its diagnosis" "$(printf '%s\n' 'oj_d1.D1Error: daily write budget reached: 91000 of 90000 rows' | filtered)" 'oj_d1.D1Error daily write budget reached'
  check "$name: write cap keeps its diagnosis" "$(printf '%s\n' 'oj_d1.D1Error: per-run write cap reached: 2000 of 2000 rows' | filtered)" 'oj_d1.D1Error per-run write cap reached'
  check "$name: an exception is cut to its type" "$(printf '%s\n' "KeyError: 'Acme Plumbing'" | filtered)" KeyError
  check "$name: SystemExit is cut to its type" "$(printf '%s\n' 'SystemExit: Acme Plumbing' | filtered)" SystemExit
  check "$name: error: is cut to the word" "$(printf '%s\n' 'error: Acme Plumbing 555 0100' | filtered)" error
  check "$name: fatal: is cut to the word" "$(printf '%s\n' 'fatal: Acme Plumbing' | filtered)" fatal
  check "$name: warning: is cut to the word" "$(printf '%s\n' 'warning: Acme Plumbing' | filtered)" warning
  # Every prefix the old list accepted, followed by a name. None may survive, in any case.
  attacks="$(filtered <<'ATTACK'
exit=2 Acme Plumbing
exit=2 gmaps scraper acme plumbing
found=1 Acme Plumbing
found=1 written=1 write_failed=0 skipped=1 dnc=1 Acme Plumbing
wrote 3 Acme Plumbing
wrote 3 new businesses into the OpsJuice pool Acme
read 3 Acme Plumbing
read 3 judged businesses off acme.example, matched 1 to a row, 2 unmatched
read 1 queued rows after x; 1 due a quote; skipped 0; acme plumbing (apply=True)
read 1 queued rows after Acme Plumbing; 1 due a quote; skipped 0; none (apply=True)
HTTP 403 Acme Plumbing
D1 statements Acme
D1 statements this run: 4 Acme
end of the queued Acme
end of the queued rows Acme
Traceback Acme Plumbing
  File "Acme Plumbing", line 3
  File "/a.py", line 3, in Acme Plumbing
ValueError Acme Plumbing
errors Acme Plumbing
warning Acme Plumbing
refused: Acme Plumbing
someone@acme.example
https://acme.example
{"probed": 1, "verdicts": {"Acme Plumbing": 1}, "written": 1, "applied": true}
{"probed": 1, "email": "someone@acme.example"}
ATTACK
)"
  check "$name: no name, site or address survives" "$(printf '%s\n' "$attacks" | grep -ciE 'acme|@')" 0
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
  SAFE_LINES="$gmaps_pattern" SAFE_CUT="$gmaps_cut" RUNNER_TEMP="$dir" FAKE="$dir/fake.sh" bash -c "$gmaps_step" >/dev/null 2>&1
  echo $?
}
check "gmaps: the scraper's telemetry is off" "$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["jobs"]["gmaps"]["env"].get("DISABLE_TELEMETRY"))' "$gmaps_wf")" 1
gmaps_pattern="$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1])).get("env",{}).get("SAFE_LINES",""))' "$gmaps_wf")"
gmaps_cut="$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1])).get("env",{}).get("SAFE_CUT",""))' "$gmaps_wf")"
check "gmaps: empty scrape exits 4" "$(gmaps_case '{"queries": 8, "places": 0, "inserted": 0}' 0)" 4
check "gmaps: good scrape exits 0" "$(gmaps_case '{"queries": 8, "places": 31, "inserted": 12}' 0)" 0
check "gmaps: exit 0 with no counts line exits 5" "$(gmaps_case 'Metros today: 3' 0)" 5
check "gmaps: a crash keeps the script's exit code" "$(gmaps_case 'exit=2 gmaps scraper timed out after 3600 s' 2)" 2
# Reuses the exit-2 fake the crash case above wrote; only the log changes.
leak="$(SAFE_LINES="$gmaps_pattern" SAFE_CUT="$gmaps_cut" RUNNER_TEMP="$repo/.test-gmaps" FAKE="$repo/.test-gmaps/fake.sh" bash -c \
  "printf '%s\n' 'someone@example.invalid' 'Acme Plumbing 12 Test St' 'exit=2 gmaps scraper failed' > \"\$RUNNER_TEMP/log.txt\"; $gmaps_step" 2>&1)"
check "gmaps: a crash prints the exit line" "$(printf '%s\n' "$leak" | grep -c '^exit=2 gmaps scraper failed$')" 1
check "gmaps: a crash prints no name, street or address" "$(printf '%s\n' "$leak" | grep -cE 'Acme|Test St|@')" 0
rm -rf "${repo:?}/.test-gmaps"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]

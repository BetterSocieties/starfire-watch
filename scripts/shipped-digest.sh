#!/usr/bin/env bash
# Cloud shipped-digest: tells the note-writer what shipped in starfire-core over
# the last N minutes. Runs on GitHub Actions cron; no Mac dependency. Sends
# nothing at all when nothing substantive shipped.
#
# This is the copy that actually runs. The Mac launchd job it replaced was
# retired on 2026-07-15 (the plist is still on disk renamed
# .migrated-to-cloud-2026-07-15), so anything fixed only in starfire-core's copy
# of this script changes nothing that Adrien can see. Fix both, or fix this one.
#
# Two things were wrong here on 31 July, and together they wrote him a note
# saying nothing had shipped during a half hour in which three things had.
#
#   1. Whether to send and how much shipped were two different sums. The send
#      decision asked "is anything left after the housekeeping filter", and the
#      count asked "how many lines got a dash in front of them", and only eight
#      hand-listed commit types ever got a dash. A window whose work was all
#      refactor/perf/ea work passed the first question and scored zero on the
#      second. There is now one list, and the count is its length, so the two
#      cannot disagree again.
#   2. It sent a finished block of text, and the note-writer on the other side
#      now expects the facts. It recovered what it could from the text, which
#      was only the dashed lines, so the miscount above turned into an empty
#      note. It now sends the facts, which is what that side reads first.
#
# Compliance_entity: Echo Collective LLC. Compliance_address: 8 East 96th Street.
set -uo pipefail

WINDOW_MIN=${WINDOW_MIN:-45}
HOOK_URL="https://n8n.opsjuice.com/webhook/starfire-shipped-digest"

cd core || { echo "core checkout missing"; exit 1; }

# The prefix strip takes any short type token, with or without a scope in
# brackets, rather than the eight that happened to be listed when this was
# written. An unrecognised type used to survive the strip and then fail to be
# counted, which is the whole of failure 1 above.
lines=$(git log --format='%s' --since="$WINDOW_MIN minutes ago" \
  | grep -ivE '^(state:|archive:|obsidian:|chore: eval|chore: log|merge |index on|WIP on|cloud-tick:|heartbeat)' \
  | sed -E 's/^[A-Za-z][A-Za-z0-9_.-]*(\([^)]*\))?!?:[[:space:]]*//' \
  | sed -E 's/^[[:space:]]*[-*][[:space:]]*//' \
  | grep -v '^[[:space:]]*$' \
  | head -12)

if [ -z "$lines" ]; then
  echo "no substantive commits in last ${WINDOW_MIN}m, sending nothing"
  exit 0
fi

# One list, one count. Never a second way of measuring the same thing.
count=$(printf '%s\n' "$lines" | grep -c .)
echo "sending ${count} items from the last ${WINDOW_MIN}m"

python3 - "$HOOK_URL" "$WINDOW_MIN" "$count" "$lines" <<'PYEOF'
import json, sys, urllib.request
url, window, count, blob = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
lines = [l.strip() for l in blob.split("\n") if l.strip()]
if not lines:
    print("nothing to send")
    raise SystemExit(0)
body = {"window_minutes": window, "count": count, "lines": lines}
req = urllib.request.Request(
    url,
    data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json", "User-Agent": "starfire-digest-cloud"},
)
print(urllib.request.urlopen(req, timeout=15).status)
PYEOF

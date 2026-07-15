#!/usr/bin/env bash
# Cloud shipped-digest: posts substantive starfire-core commits from the last N
# minutes to Slack via the n8n webhook. Runs on GitHub Actions cron; no Mac
# dependency. Silent when no substantive commits (housekeeping filtered out).
# Compliance_entity: Echo Collective LLC. Compliance_address: 8 East 96th Street.
set -uo pipefail

WINDOW_MIN=${WINDOW_MIN:-45}
HOOK_URL="https://n8n.opsjuice.com/webhook/starfire-shipped-digest"

cd core || { echo "core checkout missing"; exit 1; }

lines=$(git log --format='%s' --since="$WINDOW_MIN minutes ago" \
  | grep -ivE '^(state:|archive:|obsidian:|chore: eval|chore: log|merge |index on|WIP on)' \
  | sed -E 's/^(feat|fix|docs|tasks|qa|log|oversight|exec\[[^]]*\])[(:][^:]*:?\s*/- /; s/^- ?-? ?/- /' \
  | head -12)

if [ -z "$lines" ]; then
  echo "no substantive commits in last ${WINDOW_MIN}m"
  exit 0
fi

count=$(echo "$lines" | grep -c '^- ')
text="Starfire shipped (cloud digest, last ${WINDOW_MIN}m, ${count} items):
$lines
Live board: https://starfireos.pages.dev/progress"

python3 - "$HOOK_URL" "$text" <<'PYEOF'
import json, sys, urllib.request
url, text = sys.argv[1], sys.argv[2]
req = urllib.request.Request(
    url,
    data=json.dumps({"text": text}).encode(),
    headers={"Content-Type": "application/json", "User-Agent": "starfire-digest-cloud"},
)
print(urllib.request.urlopen(req, timeout=15).status)
PYEOF

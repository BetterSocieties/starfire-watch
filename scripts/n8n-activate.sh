#!/usr/bin/env bash
# Activate every workflow on the n8n pod. These workflows use no n8n credential
# objects (verified), so activation needs only the pod API key. Idempotent.
# On failure, captures the API error body and buckets it (missing-cred /
# webhook-collision / other) so failures are diagnosable without re-running
# by hand. Writes data/n8n-activate-report.json for the caller to commit.
set -uo pipefail
N8N_URL="${N8N_URL:?}"; N8N_API_KEY="${N8N_API_KEY:?}"
API="$N8N_URL/api/v1"; H=(-H "X-N8N-API-KEY: $N8N_API_KEY" -H "Content-Type: application/json")
ok=0; already=0; fail=0
cred_fail=0; webhook_fail=0; other_fail=0
cursor=""
ids=$(mktemp)
# page through all workflows (id, active, name)
while :; do
  if [ -z "$cursor" ]; then resp=$(curl -sf "${H[@]}" "$API/workflows?limit=250"); else resp=$(curl -sf "${H[@]}" "$API/workflows?limit=250&cursor=$cursor"); fi
  echo "$resp" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for w in d.get('data', []):
    name = (w.get('name') or '').replace(chr(9), ' ').replace(chr(10), ' ')
    print(f\"{w['id']}\t{w.get('active')}\t{name}\")
" >> "$ids"
  cursor=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('nextCursor') or '')")
  [ -z "$cursor" ] && break
done
total=$(wc -l < "$ids")
echo "workflows on pod: $total"

failures_jsonl=$(mktemp)
: > "$failures_jsonl"

while IFS=$'\t' read -r id active name; do
  [ -z "$id" ] && continue
  if [ "$active" = "True" ] || [ "$active" = "true" ]; then already=$((already+1)); continue; fi
  code=$(curl -s -o /tmp/act.out -w '%{http_code}' "${H[@]}" -X POST "$API/workflows/$id/activate")
  respbody=$(cat /tmp/act.out)
  if [ "$code" = "200" ]; then
    ok=$((ok+1))
  else
    fail=$((fail+1))
    lc=$(echo "$respbody" | tr '[:upper:]' '[:lower:]')
    if echo "$lc" | grep -qE 'credential'; then
      bucket="missing-cred"; cred_fail=$((cred_fail+1))
    elif echo "$lc" | grep -qE 'webhook|already registered|duplicate|path.*(exist|use)'; then
      bucket="webhook-collision"; webhook_fail=$((webhook_fail+1))
    else
      bucket="other"; other_fail=$((other_fail+1))
    fi
    python3 -c "
import json, sys
print(json.dumps({
    'id': sys.argv[1], 'name': sys.argv[2], 'http_code': sys.argv[3],
    'bucket': sys.argv[4], 'message': sys.argv[5][:300],
}))
" "$id" "$name" "$code" "$bucket" "$respbody" >> "$failures_jsonl"
  fi
done < "$ids"

echo "ACTIVATE RESULT: newly_activated=$ok already_active=$already failed=$fail total=$total"
echo "FAILURE BUCKETS: missing-cred=$cred_fail webhook-collision=$webhook_fail other=$other_fail"
[ "$fail" -gt 0 ] && echo "sample failures:" && head -5 "$failures_jsonl"

mkdir -p data
python3 -c "
import json, sys
from datetime import datetime, timezone

failures = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            failures.append(json.loads(line))

report = {
    'generated_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'total': int(sys.argv[2]),
    'newly_activated': int(sys.argv[3]),
    'already_active': int(sys.argv[4]),
    'failed': int(sys.argv[5]),
    'buckets': {
        'missing_cred': int(sys.argv[6]),
        'webhook_collision': int(sys.argv[7]),
        'other': int(sys.argv[8]),
    },
    'failures': failures,
}
with open('data/n8n-activate-report.json', 'w') as f:
    json.dump(report, f, indent=2)
    f.write('\n')
" "$failures_jsonl" "$total" "$ok" "$already" "$fail" "$cred_fail" "$webhook_fail" "$other_fail"

# fire 2026-07-13T21:48:17Z

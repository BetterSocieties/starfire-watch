#!/usr/bin/env bash
# Diagnostic: fetch a known-brain workflow by name and dump its node credentials
# to answer whether POST /workflows preserved credential refs or stripped them.
set -uo pipefail
N8N_URL="${N8N_URL:?}"; N8N_API_KEY="${N8N_API_KEY:?}"
API="$N8N_URL/api/v1"; H=(-H "X-N8N-API-KEY: $N8N_API_KEY")
for name in "OpsJuice Cold Outreach (Phase 1)" "BS-Cold-Outreach-Engine" "OJ-Assessment-Engine"; do
  echo "== $name"
  id=$(curl -sf --max-time 20 "${H[@]}" "$API/workflows?limit=250" | python3 -c "import json,sys; d=json.load(sys.stdin); print([w['id'] for w in d['data'] if w['name']=='$name'][:1][0] if [w for w in d['data'] if w['name']=='$name'] else '')")
  if [ -z "$id" ]; then
    # paginate
    cursor=""; while :; do
      r=$(curl -sf --max-time 20 "${H[@]}" "$API/workflows?limit=250${cursor:+&cursor=$cursor}")
      id=$(echo "$r" | python3 -c "import json,sys; d=json.load(sys.stdin); m=[w['id'] for w in d['data'] if w['name']=='$name']; print(m[0] if m else '')")
      [ -n "$id" ] && break
      cursor=$(echo "$r" | python3 -c "import json,sys; print(json.load(sys.stdin).get('nextCursor') or '')")
      [ -z "$cursor" ] && break
    done
  fi
  echo "id=$id"
  [ -z "$id" ] && continue
  curl -s --max-time 20 "${H[@]}" "$API/workflows/$id" | python3 -c "
import json,sys
w=json.load(sys.stdin)
print('name:', w.get('name'), 'active:', w.get('active'))
for n in w.get('nodes', []):
    creds = n.get('credentials')
    if creds:
        print(' node', n.get('name'), 'creds:', json.dumps(creds))
"
done

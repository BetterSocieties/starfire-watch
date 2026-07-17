#!/bin/bash
# One-shot: POST the DRAFT-OJ-Abandoned-Checkout-Recovery workflow to pod (active=false),
# then PATCH to active=true if a --activate arg is present. Idempotent: skip if a workflow
# with the same name already exists.
set -uo pipefail
: "${N8N_API_KEY:?}"; : "${N8N_URL:?}"
API="${N8N_URL%/}/api/v1"
NAME="OJ-Abandoned-Checkout-Recovery"
H=(-H "X-N8N-API-KEY: $N8N_API_KEY" -H "User-Agent: Mozilla/5.0" -H "Content-Type: application/json")
SRC="core/ventures/opsjuice/system-export/DRAFT-OJ-Abandoned-Checkout-Recovery.json"
[ -f "$SRC" ] || { echo "missing $SRC"; exit 1; }

echo "== check if workflow exists"
LIST=$(curl -sS --max-time 30 "${H[@]}" "$API/workflows?limit=250" | python3 -c "
import json, sys
d=json.load(sys.stdin).get('data', [])
for w in d:
    if w.get('name')=='OJ-Abandoned-Checkout-Recovery':
        print(w['id']); break")
if [ -n "$LIST" ]; then
  echo "already exists id=$LIST — no POST"
  echo "existing_id=$LIST"
  exit 0
fi

echo "== POST workflow"
BODY=$(python3 -c "
import json,sys
d=json.load(open('$SRC'))
# n8n POST accepts only these fields
out={k:d[k] for k in ('name','nodes','connections','settings','staticData') if k in d}
sys.stdout.write(json.dumps(out))")
CODE=$(echo "$BODY" | curl -s -o /tmp/post.out -w "%{http_code}" -X POST "${H[@]}" --data-binary @- "$API/workflows")
echo "post http_code=$CODE"
head -c 400 /tmp/post.out
echo ""
if [ "$CODE" = "200" ] || [ "$CODE" = "201" ]; then
  NEW_ID=$(python3 -c "import json; print(json.load(open('/tmp/post.out'))['id'])")
  echo "created_id=$NEW_ID"
  echo "== verify GET"
  curl -sS --max-time 20 "${H[@]}" "$API/workflows/$NEW_ID" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('name:', d.get('name'), 'active:', d.get('active'), 'nodes:', len(d.get('nodes',[])))"
fi

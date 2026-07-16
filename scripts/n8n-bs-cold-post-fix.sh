#!/bin/bash
# One-shot: patch BS-Cold-Outreach-Engine (OLS9DHyDUOx6vCM2) trigger httpMethod GET->POST.
# Runs on GitHub Actions runner where N8N_API_KEY is present.
set -euo pipefail
: "${N8N_API_KEY:?}"
: "${N8N_URL:?}"
API="${N8N_URL%/}"
WF="OLS9DHyDUOx6vCM2"
H=(-H "X-N8N-API-KEY: $N8N_API_KEY" -H "User-Agent: Mozilla/5.0" -H "Content-Type: application/json")

echo "== GET workflow"
CUR=$(curl -sS --fail --max-time 30 "${H[@]}" "$API/workflows/$WF")
echo "$CUR" | python3 -c "import json,sys;d=json.load(sys.stdin);print('trigger httpMethod current:',[n.get('parameters',{}).get('httpMethod') for n in d['nodes'] if n['type']=='n8n-nodes-base.webhook'])"

echo "== patch nodes[webhook].parameters.httpMethod = POST + strip pod-managed fields"
PATCHED=$(echo "$CUR" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for n in d["nodes"]:
    if n["type"]=="n8n-nodes-base.webhook":
        n.setdefault("parameters",{})["httpMethod"]="POST"
# pod PUT only accepts these fields (n8n API contract):
out={k:d[k] for k in ("name","nodes","connections","settings","staticData") if k in d}
sys.stdout.write(json.dumps(out))')
echo "patched bytes: $(echo -n "$PATCHED" | wc -c)"

echo "== PUT workflow"
CODE=$(echo "$PATCHED" | curl -s -o /tmp/put.out -w "%{http_code}" -X PUT "${H[@]}" --data-binary @- "$API/workflows/$WF")
echo "put http_code=$CODE"
cat /tmp/put.out | head -c 300
echo ""

echo "== re-GET to confirm"
curl -sS --max-time 20 "${H[@]}" "$API/workflows/$WF" | python3 -c "import json,sys;d=json.load(sys.stdin);print('trigger httpMethod after:',[n.get('parameters',{}).get('httpMethod') for n in d['nodes'] if n['type']=='n8n-nodes-base.webhook'])"

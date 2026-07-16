#!/bin/bash
set -uo pipefail
: "${N8N_API_KEY:?}"
: "${N8N_URL:?}"
API="${N8N_URL%/}/api/v1"
WF="OLS9DHyDUOx6vCM2"
H=(-H "X-N8N-API-KEY: $N8N_API_KEY" -H "User-Agent: Mozilla/5.0" -H "Content-Type: application/json")

echo "== GET workflow"
GET_CODE=$(curl -sS -o /tmp/wf.json -w "%{http_code}" --max-time 30 "${H[@]}" "$API/workflows/$WF")
echo "get http_code=$GET_CODE size=$(wc -c </tmp/wf.json) headline=$(head -c 80 /tmp/wf.json)"
[ "$GET_CODE" = "200" ] || { echo "GET failed"; exit 1; }

echo "== patch nodes[webhook].parameters.httpMethod = POST"
python3 <<'PY' > /tmp/wf-patched.json
import json
d=json.load(open("/tmp/wf.json"))
found=[]
for n in d["nodes"]:
    if n["type"]=="n8n-nodes-base.webhook":
        n.setdefault("parameters",{})["httpMethod"]="POST"
        found.append(n["name"])
import sys
sys.stderr.write(f"patched triggers: {found}\n")
# pod PUT accepts only these fields per n8n API contract
out={k:d[k] for k in ("name","nodes","connections","settings","staticData") if k in d}
json.dump(out, sys.stdout)
PY
echo "patched size: $(wc -c </tmp/wf-patched.json)"

echo "== PUT workflow"
PUT_CODE=$(curl -s -o /tmp/put.out -w "%{http_code}" -X PUT "${H[@]}" --data-binary @/tmp/wf-patched.json "$API/workflows/$WF")
echo "put http_code=$PUT_CODE"
head -c 300 /tmp/put.out; echo ""

echo "== re-GET"
curl -sS --max-time 20 "${H[@]}" "$API/workflows/$WF" | python3 -c "import json,sys;d=json.load(sys.stdin);print('after httpMethods:',[n.get('parameters',{}).get('httpMethod') for n in d['nodes'] if n['type']=='n8n-nodes-base.webhook'])"

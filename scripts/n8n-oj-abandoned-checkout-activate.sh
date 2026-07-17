#!/bin/bash
set -uo pipefail
: "${N8N_API_KEY:?}"; : "${N8N_URL:?}"
API="${N8N_URL%/}/api/v1"
WF="Zr4tUUufIJxyV1hB"
H=(-H "X-N8N-API-KEY: $N8N_API_KEY" -H "User-Agent: Mozilla/5.0" -H "Content-Type: application/json")
echo "== BEFORE"
curl -sS --max-time 20 "${H[@]}" "$API/workflows/$WF" | python3 -c "import json,sys;d=json.load(sys.stdin);print('name:',d.get('name'),'active:',d.get('active'))"
echo "== POST activate"
CODE=$(curl -s -o /tmp/act.out -w "%{http_code}" -X POST "${H[@]}" "$API/workflows/$WF/activate")
echo "activate http_code=$CODE"; head -c 200 /tmp/act.out; echo ""
echo "== AFTER"
curl -sS --max-time 20 "${H[@]}" "$API/workflows/$WF" | python3 -c "import json,sys;d=json.load(sys.stdin);print('name:',d.get('name'),'active:',d.get('active'))"

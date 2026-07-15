#!/usr/bin/env bash
set -uo pipefail
N8N_URL="${N8N_URL:?}"; N8N_API_KEY="${N8N_API_KEY:?}"
MODE="${MODE:?}"; WF_ID="${WF_ID:?}"
API="$N8N_URL/api/v1"
H=(-H "X-N8N-API-KEY: $N8N_API_KEY" -H "Content-Type: application/json")

get() {
  echo "== GET /workflows/$WF_ID"
  code=$(curl -s --max-time 20 -o /tmp/wf.out -w '%{http_code}' "${H[@]}" "$API/workflows/$WF_ID")
  echo "http_code=$code"
  cat /tmp/wf.out
}

if [ "$MODE" = "get" ]; then
  get
elif [ "$MODE" = "put" ]; then
  STAGE="data/n8n-staged/$WF_ID.json"
  if [ ! -f "$STAGE" ]; then echo "missing staged file $STAGE"; exit 1; fi
  echo "== PUT /workflows/$WF_ID from $STAGE"
  code=$(curl -s --max-time 20 -o /tmp/wf-put.out -w '%{http_code}' -X PUT "${H[@]}" --data-binary @"$STAGE" "$API/workflows/$WF_ID")
  echo "http_code=$code"
  cat /tmp/wf-put.out
  echo "== re-GET to confirm"
  get
else
  echo "MODE must be get or put"; exit 1
fi

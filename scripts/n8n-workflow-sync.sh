#!/usr/bin/env bash
set -uo pipefail
N8N_URL="${N8N_URL:?}"; N8N_API_KEY="${N8N_API_KEY:?}"
MODE="${MODE:?}"; WF_ID="${WF_ID:-}"
API="$N8N_URL/api/v1"
H=(-H "X-N8N-API-KEY: $N8N_API_KEY" -H "Content-Type: application/json")

get() {
  echo "== GET /workflows/$WF_ID"
  code=$(curl -s --max-time 20 -o /tmp/wf.out -w '%{http_code}' "${H[@]}" "$API/workflows/$WF_ID")
  echo "http_code=$code"
  # gh run log drops very long single-line output; persist the JSON to the repo instead
  mkdir -p data/n8n-fetched
  cp /tmp/wf.out "data/n8n-fetched/$WF_ID.json"
  python3 -c "import json;d=json.load(open('/tmp/wf.out'));print('name:',d.get('name'),'active:',d.get('active'),'nodes:',len(d.get('nodes',[])))"
}

list() {
  echo "== GET /workflows (id + name only)"
  cursor=""
  while :; do
    url="$API/workflows?limit=250"
    [ -n "$cursor" ] && url="$url&cursor=$cursor"
    resp=$(curl -s --max-time 20 "${H[@]}" "$url")
    echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(w["id"], "|", w["name"]) for w in d.get("data",[])]'
    cursor=$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("nextCursor") or "")')
    [ -z "$cursor" ] && break
  done
}

find_term() {
  echo "== scanning all workflows for '$SEARCH'"
  cursor=""
  while :; do
    url="$API/workflows?limit=250"
    [ -n "$cursor" ] && url="$url&cursor=$cursor"
    resp=$(curl -s --max-time 20 "${H[@]}" "$url")
    echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(w["id"]) for w in d.get("data",[])]' > /tmp/ids.txt
    while read -r id; do
      [ -z "$id" ] && continue
      body=$(curl -s --max-time 20 "${H[@]}" "$API/workflows/$id")
      if echo "$body" | grep -q "$SEARCH"; then
        name=$(echo "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("name"), "| active=", d.get("active"))')
        echo "MATCH $id | $name"
      fi
    done < /tmp/ids.txt
    cursor=$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("nextCursor") or "")')
    [ -z "$cursor" ] && break
  done
}

if [ "$MODE" = "get" ]; then
  get
elif [ "$MODE" = "list" ]; then
  list
elif [ "$MODE" = "find" ]; then
  SEARCH="${SEARCH:?}"
  find_term
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

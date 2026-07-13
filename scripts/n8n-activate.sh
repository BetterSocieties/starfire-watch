#!/usr/bin/env bash
# Activate every workflow on the n8n pod. These workflows use no n8n credential
# objects (verified), so activation needs only the pod API key. Idempotent.
set -uo pipefail
N8N_URL="${N8N_URL:?}"; N8N_API_KEY="${N8N_API_KEY:?}"
API="$N8N_URL/api/v1"; H=(-H "X-N8N-API-KEY: $N8N_API_KEY" -H "Content-Type: application/json")
ok=0; already=0; fail=0; failed_ids=""
cursor=""
ids=$(mktemp)
# page through all workflows
while :; do
  if [ -z "$cursor" ]; then resp=$(curl -sf "${H[@]}" "$API/workflows?limit=250"); else resp=$(curl -sf "${H[@]}" "$API/workflows?limit=250&cursor=$cursor"); fi
  echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); [print(w['id'], w.get('active')) for w in d.get('data',[])]" >> "$ids"
  cursor=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('nextCursor') or '')")
  [ -z "$cursor" ] && break
done
total=$(wc -l < "$ids")
echo "workflows on pod: $total"
while read -r id active; do
  [ -z "$id" ] && continue
  if [ "$active" = "True" ] || [ "$active" = "true" ]; then already=$((already+1)); continue; fi
  code=$(curl -s -o /tmp/act.out -w '%{http_code}' "${H[@]}" -X POST "$API/workflows/$id/activate")
  if [ "$code" = "200" ]; then ok=$((ok+1)); else fail=$((fail+1)); failed_ids="$failed_ids $id"; fi
done < "$ids"
echo "ACTIVATE RESULT: newly_activated=$ok already_active=$already failed=$fail total=$total"
[ "$fail" -gt 0 ] && echo "first failures:$(echo $failed_ids | tr ' ' '\n' | head -5 | tr '\n' ' ')"
echo "(failures usually mean a workflow needs a service key inside an HTTP node, or a duplicate webhook path; reported for follow-up)"

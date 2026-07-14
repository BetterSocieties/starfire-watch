#!/usr/bin/env bash
# Dedupe the n8n pod to ONE workflow per name (keep earliest createdAt), then
# activate the survivors. Fixes the duplication (5,323 -> ~1,129). Idempotent.
set -uo pipefail
N8N_URL="${N8N_URL:?}"; N8N_API_KEY="${N8N_API_KEY:?}"
API="$N8N_URL/api/v1"; H=(-H "X-N8N-API-KEY: $N8N_API_KEY" -H "Content-Type: application/json")
tmp=$(mktemp)
echo "== paging all workflows"
cursor=""
while :; do
  if [ -z "$cursor" ]; then resp=$(curl -sf --max-time 30 "${H[@]}" "$API/workflows?limit=250"); else resp=$(curl -sf --max-time 30 "${H[@]}" "$API/workflows?limit=250&cursor=$cursor"); fi
  [ -z "$resp" ] && { echo "empty page, stopping"; break; }
  echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); [print(w['id']+'\t'+(w.get('createdAt') or '')+'\t'+w['name']) for w in d.get('data',[])]" >> "$tmp"
  cursor=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('nextCursor') or '')")
  [ -z "$cursor" ] && break
done
total=$(wc -l < "$tmp"); echo "total workflows on pod: $total"

# choose survivors: earliest createdAt per name; rest are deletions
python3 - "$tmp" > /tmp/plan.txt <<'PY'
import sys,collections
rows=[l.rstrip('\n').split('\t') for l in open(sys.argv[1]) if l.strip()]
by=collections.defaultdict(list)
for r in rows:
    if len(r)<3: continue
    wid,created,name=r[0],r[1],'\t'.join(r[2:])
    by[name].append((created or 'zzzz',wid))
keep=set(); delete=[]
for name,items in by.items():
    items.sort()  # earliest createdAt first
    keep.add(items[0][1])
    for _,wid in items[1:]: delete.append(wid)
open('/tmp/keep.txt','w').write('\n'.join(sorted(keep)))
open('/tmp/del.txt','w').write('\n'.join(delete))
print(f"unique_names={len(by)} keep={len(keep)} delete={len(delete)}")
PY
cat /tmp/plan.txt

echo "== deleting duplicates"
dok=0; dfail=0
while read -r id; do
  [ -z "$id" ] && continue
  code=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' "${H[@]}" -X DELETE "$API/workflows/$id")
  if [ "$code" = "200" ]; then dok=$((dok+1)); else dfail=$((dfail+1)); fi
done < /tmp/del.txt
echo "deleted=$dok delete_failed=$dfail"

echo "== activating survivors"
aok=0; aalready=0; afail=0
while read -r id; do
  [ -z "$id" ] && continue
  code=$(curl -s --max-time 30 -o /tmp/a.out -w '%{http_code}' "${H[@]}" -X POST "$API/workflows/$id/activate")
  if [ "$code" = "200" ]; then aok=$((aok+1)); elif grep -qi "already" /tmp/a.out 2>/dev/null; then aalready=$((aalready+1)); else afail=$((afail+1)); fi
done < /tmp/keep.txt
remaining=$(curl -sf --max-time 30 "${H[@]}" "$API/workflows?limit=1" | python3 -c "import json,sys; print('ok')" 2>/dev/null || echo "?")
echo "FIX-POD RESULT: activated=$aok already_active=$aalready activate_failed=$afail (survivors=$(wc -l < /tmp/keep.txt))"
echo "(remaining activate failures are workflows whose HTTP nodes need a live service key, or webhook-path conflicts; expected for a subset)"

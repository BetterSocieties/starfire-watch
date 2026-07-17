#!/bin/bash
# One-shot: swap canonical 3-tier upsell email HTML into pod workflow 2oxtWXaeRhCsbdJp.
# Canonical source: core/ventures/opsjuice/emails/upsell-three-tiers.html (checked out by the Action).
# Compliance: the canonical email carries the CAN-SPAM footer (Echo Collective LLC, 8 East 96th Street,
# New York, NY 10128 + unsubscribe); this script only transplants that compliant HTML into the engine.
set -uo pipefail
: "${N8N_API_KEY:?}"; : "${N8N_URL:?}"
API="${N8N_URL%/}/api/v1"
WF="J3gQgu1QffAAaLrA"
H=(-H "X-N8N-API-KEY: $N8N_API_KEY" -H "User-Agent: Mozilla/5.0" -H "Content-Type: application/json")
SRC="core/ventures/opsjuice/emails/upsell-three-tiers.html"
[ -f "$SRC" ] || { echo "missing $SRC"; exit 1; }
grep -q "8 East 96th" "$SRC" || { echo "canonical email missing CAN-SPAM footer"; exit 1; }

echo "== GET workflow"
GET_CODE=$(curl -sS -o /tmp/wf.json -w "%{http_code}" --max-time 30 "${H[@]}" "$API/workflows/$WF")
echo "get http_code=$GET_CODE size=$(wc -c </tmp/wf.json)"
[ "$GET_CODE" = "200" ] || exit 1

echo "== node census"
python3 - <<'CENSUS'
import json
d = json.load(open("/tmp/wf.json"))
for n in d["nodes"]:
    params = n.get("parameters", {})
    keys = list(params.keys())
    blob = json.dumps(params)
    marks = [w for w in ("html","upsell","1,500","3,500","7,500","stripe","cal.com","subject","message") if w in blob.lower()]
    print(f"NODE {n.get('name','?')[:44]!r} type={n['type'].split('.')[-1]} keys={keys[:5]} marks={marks}")
CENSUS

echo "== patch upsell email node"
python3 - "$SRC" <<'PY' > /tmp/wf-patched.json
import json
import re
import sys

src_html = open(sys.argv[1]).read()
html_only = re.sub(r"^<!--[\s\S]*?-->\s*", "", src_html)
d = json.load(open("/tmp/wf.json"))
hit = []
for n in d["nodes"]:
    params = n.get("parameters", {})
    blob = json.dumps(params)
    name_hit = "upsell" in n.get("name", "").lower()
    content_hit = ("3,500" in blob or "3500" in blob or "retainer" in blob.lower()) and ("html" in blob.lower() or "jsCode" in blob or "message" in blob)
    if not (name_hit or content_hit):
        continue
    if "jsCode" in params:
        code = params["jsCode"]
        esc = (html_only.replace("\\", "\\\\").replace("`", "\\`")
               .replace("${", "\\${").replace("{{first_name}}", "${firstName}"))
        new_code = re.sub(r"(const html = `)[\s\S]*?(`;)",
                          lambda m: m.group(1) + esc + m.group(2), code, count=1)
        if new_code != code:
            params["jsCode"] = new_code
            hit.append(n["name"] + " (jsCode)")
    elif "message" in params:
        params["message"] = html_only.replace("{{first_name}}", "={{ $json.firstName }}")
        hit.append(n["name"] + " (message)")
sys.stderr.write("patched nodes: %s\n" % hit)
out = {k: d[k] for k in ("name", "nodes", "connections", "settings", "staticData") if k in d}
json.dump(out, sys.stdout)
PY
echo "patched size: $(wc -c </tmp/wf-patched.json)"

echo "== PUT workflow"
PUT_CODE=$(curl -s -o /tmp/put.out -w "%{http_code}" -X PUT "${H[@]}" --data-binary @/tmp/wf-patched.json "$API/workflows/$WF")
echo "put http_code=$PUT_CODE"; head -c 200 /tmp/put.out; echo ""

echo "== re-GET confirm"
curl -sS --max-time 20 "${H[@]}" "$API/workflows/$WF" | python3 -c "
import json, sys
d = json.load(sys.stdin)
blob = json.dumps(d)
print('three-tier copy present:', 'Start with Growth' in blob)
print('footer present:', '8 East 96th' in blob)"

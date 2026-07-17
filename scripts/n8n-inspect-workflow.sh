#!/usr/bin/env bash
# Inspect one or more n8n pod workflows by id: dump every executeCommand node's
# command string so an activation failure ("Unrecognized node type:
# n8n-nodes-base.executeCommand") can be root-caused as Mac-local-only
# (SKIP_IDS candidate) vs a real revenue path that needs migrating off
# executeCommand. Writes data/n8n-workflow-inspect.json for the caller to commit.
# Root cause context: TASKS.md row d7b79f2c (OJ-POD-17-REAL-FAILS).
set -uo pipefail
N8N_URL="${N8N_URL:?}"; N8N_API_KEY="${N8N_API_KEY:?}"; WORKFLOW_IDS="${WORKFLOW_IDS:?}"
API="$N8N_URL/api/v1"; H=(-H "X-N8N-API-KEY: $N8N_API_KEY" -H "Content-Type: application/json")

mkdir -p data
results=$(mktemp)
echo "[]" > "$results"

IFS=',' read -ra IDS <<< "$WORKFLOW_IDS"
for id in "${IDS[@]}"; do
  id="$(echo "$id" | xargs)"
  [ -z "$id" ] && continue
  code=$(curl -s -o /tmp/wf.out -w '%{http_code}' "${H[@]}" "$API/workflows/$id")
  echo "GET /workflows/$id -> $code"
  if [ "$code" != "200" ]; then
    python3 -c "
import json
r = json.load(open('$results'))
r.append({'id': '$id', 'http_code': '$code', 'error': open('/tmp/wf.out').read()[:500]})
json.dump(r, open('$results','w'))
"
    continue
  fi
  python3 -c "
import json
d = json.load(open('/tmp/wf.out'))
r = json.load(open('$results'))
nodes = d.get('nodes', [])
exec_nodes = []
for n in nodes:
    if n.get('type') == 'n8n-nodes-base.executeCommand':
        exec_nodes.append({
            'node_name': n.get('name'),
            'command': (n.get('parameters', {}) or {}).get('command', ''),
        })
r.append({
    'id': '$id',
    'name': d.get('name'),
    'active': d.get('active'),
    'total_nodes': len(nodes),
    'node_types': sorted(set(n.get('type') for n in nodes)),
    'node_names': [n.get('name','?') for n in nodes],
    'execute_command_nodes': exec_nodes,
})
json.dump(r, open('$results','w'))
"
done

python3 -c "
import json, sys
from datetime import datetime, timezone
r = json.load(open('$results'))
out = {'generated_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'workflows': r}
json.dump(out, open('data/n8n-workflow-inspect.json', 'w'), indent=2)
open('data/n8n-workflow-inspect.json', 'a').write('\n')
print(json.dumps(out, indent=2))
"

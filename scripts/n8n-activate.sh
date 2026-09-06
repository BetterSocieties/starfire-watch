#!/usr/bin/env bash
# Activate every workflow on the n8n pod. These workflows use no n8n credential
# objects (verified), so activation needs only the pod API key. Idempotent.
# On failure, captures the API error body and buckets it (missing-cred /
# webhook-collision / other) so failures are diagnosable without re-running
# by hand. Writes data/n8n-activate-report.json for the caller to commit.
set -uo pipefail
N8N_URL="${N8N_URL:?}"; N8N_API_KEY="${N8N_API_KEY:?}"
API="$N8N_URL/api/v1"; H=(-H "X-N8N-API-KEY: $N8N_API_KEY" -H "Content-Type: application/json")

# Workflows that use n8n-nodes-base.executeCommand to shell out to Mac-local-only
# resources (whisper binary, graphify CLI, local claude CLI, ~/starfire/brain vault
# filesystem) or are one-time ONESHOT DB/env probes that already served their purpose.
# The cloud pod has no shell/filesystem access to these paths by design (n8n-nodes-base.
# executeCommand does not exist on the pod at all), so POSTing /activate for them can
# never succeed and only pollutes the failure report every 2h cron cycle. Root-caused
# 2026-07-15 per OJ-POD-17-REAL-FAILS: verified via ventures/opsjuice/system-export/*.json
# that every one of these executeCommand nodes references /Users/adrienharrison/... paths
# or is a completed one-off migration/probe. Skipping them here is a reporting-hygiene
# fix only; it does not change their (already-inactive) runtime state.
SKIP_IDS=(
  # ONESHOT-* -- one-time DB/env probes and migrations, already run, no reason to re-activate
  B4La6XsUcgkfm4Ky   # ONESHOT-alter-upsells-final
  6v4sDlkf8RbfnZNS   # ONESHOT-psql-probe-v3
  HC3X71flglZhYRIW   # ONESHOT-psql-probe
  hY1N2hA8GpEdsiaG   # ONESHOT-probe-n8n-server
  iEgh3GEaCBji1B54   # ONESHOT-ddl-via-cmd
  tGNMhEQUqEqzEH61   # ONESHOT-probe-env
  QwEPmdmmS9Erv4d9   # ONESHOT-alter-upsells-v3
  # BRAIN-* -- Mac-local vault/whisper/graphify/claude-CLI automations, belong on the
  # Mac-local brain (localhost:5681) only, not the cloud pod
  2zJcRi6fx7IToe0I   # BRAIN-009 Daily inbox routing 11pm
  8jpZ6TCySKyoan6L   # BRAIN-006 YouTube watch -> vault inbox
  iEMQtBhy1vxERCXQ   # BRAIN-011 Graphify update (decoupled)
  JtLDO1MBFlfNkhN4   # BRAIN-002 Whisper voice transcription to vault inbox
  SBVdLIHUv4Bnb0V5   # BRAIN-007 Daily brief 6am Mon-Fri
  tUxaj0MPS9eCnRpO   # BRAIN-010 Karpathy hook (Sun 2:50am)
  O79usQgsfbmUYY12   # BRAIN-008 Weekly synthesis Mon 6am
  # OJ-POD-17-REAL-FAILS "other" bucket, root-caused 2026-07-15 via the local
  # export copies in starfire-core ventures/opsjuice/system-export/: both
  # contain n8n-nodes-base.executeCommand nodes that write to /tmp and shell
  # out to /Users/adrienharrison/.local/bin/claude -- Mac-local-only, same
  # class as the BRAIN-* entries above. Pod error was identical either way:
  # "Unrecognized node type: n8n-nodes-base.executeCommand" (the node type
  # is not registered on the pod at all, so no content difference could ever
  # make this activate there).
  56KMoa1BAcLc6vgk   # OJ-Assessment-Twilio-Engine
  SxaBrFdnwaX9v7fR   # BS-Compliance-Assessment-Engine
)

# POLICY exclusions (2026-09-06): workflows a person deliberately stopped that this job must
# never turn back on, regardless of pod compatibility. This is a different list from SKIP_IDS
# above for a different reason: SKIP_IDS is about what the pod can run at all, this is about
# what a person decided should stay off. Held in config/never-activate.txt, one file, so it
# can be read and edited without touching this script. See that file for the full reason and
# who may remove an entry.
NEVER_FILE="$(cd "$(dirname "$0")/.." && pwd)/config/never-activate.txt"
NEVER_IDS=()
if [ -f "$NEVER_FILE" ]; then
  while read -r nid _rest; do
    [ -z "$nid" ] && continue
    case "$nid" in \#*) continue ;; esac
    NEVER_IDS+=("$nid")
  done < "$NEVER_FILE"
fi
echo "never-activate policy list: ${#NEVER_IDS[@]} workflow(s)"

ok=0; already=0; fail=0; skipped=0; never=0
cred_fail=0; webhook_fail=0; other_fail=0; notrigger_fail=0
cursor=""
ids=$(mktemp)
# page through all workflows (id, active, name)
while :; do
  if [ -z "$cursor" ]; then resp=$(curl -sf "${H[@]}" "$API/workflows?limit=250"); else resp=$(curl -sf "${H[@]}" "$API/workflows?limit=250&cursor=$cursor"); fi
  echo "$resp" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for w in d.get('data', []):
    name = (w.get('name') or '').replace(chr(9), ' ').replace(chr(10), ' ')
    print(f\"{w['id']}\t{w.get('active')}\t{name}\")
" >> "$ids"
  cursor=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('nextCursor') or '')")
  [ -z "$cursor" ] && break
done
total=$(wc -l < "$ids")
echo "workflows on pod: $total"

failures_jsonl=$(mktemp)
: > "$failures_jsonl"

skipped_jsonl=$(mktemp)
: > "$skipped_jsonl"

while IFS=$'\t' read -r id active name; do
  [ -z "$id" ] && continue
  is_never=0
  for n in "${NEVER_IDS[@]}"; do
    if [ "$id" = "$n" ]; then is_never=1; break; fi
  done
  if [ "$is_never" = "1" ]; then
    never=$((never+1))
    python3 -c "
import json, sys
print(json.dumps({'id': sys.argv[1], 'name': sys.argv[2], 'reason': 'policy: never-activate, see config/never-activate.txt'}))
" "$id" "$name" >> "$skipped_jsonl"
    continue
  fi
  if [ "$active" = "True" ] || [ "$active" = "true" ]; then already=$((already+1)); continue; fi
  is_skip=0
  for s in "${SKIP_IDS[@]}"; do
    if [ "$id" = "$s" ]; then is_skip=1; break; fi
  done
  if [ "$is_skip" = "1" ]; then
    skipped=$((skipped+1))
    python3 -c "
import json, sys
print(json.dumps({'id': sys.argv[1], 'name': sys.argv[2], 'reason': 'mac-local-only or completed oneshot, see SKIP_IDS comment in scripts/n8n-activate.sh'}))
" "$id" "$name" >> "$skipped_jsonl"
    continue
  fi
  code=$(curl -s -o /tmp/act.out -w '%{http_code}' "${H[@]}" -X POST "$API/workflows/$id/activate")
  respbody=$(cat /tmp/act.out)
  if [ "$code" = "200" ]; then
    ok=$((ok+1))
  else
    fail=$((fail+1))
    lc=$(echo "$respbody" | tr '[:upper:]' '[:lower:]')
    if echo "$lc" | grep -qE 'credential'; then
      bucket="missing-cred"; cred_fail=$((cred_fail+1))
    elif echo "$lc" | grep -qE 'no trigger node|cannot be activated because it has no trigger'; then
      bucket="no-trigger"; notrigger_fail=$((notrigger_fail+1))
    elif echo "$lc" | grep -qE 'already registered|duplicate|path.*(exist|use)|webhook.*(conflict|in use)|conflict.*webhook'; then
      bucket="webhook-collision"; webhook_fail=$((webhook_fail+1))
    else
      bucket="other"; other_fail=$((other_fail+1))
    fi
    python3 -c "
import json, sys
print(json.dumps({
    'id': sys.argv[1], 'name': sys.argv[2], 'http_code': sys.argv[3],
    'bucket': sys.argv[4], 'message': sys.argv[5][:300],
}))
" "$id" "$name" "$code" "$bucket" "$respbody" >> "$failures_jsonl"
  fi
done < "$ids"

echo "ACTIVATE RESULT: newly_activated=$ok already_active=$already failed=$fail skipped=$skipped never_activate_policy=$never total=$total"
echo "FAILURE BUCKETS: missing-cred=$cred_fail no-trigger=$notrigger_fail webhook-collision=$webhook_fail other=$other_fail"
[ "$fail" -gt 0 ] && echo "sample failures:" && head -5 "$failures_jsonl"

# --- Guard: workflows in the never-activate list must have every automatic trigger node
# (any trigger-type node except the manual trigger) held disabled, no matter what turned one
# back on. Skipping /activate above only stops this job from flipping the workflow-level
# active flag; it has no power over a node's own disabled flag, which is a different field
# set by a different kind of write (a PUT of the whole workflow, not a POST to /activate).
# Something did exactly that to xNWE0BuyBOePIBbU on 2026-09-06, outside this job's own run
# windows, so the guard checks and corrects node state directly on every run rather than
# trusting that leaving `active` alone is enough. Never echoes a PUT response body: that
# endpoint returns every node parameter, including live credentials.
never_checked=0; never_corrected=0
corrections_jsonl=$(mktemp)
: > "$corrections_jsonl"
for id in "${NEVER_IDS[@]}"; do
  [ -z "$id" ] && continue
  never_checked=$((never_checked+1))
  wf_json=$(curl -sf "${H[@]}" "$API/workflows/$id") || { echo "never-activate guard: GET $id failed, skipping guard this run"; continue; }
  guard_out=$(echo "$wf_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
changed = []
for n in d.get('nodes', []):
    t = (n.get('type') or '').lower()
    is_manual = 'manualtrigger' in t
    is_auto_trigger = ('trigger' in t or t in ('n8n-nodes-base.webhook', 'n8n-nodes-base.cron')) and not is_manual
    if is_auto_trigger and not n.get('disabled', False):
        n['disabled'] = True
        changed.append(n.get('name') or '')
result = {'changed': changed, 'name': d.get('name') or ''}
if changed:
    result['body'] = {k: d[k] for k in ('name', 'nodes', 'connections', 'settings', 'staticData') if k in d}
print(json.dumps(result))
")
  n_changed=$(echo "$guard_out" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('changed', [])))")
  if [ "$n_changed" -gt 0 ]; then
    wf_name=$(echo "$guard_out" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))")
    changed_csv=$(echo "$guard_out" | python3 -c "import json,sys; print(','.join(json.load(sys.stdin).get('changed', [])))")
    echo "$guard_out" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['body']))" > /tmp/never-activate-guard-put.json
    put_code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${H[@]}" --data-binary @/tmp/never-activate-guard-put.json "$API/workflows/$id")
    rm -f /tmp/never-activate-guard-put.json
    never_corrected=$((never_corrected+1))
    corrected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    python3 -c "
import json, sys
print(json.dumps({
    'id': sys.argv[1], 'name': sys.argv[2],
    'nodes_redisabled': [x for x in sys.argv[3].split(',') if x],
    'put_http_code': sys.argv[4], 'corrected_at': sys.argv[5],
}))
" "$id" "$wf_name" "$changed_csv" "$put_code" "$corrected_at" >> "$corrections_jsonl"
    echo "never-activate guard: RE-DISABLED drifted trigger(s) on $id ($wf_name): $changed_csv (PUT http_code=$put_code, at $corrected_at)"
  fi
done
echo "NEVER-ACTIVATE GUARD: checked=$never_checked corrected=$never_corrected"

mkdir -p data
python3 -c "
import json, sys
from datetime import datetime, timezone

failures = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            failures.append(json.loads(line))

skipped_list = []
with open(sys.argv[10]) as f:
    for line in f:
        line = line.strip()
        if line:
            skipped_list.append(json.loads(line))

corrections = []
with open(sys.argv[12]) as f:
    for line in f:
        line = line.strip()
        if line:
            corrections.append(json.loads(line))

report = {
    'generated_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'total': int(sys.argv[2]),
    'newly_activated': int(sys.argv[3]),
    'already_active': int(sys.argv[4]),
    'failed': int(sys.argv[5]),
    'skipped': int(sys.argv[11]),
    'never_activate_policy': int(sys.argv[13]),
    'buckets': {
        'missing_cred': int(sys.argv[6]),
        'webhook_collision': int(sys.argv[7]),
        'no_trigger': int(sys.argv[9]) if len(sys.argv)>9 else 0,
        'other': int(sys.argv[8]),
    },
    'failures': failures,
    'skipped_detail': skipped_list,
    'never_activate_guard': {
        'checked': int(sys.argv[14]),
        'corrected': int(sys.argv[15]),
        'corrections': corrections,
    },
}
with open('data/n8n-activate-report.json', 'w') as f:
    json.dump(report, f, indent=2)
    f.write('\n')
" "$failures_jsonl" "$total" "$ok" "$already" "$fail" "$cred_fail" "$webhook_fail" "$other_fail" "$notrigger_fail" "$skipped_jsonl" "$skipped" "$corrections_jsonl" "$never" "$never_checked" "$never_corrected"

# fire 2026-07-13T21:48:17Z

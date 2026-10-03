#!/usr/bin/env bash
# Activate eligible pod workflows and report counts publicly, diagnostics privately.
set -uo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLIC_REPORT="${N8N_PUBLIC_REPORT:-$ROOT/data/n8n-activate-summary.json}"
PRIVATE_REPORT="${N8N_PRIVATE_REPORT:-$ROOT/core/STATE/n8n-activate-report.json}"
RUN_ID="${GITHUB_RUN_ID:-local-$(date -u +%Y%m%dT%H%M%S)-$$}"
RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
N8N_URL="${N8N_URL:-}"
N8N_API_KEY="${N8N_API_KEY:-}"
API="${N8N_URL%/}/api/v1"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/n8n-activate.XXXXXXXX")" || exit 1
trap 'rm -rf -- "$tmp"' EXIT
ids="$tmp/workflows.tsv"
failures="$tmp/failures.jsonl"
skipped_detail="$tmp/skipped.jsonl"
corrections="$tmp/corrections.jsonl"
guard_errors="$tmp/guard-errors.jsonl"
: > "$ids"; : > "$failures"; : > "$skipped_detail"; : > "$corrections"; : > "$guard_errors"
mkdir -p "$(dirname "$PUBLIC_REPORT")" "$(dirname "$PRIVATE_REPORT")"
# Remove only these run outputs so an early failure cannot publish old evidence.
rm -f -- "$PUBLIC_REPORT" "$PRIVATE_REPORT"

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
NEVER_FILE="$ROOT/config/never-activate.txt"
NEVER_IDS=()
if [ -f "$NEVER_FILE" ]; then
  while read -r nid _rest; do
    [ -z "$nid" ] && continue
    case "$nid" in \#*) continue ;; esac
    NEVER_IDS+=("$nid")
  done < "$NEVER_FILE"
fi

ok=0; already=0; fail=0; skipped=0; never=0; archived=0; total=0
cred_fail=0; webhook_fail=0; other_fail=0; notrigger_fail=0
guard_checked=0; guard_corrected=0; guard_failed=0
list_failed=0; list_failure_reason=""; cursor=""; page=0

request() {
  local output="$1"; shift
  local code
  : > "$output"
  code=$(curl -s -o "$output" -w '%{http_code}' -H "X-N8N-API-KEY: $N8N_API_KEY" -H 'Content-Type: application/json' "$@" 2>/dev/null) || { printf '000'; return; }
  printf '%s' "$code"
}

record_failure() {
  python3 - "$failures" "$1" "$2" "$3" "$4" "$5" <<'PY'
import hashlib, json, pathlib, sys
path, ident, name, code, bucket, body_path = sys.argv[1:]
digest = hashlib.sha256(pathlib.Path(body_path).read_bytes()).hexdigest()
with open(path, 'a') as out:
    out.write(json.dumps({'id': ident, 'name': name, 'http_code': code,
                          'bucket': bucket, 'response_sha256': digest}) + '\n')
PY
}

record_guard_error() {
  python3 - "$guard_errors" "$1" "$2" "$3" <<'PY'
import json, sys
with open(sys.argv[1], 'a') as out:
    out.write(json.dumps({'id': sys.argv[2], 'stage': sys.argv[3],
                          'http_code': sys.argv[4]}) + '\n')
PY
}

if [ -z "$N8N_URL" ] || [ -z "$N8N_API_KEY" ]; then
  list_failed=1; list_failure_reason="configuration_missing"
else
  while :; do
    page=$((page+1))
    if [ "$page" -gt 1000 ]; then list_failed=1; list_failure_reason="page_limit"; break; fi
    if [ -z "$cursor" ]; then
      code=$(request "$tmp/list.json" --get --data-urlencode 'limit=250' "$API/workflows")
    else
      code=$(request "$tmp/list.json" --get --data-urlencode 'limit=250' --data-urlencode "cursor=$cursor" "$API/workflows")
    fi
    if [ "$code" != 200 ]; then
      list_failed=1; list_failure_reason="http_$code"; break
    fi
    # Validate the whole page before appending it. Never display API data on failure.
    if ! python3 - "$tmp/list.json" "$tmp/page.tsv" "$tmp/cursor" <<'PY'
import json, pathlib, sys
try:
    data = json.loads(pathlib.Path(sys.argv[1]).read_text())
    rows = data['data']
    cursor = data.get('nextCursor') or ''
    if not isinstance(rows, list) or not isinstance(cursor, str):
        raise ValueError()
    lines = []
    for w in rows:
        ident, active, archived = w['id'], w['active'], w.get('isArchived', False)
        if not isinstance(ident, str) or not ident.isalnum() or not isinstance(active, bool) or not isinstance(archived, bool):
            raise ValueError()
        name = str(w.get('name') or '').replace('\t', ' ').replace('\r', ' ').replace('\n', ' ')
        lines.append(f'{ident}\t{str(active).lower()}\t{str(archived).lower()}\t{name}\n')
    pathlib.Path(sys.argv[2]).write_text(''.join(lines))
    pathlib.Path(sys.argv[3]).write_text(cursor)
except (KeyError, TypeError, ValueError, json.JSONDecodeError, UnicodeError):
    sys.exit(1)
PY
    then
      list_failed=1; list_failure_reason="invalid_response"; break
    fi
    cat "$tmp/page.tsv" >> "$ids"
    cursor=$(<"$tmp/cursor")
    [ -z "$cursor" ] && break
  done
fi

if [ "$list_failed" -eq 0 ]; then
  total=$(wc -l < "$ids")
  while IFS=$'\t' read -r id active is_archived name; do
    [ -z "$id" ] && continue
    is_never=0
    for n in "${NEVER_IDS[@]}"; do [ "$id" = "$n" ] && { is_never=1; break; }; done
    if [ "$is_never" -eq 1 ]; then
      never=$((never+1))
      python3 - "$skipped_detail" "$id" "$name" <<'PY'
import json, sys
with open(sys.argv[1], 'a') as out:
    out.write(json.dumps({'id': sys.argv[2], 'name': sys.argv[3], 'reason': 'policy: never-activate'}) + '\n')
PY
      continue
    fi
    if [ "$is_archived" = true ]; then
      archived=$((archived+1))
      python3 - "$skipped_detail" "$id" "$name" <<'PY'
import json, sys
with open(sys.argv[1], 'a') as out:
    out.write(json.dumps({'id': sys.argv[2], 'name': sys.argv[3], 'reason': 'archived'}) + '\n')
PY
      continue
    fi
    if [ "$active" = true ]; then already=$((already+1)); continue; fi
    is_skip=0
    for s in "${SKIP_IDS[@]}"; do [ "$id" = "$s" ] && { is_skip=1; break; }; done
    if [ "$is_skip" -eq 1 ]; then
      skipped=$((skipped+1))
      python3 - "$skipped_detail" "$id" "$name" <<'PY'
import json, sys
with open(sys.argv[1], 'a') as out:
    out.write(json.dumps({'id': sys.argv[2], 'name': sys.argv[3], 'reason': 'compatibility exclusion'}) + '\n')
PY
      continue
    fi
    code=$(request "$tmp/activate.json" -X POST "$API/workflows/$id/activate")
    if [ "$code" = 200 ]; then ok=$((ok+1)); continue; fi
    fail=$((fail+1))
    # The HTTP code and digest allow private correlation without retaining raw bodies.
    lc=$(tr '[:upper:]' '[:lower:]' < "$tmp/activate.json" 2>/dev/null || true)
    if [[ "$lc" == *credential* ]]; then
      bucket="missing-cred"; cred_fail=$((cred_fail+1))
    elif [[ "$lc" == *'no trigger node'* || "$lc" == *'cannot be activated because it has no trigger'* ]]; then
      bucket="no-trigger"; notrigger_fail=$((notrigger_fail+1))
    elif [[ "$lc" == *'already registered'* || "$lc" == *duplicate* || "$lc" == *'webhook conflict'* || "$lc" == *'webhook in use'* ]]; then
      bucket="webhook-collision"; webhook_fail=$((webhook_fail+1))
    else
      bucket="other"; other_fail=$((other_fail+1))
    fi
    record_failure "$id" "$name" "$code" "$bucket" "$tmp/activate.json"
  done < "$ids"
fi

# Policy guard keeps all listed automatic trigger nodes disabled. A correction is
# counted only after a successful PUT, and no response body reaches public logs.
for id in "${NEVER_IDS[@]}"; do
  [ -z "$id" ] && continue
  guard_checked=$((guard_checked+1))
  code=$(request "$tmp/guard-get.json" "$API/workflows/$id")
  if [ "$code" != 200 ]; then
    guard_failed=$((guard_failed+1)); record_guard_error "$id" get "$code"; continue
  fi
  if ! python3 - "$tmp/guard-get.json" "$tmp/guard-put.json" "$tmp/guard-info.json" "$id" <<'PY'
import json, pathlib, sys
try:
    data = json.loads(pathlib.Path(sys.argv[1]).read_text())
    if data.get('id') != sys.argv[4]:
        raise ValueError()
    nodes = data['nodes']
    if not isinstance(nodes, list):
        raise ValueError()
    changed = []
    intended = []
    seen = set()
    for node in nodes:
        node_id = node.get('id')
        if not isinstance(node_id, str) or not node_id or node_id in seen:
            raise ValueError()
        seen.add(node_id)
        disabled = node.get('disabled', False)
        if not isinstance(disabled, bool):
            raise ValueError()
        typ = (node.get('type') or '').lower()
        automatic = ('trigger' in typ or typ in ('n8n-nodes-base.webhook', 'n8n-nodes-base.cron')) and 'manualtrigger' not in typ
        if automatic and not disabled:
            node['disabled'] = True
            changed.append(node.get('name') or '')
            intended.append({'id': node_id, 'type': node.get('type')})
    body = {key: data[key] for key in ('name', 'nodes', 'connections', 'settings', 'staticData') if key in data}
    pathlib.Path(sys.argv[2]).write_text(json.dumps(body))
    pathlib.Path(sys.argv[3]).write_text(json.dumps({'name': data.get('name') or '', 'changed': changed,
                                                     'intended': intended}))
except (KeyError, TypeError, ValueError, json.JSONDecodeError, AttributeError, UnicodeError):
    sys.exit(1)
PY
  then
    guard_failed=$((guard_failed+1)); record_guard_error "$id" parse invalid_response; continue
  fi
  n_changed=$(python3 - "$tmp/guard-info.json" <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1]))['changed']))
PY
)
  [ "$n_changed" -eq 0 ] && continue
  code=$(request "$tmp/guard-put-response.json" -X PUT --data-binary "@$tmp/guard-put.json" "$API/workflows/$id")
  corrected_this=false
  if [ "$code" != 200 ]; then
    guard_failed=$((guard_failed+1))
    record_guard_error "$id" put "$code"
  else
    verify_code=$(request "$tmp/guard-verify.json" "$API/workflows/$id")
    if [ "$verify_code" != 200 ]; then
      guard_failed=$((guard_failed+1))
      record_guard_error "$id" verify "$verify_code"
    elif ! python3 - "$tmp/guard-verify.json" "$tmp/guard-info.json" "$id" <<'PY'
import json, pathlib, sys
try:
    data = json.loads(pathlib.Path(sys.argv[1]).read_text())
    if data.get('id') != sys.argv[3]:
        raise ValueError()
    nodes = data['nodes']
    intended = json.loads(pathlib.Path(sys.argv[2]).read_text())['intended']
    if not isinstance(nodes, list):
        raise ValueError()
    if not isinstance(intended, list) or not intended:
        raise ValueError()
    by_id = {}
    for node in nodes:
        node_id = node.get('id')
        if not isinstance(node_id, str) or not node_id or node_id in by_id:
            raise ValueError()
        by_id[node_id] = node
        typ = (node.get('type') or '').lower()
        automatic = ('trigger' in typ or typ in ('n8n-nodes-base.webhook', 'n8n-nodes-base.cron')) and 'manualtrigger' not in typ
        if automatic and node.get('disabled') is not True:
            sys.exit(1)
    for expected in intended:
        node = by_id.get(expected['id'])
        if node is None or node.get('type') != expected['type'] or node.get('disabled') is not True:
            sys.exit(1)
except (KeyError, TypeError, ValueError, json.JSONDecodeError, AttributeError, UnicodeError):
    sys.exit(1)
PY
    then
      guard_failed=$((guard_failed+1))
      record_guard_error "$id" verify verification_failed
    else
      guard_corrected=$((guard_corrected+1))
      corrected_this=true
    fi
  fi
  python3 - "$corrections" "$tmp/guard-info.json" "$id" "$code" "$corrected_this" <<'PY'
import json, sys
info = json.load(open(sys.argv[2]))
with open(sys.argv[1], 'a') as out:
    out.write(json.dumps({'id': sys.argv[3], 'name': info['name'],
                          'nodes_redisabled': info['changed'], 'put_http_code': sys.argv[4],
                          'corrected': sys.argv[5] == 'true'}) + '\n')
PY
done

status=success
if [ "$list_failed" -ne 0 ] || [ "$fail" -ne 0 ] || [ "$guard_failed" -ne 0 ]; then status=failure; fi
python3 - "$PRIVATE_REPORT" "$PUBLIC_REPORT" "$failures" "$skipped_detail" "$corrections" "$guard_errors" "$RUN_ID" "$RUN_ATTEMPT" "$status" "$total" "$ok" "$already" "$fail" "$skipped" "$never" "$archived" "$cred_fail" "$webhook_fail" "$notrigger_fail" "$other_fail" "$guard_checked" "$guard_corrected" "$guard_failed" "$list_failed" "$list_failure_reason" 2>/dev/null <<'PY'
import json, pathlib, sys
from datetime import datetime, timezone

(private_path, public_path, failures_path, skipped_path, corrections_path, guard_errors_path, run_id, run_attempt,
 status, total, activated, already, failed, skipped, never, archived, cred, webhook,
 no_trigger, other, checked, corrected, guard_failed, list_failed, list_reason) = sys.argv[1:]
def rows(path):
    return [json.loads(line) for line in pathlib.Path(path).read_text().splitlines() if line]
summary = {
    'run_id': run_id,
    'run_attempt': run_attempt,
    'generated_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'status': status,
    'enumeration_complete': list_failed == '0',
    'total': int(total),
    'newly_activated': int(activated),
    'already_active': int(already),
    'failed': int(failed),
    'skipped': int(skipped),
    'never_activate_policy': int(never),
    'archived': int(archived),
    'buckets': {'missing_cred': int(cred), 'webhook_collision': int(webhook),
                'no_trigger': int(no_trigger), 'other': int(other)},
    'never_activate_guard': {'checked': int(checked), 'corrected': int(corrected),
                             'failed': int(guard_failed)},
}
private = dict(summary, failures=rows(failures_path), skipped_detail=rows(skipped_path),
               never_activate_guard=dict(summary['never_activate_guard'], corrections=rows(corrections_path),
                                         errors=rows(guard_errors_path)),
               list_failure_reason=list_reason if list_failed != '0' else None)
pathlib.Path(private_path).write_text(json.dumps(private, indent=2) + '\n')
pathlib.Path(public_path).write_text(json.dumps(summary, indent=2) + '\n')
PY
report_rc=$?
if [ "$report_rc" -ne 0 ]; then
  echo 'activation report write failed' >&2
  exit 1
fi
echo "ACTIVATE RESULT: status=$status newly_activated=$ok already_active=$already failed=$fail skipped=$skipped never_activate_policy=$never archived=$archived total=$total"
echo "FAILURE BUCKETS: missing-cred=$cred_fail no-trigger=$notrigger_fail webhook-collision=$webhook_fail other=$other_fail"
echo "NEVER-ACTIVATE GUARD: checked=$guard_checked corrected=$guard_corrected failed=$guard_failed"
[ "$status" = success ]

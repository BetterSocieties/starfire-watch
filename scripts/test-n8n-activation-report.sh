#!/usr/bin/env bash
# Offline regression against the actual activation script and workflow publish block.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$repo/.github/workflows/n8n-activate.yml" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
regression = source.split('  regression:\n', 1)[1].split('  activate:\n', 1)[0]
activate = source.split('  activate:\n', 1)[1]
assert "if: github.event_name == 'push'" in regression
assert 'bash scripts/test-n8n-activation-report.sh' in regression
assert 'secrets.' not in regression and 'bash scripts/n8n-activate.sh' not in regression
assert "if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'" in activate
assert 'bash scripts/n8n-activate.sh' in activate
assert 'cron: "51 */2 * * *"' in source
assert 'group: n8n-pod-mutations' in source
PY
test_root="$(mktemp -d "${TMPDIR:-/tmp}/n8n-report-test.XXXXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/project/scripts" "$test_root/project/config" "$test_root/project/data" "$test_root/project/core/STATE"
cp "$repo/scripts/n8n-activate.sh" "$test_root/project/scripts/n8n-activate.sh"
printf 'held123 policy hold\n' > "$test_root/project/config/never-activate.txt"
SKIP_ID="$(awk '/^SKIP_IDS=\(/ { inside=1; next } inside && $1 !~ /^#/ { print $1; exit }' "$repo/scripts/n8n-activate.sh")"
[ -n "$SKIP_ID" ] || { echo 'compatibility fixture ID missing'; exit 1; }
export SKIP_ID
GITHUB_RUN_ATTEMPT=1
export GITHUB_RUN_ATTEMPT

# No test process has access to a network client: this is the only curl on PATH.
cat > "$test_root/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -u
out=/dev/null; method=GET; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -H|-w|--data-urlencode|--data-binary) shift 2 ;;
    --get|-s|-f|-sf|-sS) shift ;;
    *) url="$1"; shift ;;
  esac
done
code=200; body='{}'
printf '%s %s\n' "$method" "$url" >> "$STUB_LOG"
case "$url:$method" in
  */workflows:GET)
    case "$CASE_NAME" in
      list_auth) code=401; body='{"error":"SENTINEL_RAW_ERROR"}' ;;
      list_parse) body='{bad json' ;;
      *)
        body='{"data":[{"id":"held123","active":false,"isArchived":true,"name":"SENTINEL_HELD_NAME"},{"id":"archived123","active":false,"isArchived":true,"name":"SENTINEL_ARCHIVED_NAME"},{"id":"COMPAT_ID","active":false,"isArchived":false,"name":"SENTINEL_SKIP_NAME"},{"id":"active123","active":true,"name":"SENTINEL_ACTIVE_NAME"},{"id":"good123","active":false,"isArchived":false,"name":"SENTINEL_GOOD_NAME"}],"nextCursor":null}'
        if [ "$CASE_NAME" = mixed ]; then body='{"data":[{"id":"held123","active":false,"isArchived":true,"name":"SENTINEL_HELD_NAME"},{"id":"archived123","active":false,"isArchived":true,"name":"SENTINEL_ARCHIVED_NAME"},{"id":"COMPAT_ID","active":false,"isArchived":false,"name":"SENTINEL_SKIP_NAME"},{"id":"active123","active":true,"name":"SENTINEL_ACTIVE_NAME"},{"id":"good123","active":false,"isArchived":false,"name":"SENTINEL_GOOD_NAME"},{"id":"bad123","active":false,"name":"SENTINEL_BAD_NAME"}],"nextCursor":null}'; fi
        body="${body//COMPAT_ID/$SKIP_ID}"
        ;;
    esac ;;
  */workflows/good123/activate:POST) body='{"active":true}' ;;
  */workflows/bad123/activate:POST) code=400; body='{"message":"SENTINEL_RAW_ERROR unknown failure"}' ;;
  */workflows/held123:GET)
    if [ "$CASE_NAME" = guard_get_fail ]; then code=503; body='{"message":"SENTINEL_RAW_ERROR"}'
    elif rg -q 'PUT .*/workflows/held123' "$STUB_LOG"; then
      case "$CASE_NAME" in
        guard_empty_nodes) body='{"id":"held123","nodes":[]}' ;;
        guard_wrong_workflow) body='{"id":"different123","nodes":[{"id":"trigger123","type":"n8n-nodes-base.webhook","disabled":true}]}' ;;
        guard_missing_node) body='{"id":"held123","nodes":[{"id":"different-node","type":"n8n-nodes-base.webhook","disabled":true}]}' ;;
        guard_duplicate_node) body='{"id":"held123","nodes":[{"id":"trigger123","type":"n8n-nodes-base.webhook","disabled":true},{"id":"trigger123","type":"n8n-nodes-base.webhook","disabled":true}]}' ;;
        guard_unverified) body='{"id":"held123","nodes":[{"id":"trigger123","type":"n8n-nodes-base.webhook","disabled":false}]}' ;;
        guard_string_disabled) body='{"id":"held123","nodes":[{"id":"trigger123","type":"n8n-nodes-base.webhook","disabled":"false"}]}' ;;
        *) body='{"id":"held123","nodes":[{"id":"trigger123","type":"n8n-nodes-base.webhook","disabled":true}]}' ;;
      esac
    else
      body='{"id":"held123","name":"SENTINEL_HELD_NAME","nodes":[{"id":"trigger123","name":"SENTINEL_NODE_NAME","type":"n8n-nodes-base.webhook","disabled":false}],"connections":{},"settings":{},"staticData":{}}'
      if [ "$CASE_NAME" = guard_missing_identity ]; then body='{"id":"held123","name":"SENTINEL_HELD_NAME","nodes":[{"name":"SENTINEL_NODE_NAME","type":"n8n-nodes-base.webhook","disabled":false}],"connections":{},"settings":{},"staticData":{}}'; fi
      if [ "$CASE_NAME" = guard_no_drift ]; then body='{"id":"held123","name":"SENTINEL_HELD_NAME","nodes":[{"id":"trigger123","name":"SENTINEL_NODE_NAME","type":"n8n-nodes-base.webhook","disabled":true}],"connections":{},"settings":{},"staticData":{}}'; fi
    fi ;;
  */workflows/held123:PUT)
    if [ "$CASE_NAME" = guard_put_fail ]; then code=500; body='{"message":"SENTINEL_RAW_ERROR"}'; fi ;;
  *) code=599; body='{"message":"unexpected stub request"}' ;;
esac
printf '%s' "$body" > "$out"
printf '%s' "$code"
STUB
chmod +x "$test_root/bin/curl"

run_case() {
  local scenario="$1" expected="$2" rc=0
  rm -f "$test_root/project/data/n8n-activate-summary.json" "$test_root/project/core/STATE/n8n-activate-report.json"
  : > "$test_root/stub-calls"
  (
    cd "$test_root/project"
    CASE_NAME="$scenario" STUB_LOG="$test_root/stub-calls" PATH="$test_root/bin:$PATH" N8N_URL='https://invalid.example' \
      N8N_API_KEY='SENTINEL_FAKE_SECRET' GITHUB_RUN_ID='offline-42' \
      N8N_PUBLIC_REPORT="$test_root/project/data/n8n-activate-summary.json" \
      N8N_PRIVATE_REPORT="$test_root/project/core/STATE/n8n-activate-report.json" \
      bash scripts/n8n-activate.sh
  ) > "$test_root/log" 2>&1 || rc=$?
  [ "$rc" -eq "$expected" ] || { echo "$scenario exit $rc, expected $expected"; exit 1; }
  ! rg -q 'POST .*/workflows/(archived123|held123)/activate' "$test_root/stub-calls" || { echo "$scenario activated held or archived workflow"; exit 1; }
  if [ "$scenario" = guard_missing_identity ] || [ "$scenario" = guard_no_drift ]; then
    ! rg -q 'PUT .*/workflows/held123' "$test_root/stub-calls" || { echo "$scenario issued an unjustified guard PUT"; exit 1; }
  fi
  python3 - "$test_root/project" "$scenario" "$test_root/log" <<'PY'
import json, os, pathlib, sys
root, scenario, log = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
public = json.loads((root / 'data/n8n-activate-summary.json').read_text())
private = json.loads((root / 'core/STATE/n8n-activate-report.json').read_text())
assert public['run_id'] == private['run_id'] == 'offline-42'
assert public['run_attempt'] == private['run_attempt'] == '1'
assert public['status'] == private['status']
assert private['never_activate_guard']['checked'] == 1
assert 'failures' in private and 'skipped_detail' in private
for token in ('SENTINEL_', 'held123', 'archived123', 'good123', 'bad123', os.environ['SKIP_ID'], 'invalid.example'):
    assert token not in json.dumps(public) + log.read_text(), token
assert 'SENTINEL_FAKE_SECRET' not in json.dumps(private)
assert 'SENTINEL_RAW_ERROR' not in json.dumps(private)
if scenario == 'success':
    assert public['status'] == 'success'
    assert (public['total'], public['newly_activated'], public['already_active'], public['skipped'], public['never_activate_policy'], public['archived']) == (5, 1, 1, 1, 1, 1)
    assert {x['reason'] for x in private['skipped_detail']} == {'policy: never-activate', 'archived', 'compatibility exclusion'}
    assert public['never_activate_guard']['corrected'] == 1
elif scenario == 'mixed':
    assert public['status'] == 'failure' and public['failed'] == 1
    assert private['failures'][0]['id'] == 'bad123'
    assert private['failures'][0]['bucket'] == 'other'
    assert len(private['failures'][0]['response_sha256']) == 64
elif scenario.startswith('list_'):
    assert public['status'] == 'failure' and not public['enumeration_complete']
    assert public['total'] == 0 and private['list_failure_reason']
elif scenario == 'guard_put_fail':
    assert public['status'] == 'failure' and public['never_activate_guard']['corrected'] == 0
    assert public['never_activate_guard']['failed'] == 1
    assert private['never_activate_guard']['corrections'][0]['corrected'] is False
    assert private['never_activate_guard']['errors'][0] == {'id': 'held123', 'stage': 'put', 'http_code': '500'}
elif scenario == 'guard_get_fail':
    assert public['status'] == 'failure' and public['never_activate_guard']['failed'] == 1
    assert private['never_activate_guard']['errors'][0] == {'id': 'held123', 'stage': 'get', 'http_code': '503'}
elif scenario == 'guard_no_drift':
    assert public['status'] == 'success' and public['never_activate_guard']['corrected'] == 0
elif scenario in ('guard_empty_nodes', 'guard_wrong_workflow', 'guard_missing_node', 'guard_duplicate_node', 'guard_unverified', 'guard_string_disabled'):
    assert public['status'] == 'failure' and public['never_activate_guard']['corrected'] == 0
    assert private['never_activate_guard']['errors'][0] == {'id': 'held123', 'stage': 'verify', 'http_code': 'verification_failed'}
elif scenario == 'guard_missing_identity':
    assert public['status'] == 'failure' and public['never_activate_guard']['corrected'] == 0
    assert private['never_activate_guard']['errors'][0] == {'id': 'held123', 'stage': 'parse', 'http_code': 'invalid_response'}
PY
}

run_case success 0
run_case mixed 1
run_case list_auth 1
run_case list_parse 1
run_case guard_put_fail 1
run_case guard_get_fail 1
run_case guard_unverified 1
run_case guard_empty_nodes 1
run_case guard_wrong_workflow 1
run_case guard_missing_node 1
run_case guard_duplicate_node 1
run_case guard_missing_identity 1
run_case guard_string_disabled 1
run_case guard_no_drift 0

# Extract and execute the publish step from the actual workflow, with local git only.
python3 - "$repo/.github/workflows/n8n-activate.yml" "$test_root/publish.sh" <<'PY'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
start = lines.index('      - name: publish activate report')
run = lines.index('        run: |', start) + 1
body = []
for line in lines[run:]:
    if line and not line.startswith('          '):
        break
    body.append(line[10:] if line else '')
pathlib.Path(sys.argv[2]).write_text('set -e\n' + '\n'.join(body) + '\n')
PY
mkdir -p "$test_root/project/core/scripts"
cat > "$test_root/project/core/scripts/push-to-main.sh" <<'STUB'
#!/usr/bin/env bash
git push -q origin HEAD:main
STUB
cat > "$test_root/bin/git" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s %s\n' "$PWD" "$*" >> "$GIT_CALL_LOG"
if [ "${1:-}" = -C ]; then
  [ "${3:-}" = diff ] && exit 1
else
  [ "${1:-}" = diff ] && exit 1
  case "$PWD" in */core) [ "${1:-}" = push ] && [ "${GIT_FAIL_PRIVATE:-0}" = 1 ] && exit 1 ;; esac
fi
exit 0
STUB
chmod +x "$test_root/bin/git"
GIT_CALL_LOG="$test_root/git-calls"; export GIT_CALL_LOG
(
  cd "$test_root/project"
  PATH="$test_root/bin:$PATH" GITHUB_RUN_ID=offline-42 GIT_FAIL_PRIVATE=1 bash "$test_root/publish.sh"
) > "$test_root/publish-log" 2>&1 && { echo 'private push failure was masked'; exit 1; }
! rg -q '/project push -q' "$GIT_CALL_LOG" || { echo 'public push after private failure'; exit 1; }

python3 - "$test_root/project/data/n8n-activate-summary.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]); data = json.loads(path.read_text()); data['run_id'] = 'stale-run'; path.write_text(json.dumps(data))
PY
: > "$GIT_CALL_LOG"
(
  cd "$test_root/project"
  PATH="$test_root/bin:$PATH" GITHUB_RUN_ID=offline-42 bash "$test_root/publish.sh"
) > "$test_root/publish-log" 2>&1 && { echo 'stale report was published'; exit 1; }
[ ! -s "$GIT_CALL_LOG" ] || { echo 'git invoked on stale report'; exit 1; }

python3 - "$test_root/project/data/n8n-activate-summary.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]); data = json.loads(path.read_text()); data['run_id'] = 'offline-42'; path.write_text(json.dumps(data))
PY
: > "$GIT_CALL_LOG"
(
  cd "$test_root/project"
  PATH="$test_root/bin:$PATH" GITHUB_RUN_ID=offline-42 GITHUB_RUN_ATTEMPT=2 bash "$test_root/publish.sh"
) > "$test_root/publish-log" 2>&1 && { echo 'prior run attempt was published'; exit 1; }
[ ! -s "$GIT_CALL_LOG" ] || { echo 'git invoked on prior attempt'; exit 1; }

python3 - "$test_root/project/data/n8n-activate-summary.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]); data = json.loads(path.read_text()); data['run_id'] = 'offline-42'; path.write_text(json.dumps(data))
PY
: > "$GIT_CALL_LOG"
python3 - "$test_root/project/data/n8n-activate-summary.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]); data = json.loads(path.read_text()); data['failures'] = [{'id': 'SENTINEL_INTERNAL_ID'}]; path.write_text(json.dumps(data))
PY
(
  cd "$test_root/project"
  PATH="$test_root/bin:$PATH" GITHUB_RUN_ID=offline-42 bash "$test_root/publish.sh"
) > "$test_root/publish-log" 2>&1 && { echo 'public detail was published'; exit 1; }
[ ! -s "$GIT_CALL_LOG" ] || { echo 'git invoked on public detail'; exit 1; }
python3 - "$test_root/project/data/n8n-activate-summary.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]); data = json.loads(path.read_text()); del data['failures']; path.write_text(json.dumps(data))
PY
: > "$GIT_CALL_LOG"
python3 - "$test_root/project/data/n8n-activate-summary.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]); data = json.loads(path.read_text()); data['failed'] = 'SENTINEL_INTERNAL_ID'; path.write_text(json.dumps(data))
PY
(
  cd "$test_root/project"
  PATH="$test_root/bin:$PATH" GITHUB_RUN_ID=offline-42 bash "$test_root/publish.sh"
) > "$test_root/publish-log" 2>&1 && { echo 'string count was published'; exit 1; }
[ ! -s "$GIT_CALL_LOG" ] || { echo 'git invoked on string count'; exit 1; }
python3 - "$test_root/project/data/n8n-activate-summary.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]); data = json.loads(path.read_text()); data['failed'] = 0; data['buckets']['other'] = 'SENTINEL_RAW_ERROR'; path.write_text(json.dumps(data))
PY
(
  cd "$test_root/project"
  PATH="$test_root/bin:$PATH" GITHUB_RUN_ID=offline-42 bash "$test_root/publish.sh"
) > "$test_root/publish-log" 2>&1 && { echo 'string bucket was published'; exit 1; }
[ ! -s "$GIT_CALL_LOG" ] || { echo 'git invoked on string bucket'; exit 1; }
python3 - "$test_root/project/data/n8n-activate-summary.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]); data = json.loads(path.read_text()); data['buckets']['other'] = 0; path.write_text(json.dumps(data))
PY
cp "$test_root/project/data/n8n-activate-summary.json" "$test_root/public-clean.json"
cp "$test_root/project/core/STATE/n8n-activate-report.json" "$test_root/private-clean.json"
for mode in count bucket guard status timestamp negative boolean; do
  python3 - "$test_root/project/data/n8n-activate-summary.json" "$test_root/project/core/STATE/n8n-activate-report.json" "$mode" <<'PY'
import json, pathlib, sys
for name in sys.argv[1:3]:
    path = pathlib.Path(name)
    data = json.loads(path.read_text())
    mode = sys.argv[3]
    if mode == 'count': data['failed'] = 'SENTINEL_INTERNAL_ID'
    elif mode == 'bucket': data['buckets']['other'] = 'SENTINEL_RAW_ERROR'
    elif mode == 'guard': data['never_activate_guard']['failed'] = 'SENTINEL_RAW_ERROR'
    elif mode == 'status': data['status'] = 'SENTINEL_RAW_ERROR'
    elif mode == 'timestamp': data['generated_at'] = 'SENTINEL_RAW_ERROR'
    elif mode == 'negative': data['failed'] = -1
    elif mode == 'boolean': data['enumeration_complete'] = 'SENTINEL_RAW_ERROR'
    path.write_text(json.dumps(data))
PY
  : > "$GIT_CALL_LOG"
  (
    cd "$test_root/project"
    PATH="$test_root/bin:$PATH" GITHUB_RUN_ID=offline-42 bash "$test_root/publish.sh"
  ) > "$test_root/publish-log" 2>&1 && { echo "$mode value injection was published"; exit 1; }
  [ ! -s "$GIT_CALL_LOG" ] || { echo "git invoked on $mode value injection"; exit 1; }
  cp "$test_root/public-clean.json" "$test_root/project/data/n8n-activate-summary.json"
  cp "$test_root/private-clean.json" "$test_root/project/core/STATE/n8n-activate-report.json"
done
: > "$GIT_CALL_LOG"
(
  cd "$test_root/project"
  PATH="$test_root/bin:$PATH" GITHUB_RUN_ID=offline-42 bash "$test_root/publish.sh"
) > "$test_root/publish-log" 2>&1
[ "$(rg -c 'push -q origin HEAD:main' "$GIT_CALL_LOG")" -eq 2 ] || { echo 'private/public publish path incomplete'; exit 1; }

rm -f "$test_root/project/core/STATE/n8n-activate-report.json"
: > "$GIT_CALL_LOG"
(
  cd "$test_root/project"
  PATH="$test_root/bin:$PATH" GITHUB_RUN_ID=offline-42 bash "$test_root/publish.sh"
) > "$test_root/publish-log" 2>&1 && { echo 'missing private report was published'; exit 1; }
[ ! -s "$GIT_CALL_LOG" ] || { echo 'git invoked on missing report'; exit 1; }

# A failed report write must fail the script even if all API operations succeeded.
rc=0
(
  cd "$test_root/project"
  CASE_NAME=success STUB_LOG="$test_root/stub-calls" PATH="$test_root/bin:$PATH" \
    N8N_URL='https://invalid.example' N8N_API_KEY='SENTINEL_FAKE_SECRET' GITHUB_RUN_ID=offline-42 \
    N8N_PUBLIC_REPORT="$test_root/project/data" \
    N8N_PRIVATE_REPORT="$test_root/project/core/STATE/n8n-activate-report.json" \
    bash scripts/n8n-activate.sh
) > "$test_root/log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || { echo 'public report write failure returned success'; exit 1; }
rc=0
(
  cd "$test_root/project"
  CASE_NAME=success STUB_LOG="$test_root/stub-calls" PATH="$test_root/bin:$PATH" \
    N8N_URL='https://invalid.example' N8N_API_KEY='SENTINEL_FAKE_SECRET' GITHUB_RUN_ID=offline-42 \
    N8N_PUBLIC_REPORT="$test_root/project/data/n8n-activate-summary.json" \
    N8N_PRIVATE_REPORT="$test_root/project/core/STATE" \
    bash scripts/n8n-activate.sh
) > "$test_root/log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || { echo 'private report write failure returned success'; exit 1; }

# A mutation that restores false success must be rejected by the exit assertion.
# shellcheck disable=SC2016 # Match the script's literal status expression.
sed 's/\[ "$status" = success \]/true/' "$repo/scripts/n8n-activate.sh" > "$test_root/project/scripts/n8n-activate.sh"
rc=0
(
  cd "$test_root/project"
  CASE_NAME=mixed STUB_LOG="$test_root/stub-calls" PATH="$test_root/bin:$PATH" N8N_URL='https://invalid.example' \
    N8N_API_KEY='SENTINEL_FAKE_SECRET' GITHUB_RUN_ID=offline-42 \
    N8N_PUBLIC_REPORT="$test_root/project/data/n8n-activate-summary.json" \
    N8N_PRIVATE_REPORT="$test_root/project/core/STATE/n8n-activate-report.json" \
    bash scripts/n8n-activate.sh
) > "$test_root/log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || { echo 'mutation did not restore false success'; exit 1; }
echo 'PASS: 14 offline entrypoint scenarios, private/public publish, private push failure, stale/missing/prior-attempt publication, write failures, false-success mutation'

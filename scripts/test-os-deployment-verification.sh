#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow_file="${FLOOR_WORKFLOW_FILE:-$repo_root/.github/workflows/os-deploy.yml}"

fail() {
  printf 'FAIL %s\n' "$1" >&2
  exit 1
}

[[ -f "$workflow_file" ]] || fail "workflow not found: $workflow_file"

step_lines="$(awk '
  /- name: Deploy to Cloudflare Pages/ { deploy = NR }
  /- name: Verify deployed version/ { verify = NR }
  END {
    if (!deploy || !verify || deploy >= verify) exit 1
    print deploy, verify
  }
' "$workflow_file")" || fail 'verification must follow deployment'

read -r deploy_line verify_line <<< "$step_lines"
verify_step="$(awk '
  /- name: Verify deployed version/ { in_step = 1 }
  in_step && /^      - name:/ && !/- name: Verify deployed version/ { exit }
  in_step { print }
' "$workflow_file")"

[[ "$verify_step" == *$'        working-directory: apps/starfire-os'* ]] || fail 'verification working directory is incorrect'
[[ "$verify_step" != *$'        if:'* ]] || fail 'verification step is conditionally disabled'
[[ "$verify_step" != *$'        continue-on-error:'* ]] || fail 'verification failure is masked'
[[ "$verify_step" == *'python3 ../../scripts/verify-os-deployment.py dist/build-stamp.json https://starfireos.pages.dev'* ]] || fail 'core verifier invocation is missing or changed'
[[ "$verify_step" == *'curl -q --silent --show-error --max-time 5 --output /dev/null --write-out '\''%{http_code}'\'' --url https://starfireos.pages.dev'* ]] || fail 'bounded homepage request must disable curl config, discard body and use the fixed URL'
[[ "$verify_step" == *'if [[ "$home_status" != "200" ]]'* ]] || fail 'homepage status must be exactly HTTP 200'

verification_command="$(awk '
  /- name: Verify deployed version/ { in_step = 1; next }
  in_step && /^      - name:/ { exit }
  in_step && /^        run: \|/ { run = 1; next }
  run && /^          / { sub(/^          /, ""); print }
' "$workflow_file")"
[[ -n "$verification_command" ]] || fail 'verification run block is missing'

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"
cat > "$tmp_dir/bin/python3" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'python3' >> "$VERIFY_TEST_LOG"
printf '|%s' "$@" >> "$VERIFY_TEST_LOG"
printf '\n' >> "$VERIFY_TEST_LOG"
exit "${VERIFY_HELPER_EXIT:-0}"
STUB
cat > "$tmp_dir/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl' >> "$VERIFY_TEST_LOG"
printf '|%s' "$@" >> "$VERIFY_TEST_LOG"
printf '\n' >> "$VERIFY_TEST_LOG"
if [[ "${VERIFY_CURL_EXIT:-0}" != 0 ]]; then
  exit "$VERIFY_CURL_EXIT"
fi
printf '%s' "${VERIFY_HOME_STATUS:-200}"
STUB
chmod +x "$tmp_dir/bin/python3" "$tmp_dir/bin/curl"
export PATH="$tmp_dir/bin:$PATH"
export VERIFY_TEST_LOG="$tmp_dir/events.log"

expected_events=$'python3|../../scripts/verify-os-deployment.py|dist/build-stamp.json|https://starfireos.pages.dev\ncurl|-q|--silent|--show-error|--max-time|5|--output|/dev/null|--write-out|%{http_code}|--url|https://starfireos.pages.dev'

run_success_case() {
  : > "$VERIFY_TEST_LOG"
  local output
  if ! output="$(bash -euo pipefail -c "$verification_command; printf 'success-marker\\n'")"; then
    fail 'matching stamp and HTTP 200 should succeed'
  fi
  [[ "$output" == 'success-marker' ]] || fail 'success marker missing from successful verification'
  [[ "$(<"$VERIFY_TEST_LOG")" == "$expected_events" ]] || fail 'helper and homepage request arguments or order changed'
}

run_success_case

: > "$VERIFY_TEST_LOG"
export VERIFY_HELPER_EXIT=19
if output="$(bash -euo pipefail -c "$verification_command; printf 'success-marker\\n'")"; then
  fail 'helper failure unexpectedly succeeded'
fi
[[ -z "$output" ]] || fail 'success marker appeared after verifier failure'
[[ "$(<"$VERIFY_TEST_LOG")" == 'python3|../../scripts/verify-os-deployment.py|dist/build-stamp.json|https://starfireos.pages.dev' ]] || fail 'homepage request ran after verifier failure'
unset VERIFY_HELPER_EXIT

for status in 302 503; do
  : > "$VERIFY_TEST_LOG"
  export VERIFY_HOME_STATUS="$status"
  if output="$(bash -euo pipefail -c "$verification_command; printf 'success-marker\\n'")"; then
    fail "homepage HTTP $status unexpectedly succeeded"
  fi
  [[ -z "$output" ]] || fail "success marker appeared after homepage HTTP $status"
  [[ "$(<"$VERIFY_TEST_LOG")" == "$expected_events" ]] || fail "HTTP $status did not reach homepage check after verifier success"
done
unset VERIFY_HOME_STATUS

: > "$VERIFY_TEST_LOG"
export VERIFY_CURL_EXIT=28
if output="$(bash -euo pipefail -c "$verification_command; printf 'success-marker\\n'")"; then
  fail 'homepage request failure unexpectedly succeeded'
fi
[[ -z "$output" ]] || fail 'success marker appeared after homepage request failure'
[[ "$(<"$VERIFY_TEST_LOG")" == "$expected_events" ]] || fail 'homepage request failure did not follow verifier success'
unset VERIFY_CURL_EXIT

if [[ -z "${VERIFY_MUTATION_CHILD:-}" ]]; then
  awk '
    /- name: Verify deployed version/ { skip = 1 }
    skip && /^      - name:/ && !/- name: Verify deployed version/ { skip = 0 }
    !skip { print }
  ' "$workflow_file" > "$tmp_dir/mutant-workflow.yml"
  if VERIFY_MUTATION_CHILD=1 FLOOR_WORKFLOW_FILE="$tmp_dir/mutant-workflow.yml" \
      bash "$0" > "$tmp_dir/mutant-result" 2>&1; then
    fail 'removing the verification step did not fail this test'
  fi
fi

printf 'PASS deployed-version verification block, failure propagation, exact homepage 200 and removal mutation\n'

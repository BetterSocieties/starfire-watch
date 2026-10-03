#!/usr/bin/env bash
# Execute the workflow's actual self-test run block with a stubbed router.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="${1:-$ROOT/.github/workflows/core-free-model-tick.yml}"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

awk '
  /^      - name: Free-model router self-test$/ { step=1; next }
  step && /^      - name: / { exit }
  step && /^        run: \|$/ { body=1; next }
  body && /^          / { print substr($0, 11); next }
  body && /^[[:space:]]*$/ { print "" }
' "$WORKFLOW" > "$FIXTURE/block.sh"
test -s "$FIXTURE/block.sh" || { echo "FAIL: workflow block not found"; exit 1; }

mkdir "$FIXTURE/core"
git -C "$FIXTURE/core" init -q
git -C "$FIXTURE/core" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -q --allow-empty -m fixture
CORE_SHA="$(git -C "$FIXTURE/core" rev-parse HEAD)"

python3() {
  test "$1" = "scripts/llm-router.py" && test "$2" = "--self-test" || return 97
  printf 'called\n' >> "$CALL_MARKER"
  printf 'stub self-test\n'
  return "$ROUTER_EXIT"
}
export -f python3

run_case() {
  local script="$1" bearer="$2" router_exit="$3" label="$4"
  CALL_MARKER="$FIXTURE/$label.called"
  DOWNSTREAM="$FIXTURE/$label.downstream"
  ROUTER_EXIT="$router_exit"
  export CALL_MARKER DOWNSTREAM ROUTER_EXIT
  set +e
  (
    cd "$FIXTURE/core"
    GROQ_API_KEY= GEMINI_API_KEY= OPENROUTER_API_KEY= \
      STARFIRE_VAULT_BEARER="$bearer" \
      bash --noprofile --norc -e -o pipefail "$script" &&
      printf 'downstream\n' > "$DOWNSTREAM"
  ) > "$FIXTURE/$label.output" 2>&1
  CASE_STATUS=$?
  set -e
}

run_case "$FIXTURE/block.sh" "" 0 missing_bearer
test "$CASE_STATUS" -eq 1
test ! -e "$CALL_MARKER"
test ! -e "$DOWNSTREAM"
rg -q "core checkout sha=$CORE_SHA" "$FIXTURE/missing_bearer.output"

run_case "$FIXTURE/block.sh" fake-bearer 0 success
test "$CASE_STATUS" -eq 0
test "$(wc -l < "$CALL_MARKER")" -eq 1
test -e "$DOWNSTREAM"
rg -q "self-test exit=0" "$FIXTURE/success.output"

run_case "$FIXTURE/block.sh" fake-bearer 7 router_failure
test "$CASE_STATUS" -eq 7
test "$(wc -l < "$CALL_MARKER")" -eq 1
test ! -e "$DOWNSTREAM"
rg -q "self-test exit=7" "$FIXTURE/router_failure.output"

if [ "$#" -eq 0 ]; then
  # Mutate a disposable copy of the actual workflow, then rerun every assertion
  # against its extracted block. The suite must fail at missing-bearer handling.
  awk '
    /^      - name: Free-model router self-test$/ { step=1 }
    step && /^        run: \|$/ {
      print
      print "          if [ -z \"${GROQ_API_KEY}${GEMINI_API_KEY}${OPENROUTER_API_KEY}\" ]; then"
      print "            exit 0"
      print "          fi"
      step=0
      next
    }
    { print }
  ' "$WORKFLOW" > "$FIXTURE/mutated-workflow.yml"
  if bash "$0" "$FIXTURE/mutated-workflow.yml" > "$FIXTURE/mutation.output" 2>&1; then
    echo "FAIL: the retired green-skip mutation passed the workflow suite"
    exit 1
  fi
fi
echo "PASS: workflow block cases and green-skip mutation rejection"

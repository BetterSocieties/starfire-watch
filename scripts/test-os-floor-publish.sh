#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow_file="${FLOOR_WORKFLOW_FILE:-$repo_root/.github/workflows/os-deploy.yml}"

if [[ ! -f "$workflow_file" ]]; then
  printf 'FAIL workflow not found: %s\n' "$workflow_file" >&2
  exit 1
fi

step_lines="$(awk '
  /- name: Regenerate Floor feed/ { floor = NR }
  /- name: Build app/ { build = NR }
  END {
    if (!floor || !build || floor >= build) exit 1
    print floor, build
  }
' "$workflow_file")" || {
  printf 'FAIL Floor feed step must appear before Build app\n' >&2
  exit 1
}

generator_command="$(awk '
  /- name: Regenerate Floor feed/ { in_step = 1; next }
  in_step && /^      - name:/ { exit }
  in_step && /^        run: \|/ { run = 1; next }
  run && /^          / { sub(/^          /, ""); print }
' "$workflow_file")"

if [[ "$generator_command" != $'python3 scripts/write-the-floor-feed.py\npython3 scripts/write-the-floor-feed.py --self-test' ]]; then
  printf 'FAIL Floor feed step must generate and self-test (got: %s)\n' \
    "${generator_command:-<missing>}" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
mkdir -p "$tmp_dir/bin"
trap 'rm -rf "$tmp_dir"' EXIT
cat > "$tmp_dir/bin/python3" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${2:-}" in
  --self-test)
    printf 'self-test\n' >> "$FLOOR_TEST_LOG"
    exit "${FLOOR_SELF_TEST_EXIT:-0}" ;;
  --check-public)
    printf 'check:%s\n' "$3" >> "$FLOOR_TEST_LOG"
    exit "${FLOOR_CHECK_EXIT:-0}" ;;
  *)
    printf 'generator\n' >> "$FLOOR_TEST_LOG"
    exit "${FLOOR_GENERATOR_EXIT:-0}" ;;
esac
STUB
cat > "$tmp_dir/bin/npx" <<'STUB'
#!/usr/bin/env bash
printf 'upload\n' >> "$FLOOR_TEST_LOG"
STUB
chmod +x "$tmp_dir/bin/python3"
chmod +x "$tmp_dir/bin/npx"

export PATH="$tmp_dir/bin:$PATH"
export FLOOR_TEST_LOG="$tmp_dir/events.log"

# Execute the extracted command exactly as a GitHub Actions bash step runs it, then
# record the following build step. The generator is stubbed, so no customer data is read.
if ! bash -e -c "$generator_command"; then
  printf 'FAIL generator command failed in success fixture\n' >&2
  exit 1
fi
printf 'build\n' >> "$FLOOR_TEST_LOG"
expected_success=$'generator\nself-test\nbuild'
if [[ "$(<"$FLOOR_TEST_LOG")" != "$expected_success" ]]; then
  printf 'FAIL generation did not precede build\n' >&2
  exit 1
fi

# A nonzero generator exit must stop the same bash step before the build is reached.
: > "$FLOOR_TEST_LOG"
export FLOOR_GENERATOR_EXIT=23
if bash -e -c "$generator_command"; then
  printf 'FAIL a failing generator unexpectedly succeeded\n' >&2
  exit 1
fi
if [[ "$(<"$FLOOR_TEST_LOG")" != 'generator' ]]; then
  printf 'FAIL build was reached after generator failure\n' >&2
  exit 1
fi

: > "$FLOOR_TEST_LOG"
unset FLOOR_GENERATOR_EXIT
export FLOOR_SELF_TEST_EXIT=23
if bash -e -c "$generator_command"; then
  printf 'FAIL a failing self-test unexpectedly succeeded\n' >&2
  exit 1
fi
if [[ "$(<"$FLOOR_TEST_LOG")" != $'generator\nself-test' ]]; then
  printf 'FAIL build was reached after self-test failure\n' >&2
  exit 1
fi
unset FLOOR_SELF_TEST_EXIT

deploy_command="$(awk '
  /- name: Deploy to Cloudflare Pages/ { in_step = 1; next }
  in_step && /^      - name:/ { exit }
  in_step && /^        run: \|/ { run = 1; next }
  run && /^          / { sub(/^          /, ""); print }
' "$workflow_file")"
if [[ "$deploy_command" != $'python3 ../../scripts/write-the-floor-feed.py --check-public dist\nnpx wrangler pages deploy dist --project-name=starfireos --branch main --commit-dirty=true' ]]; then
  printf 'FAIL final Floor gate must immediately precede upload\n' >&2
  exit 1
fi

: > "$FLOOR_TEST_LOG"
export FLOOR_CHECK_EXIT=23
if bash -e -c "$deploy_command"; then
  printf 'FAIL validation exit 23 allowed upload\n' >&2
  exit 1
fi
if [[ "$(<"$FLOOR_TEST_LOG")" != 'check:dist' ]]; then
  printf 'FAIL upload was reached after validation failure\n' >&2
  exit 1
fi

: > "$FLOOR_TEST_LOG"
unset FLOOR_CHECK_EXIT
bash -e -c "$deploy_command"
if [[ "$(<"$FLOOR_TEST_LOG")" != $'check:dist\nupload' ]]; then
  printf 'FAIL valid final output did not reach upload\n' >&2
  exit 1
fi

# A removed gate must make the test fail its exact command check, and the
# adversarial execution demonstrates why: validation exit 23 cannot block it.
mutated="${deploy_command/--check-public dist/--self-test}"
if [[ "$mutated" == "$deploy_command" || "$mutated" == *'--check-public dist'* ]]; then
  printf 'FAIL gate-removal mutation did not apply\n' >&2
  exit 1
fi
: > "$FLOOR_TEST_LOG"
export FLOOR_CHECK_EXIT=23
bash -e -c "$mutated"
if [[ "$(<"$FLOOR_TEST_LOG")" != $'self-test\nupload' ]]; then
  printf 'FAIL removed-gate mutation did not demonstrate an unsafe upload\n' >&2
  exit 1
fi

if [[ -z "${FLOOR_MUTATION_CHILD:-}" ]]; then
  sed 's/--check-public dist/--self-test/' "$workflow_file" > "$tmp_dir/mutant-workflow.yml"
  if FLOOR_MUTATION_CHILD=1 FLOOR_WORKFLOW_FILE="$tmp_dir/mutant-workflow.yml" \
      bash "$0" > "$tmp_dir/mutant-result" 2>&1; then
    printf 'FAIL removed workflow gate did not fail this test\n' >&2
    exit 1
  fi
fi

printf 'PASS Floor generation, self-test and final publish gate, including exit 23 and mutation\n'

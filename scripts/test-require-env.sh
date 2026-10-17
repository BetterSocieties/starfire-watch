#!/usr/bin/env bash
# Offline check of scripts/require-env.sh and of how core-warm-wave-drain uses it.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
req="$repo/scripts/require-env.sh"
wf="$repo/.github/workflows/core-warm-wave-drain.yml"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS: $1"; else fail=$((fail+1)); echo "FAIL: $1 (got $2, want $3)"; fi; }

rc=0; N8N_URL=https://example.invalid bash "$req" N8N_URL >/dev/null || rc=$?
check "a set variable passes" "$rc" 0
rc=0; env -u N8N_URL bash "$req" N8N_URL >/dev/null || rc=$?
check "an unset variable fails red" "$rc" 1
rc=0; N8N_URL= bash "$req" N8N_URL >/dev/null || rc=$?
check "an empty variable fails red" "$rc" 1
rc=0; A=1 bash "$req" A B >/dev/null || rc=$?
check "one missing of two fails red" "$rc" 1
out="$(SECRET_TOKEN=hunter2-value env -u OTHER bash "$req" SECRET_TOKEN OTHER)"
case "$out" in *hunter2-value*) check "no value is ever printed" leaked clean ;; *) check "no value is ever printed" clean clean ;; esac
rc=0; bash "$req" >/dev/null 2>&1 || rc=$?
check "no names given is a usage error" "$rc" 2

# The workflow: requires the three variables before the sender runs, supplies N8N_URL from the repo
# convention (a plain non-secret value, as core-oj-free-asset-daily does), and maps only exit 3 to green.
grep -q 'N8N_URL: https://n8n.opsjuice.com' "$wf"; check "the drain supplies N8N_URL" "$?" 0
grep -q 'require-env.sh" N8N_URL STARFIRE_VAULT_URL STARFIRE_VAULT_BEARER' "$wf"; check "the drain requires its three variables" "$?" 0
req_line="$(grep -n 'require-env.sh' "$wf" | head -1 | cut -d: -f1)"
send_line="$(grep -n 'send-warm-wave.py --send' "$wf" | head -1 | cut -d: -f1)"
[ "$req_line" -lt "$send_line" ]; check "the requirement runs before the sender" "$?" 0
check "only exit 3 is mapped to green" "$(grep -c 'if \[ "\$rc" -eq 3 \]' "$wf")" 1

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

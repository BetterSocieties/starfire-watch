#!/usr/bin/env bash
# Fail the step, red, when a required environment variable is unset or empty.
# Usage: scripts/require-env.sh NAME [NAME ...]
# It prints only the NAMES that are missing, never a value, so a secret cannot reach the world readable log.
# Why: core-warm-wave-drain ran for weeks without N8N_URL; the sender's screening read raised KeyError,
# exited as a rail hold (3), and the job went green (starfire-core issue 4763).
set -u
[ "$#" -gt 0 ] || { echo "require-env: no variable names given" >&2; exit 2; }
missing=0
for name in "$@"; do
  case "$name" in *[!A-Za-z0-9_]*|"") echo "require-env: bad name" >&2; exit 2 ;; esac
  if [ -z "${!name:-}" ]; then
    echo "::error::required environment variable $name is missing or empty"
    missing=1
  fi
done
exit "$missing"

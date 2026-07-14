#!/usr/bin/env bash
set -uo pipefail
N8N_URL="${N8N_URL:?}"; N8N_API_KEY="${N8N_API_KEY:?}"
API="$N8N_URL/api/v1"; H=(-H "X-N8N-API-KEY: $N8N_API_KEY" -H "Content-Type: application/json")
echo "== GET /credentials"
code=$(curl -s --max-time 20 -o /tmp/creds.out -w '%{http_code}' "${H[@]}" "$API/credentials")
echo "http_code=$code"
cat /tmp/creds.out

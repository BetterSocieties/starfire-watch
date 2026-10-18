#!/usr/bin/env bash
# Stub-only test: no network, no deploy. Runs the planner's self-test.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 scripts/oj-workers-deploy.py --self-test
python3 -c "import json;json.load(open('config/oj-workers.json'))"
echo "test-oj-workers-deploy: pass"

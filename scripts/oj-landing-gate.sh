#!/usr/bin/env bash
# oj-landing-gate.sh <core-checkout-dir> <since-iso8601>
# Prints one number: how many landing-input changes reached main of the core checkout since <since>.
# --first-parent counts a merge commit as the one change it landed on main, and ignores the
# branch commits behind it. Without it a plain merge of a PR counted 0 (core PR 5246).
set -euo pipefail
dir="${1:?core dir}"; since="${2:?since}"
git -C "$dir" log --first-parent --since="$since" --oneline -- \
  scripts/build-oj-webinar-page.py scripts/build-oj-welcome-pages.py ops/oj-post-payment-pages.json \
  scripts/oj-apply-site-chrome.py scripts/oj-place-affiliate-disclosure.py ventures/opsjuice/generators/affiliate \
  config/oj-webinar.json ventures/opsjuice/oj-icp-canonical.json ventures/opsjuice/webinar-pages \
  ventures/opsjuice/landing scripts/deploy-oj-landing.sh scripts/deploy-cf-pages.sh | wc -l | tr -d ' '

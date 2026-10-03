# Python review: free-route diagnostics

Approved. No findings in the reviewed diff.

The resolver labels reflect the chosen route category, explicit `OMNIROUTE_URL`
overrides take precedence over a stale cache, and unknown cached backends are
reported as `unknown`. Self-test failures retain HTTP status or exception class
without printing exception messages, URLs, credentials, response bodies, or
prompts. The change adds diagnostic output only and does not alter model routing
or completion count.

The new tests stub resolver dependencies and completion calls. The added route
change cases exercise label updates when the resolver is consulted after a
change. No live router self-test was run.

Checks run:

- `python3 -m unittest scripts.tests.test-free-route-diagnostics`: 4 passed.
- `python3 scripts/tests/test-router-no-claude.py`: passed, 5 routes checked.
- `git diff --check 08961db870f0a5ef4cbcc478f2d42c6ed775082c -- scripts/llm-router.py scripts/tests/test-free-route-diagnostics.py`: passed.

SHA-256:

- `scripts/llm-router.py`: `4d498497ff4791cb8b0056b9887ef5d9773e627f563431902d6cd3320c1afd34`
- `scripts/tests/test-free-route-diagnostics.py`: `216645d31087dcf6fc7ae978412ef2c9ec30c10f7998c90486ce4491ef50fbf1`

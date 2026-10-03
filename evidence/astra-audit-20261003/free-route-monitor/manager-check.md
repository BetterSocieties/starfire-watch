# Manager check of issue4693 local candidate

Read complete source diff and both new test files. Reviewed the actual resolver
and call_model accessors, not only the implementation summary. Requested fixes
to the first version: record actual resolver choice instead of inferred cache/env
priority; report the final choice when a call fails or changes backend; protect
module import from network; rerun the original workflow suite on its mutation.

The current resolver records only a fixed category while returning the same tuple
and preserving explicit URL precedence, resolution order and cache behavior.
Logging reads that category without another resolution. The explicit URL branch
does not cache; the regression now covers empty and stale caches on that path.
Exceptions retain class and HTTP status, not arbitrary vendor message text.

Manager reran in the actual isolated worktrees:

- PYTHONDONTWRITEBYTECODE=1 python3 scripts/tests/test-free-route-diagnostics.py:
  4tests PASS in0.010s, exit0. Each applicable self-test scenario asserts exactly
  2call_model invocations with fake responses and blocked live network.
- PYTHONDONTWRITEBYTECODE=1 python3 scripts/tests/test-router-no-claude.py:
  5route declarations checked, PASS. This does not prove upstream routing/cost.
- bash scripts/test-free-model-tick.sh: PASS actual block and green-skip mutation.
- bash -n scripts/test-free-model-tick.sh: exit0.
- git diff --check in core and watch: exit0.

Exact reported final hashes, to be independently rechecked before integration:

- core router:4d498497ff4791cb8b0056b9887ef5d9773e627f563431902d6cd3320c1afd34
- core test:216645d31087dcf6fc7ae978412ef2c9ec30c10f7998c90486ce4491ef50fbf1
- watch workflow:dc3142bceafa89fe1e72e8db34f386f21e1d68bbae291786bf2d75aa4b7b01db
- watch test:b8d81f0d864a6ed23b811af3d703918004b4f2b4a27976bc9b274fa21007a33c

Python review pending. No fresh independent judge yet. No commit, push or
activation. The actual-host HTTP502 cause and actual free-route success remain
open; this patch enables a trustworthy next diagnosis without new test traffic.

## Review checkpoint

Separate Python review approved the scoped diff and reran4offline diagnostic
tests plus the5-route policy test. Manager read the full review and rechecked all
4SHA256values above; they match. Fresh independent Astra judge dispatched from
requirements/artifacts only, brief69c3ae83b437292324dc9ea355b7cb8a14a5e0b7a71a73017c010161e14b57ff.
Verdict pending. Temporary agent thread limit cleared; no alternate session was
archived and no independence requirement was relaxed.

Read-only core origin/main workflow search found no push or pull_request trigger;
the only workflow reference to live router self-test is dispatch-only
free-model-tick.yml. No workflow was dispatched and no source was activated.

## Independent acceptance

Fresh independent Astra judge returned PASS at 2026-10-03T08:29:38Z for the
local diagnostic and workflow prerequisite contract. It independently executed
the resolver controls, offline tests, actual workflow block, and negative
green-skip mutation. The four candidate hashes match the accepted artifacts.
Production HTTP502 resolution, actual free completions, quality, upstream cost,
activation and whole-audit completion remain explicitly outside this PASS.
Issue4693 ownership verified WON before draft integration. No activation authorized
by this local acceptance alone.

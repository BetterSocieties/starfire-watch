# Scheduled deployment verification, local acceptance

Issue4753, related core verifier issue4759 and core draftPR4756.
Base watch revision e839ea8be5055a7ae2ede204875825b09ca2ced7.

Run the two isolated checks in this repository:

- bash scripts/test-os-floor-publish.sh
- bash scripts/test-os-deployment-verification.sh

They use temporary stubs, never actual upload or model calls. The new test
executes the real verification block and rejects helper errors, HTTP302/503,
request failures and removal of the verification step. Existing Floor tests
retain their generation, self-test, final upload refusal and mutation checks.

Core scripts/verify-os-deployment.py from core590057f82 must land before this
workflow is activated. The workflow checks out core main, not a watch-local copy.
No merge or rollout is certified here. Safe rollback, live revision evidence
and a subsequent scheduled refresh remain open release requirements.

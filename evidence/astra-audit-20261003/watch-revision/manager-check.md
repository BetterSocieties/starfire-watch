# Manager verification of scheduled publisher integration

Read the complete new test and the workflow/existing-test diff directly.
The existing test changes only its block extraction boundary; its generation,
gate and mutation assertions are retained. New step follows upload and calls
the shared core verifier, then a bounded curl request requiring exact HTTP200.

Manager commands in the watch worktree, all exit0:

- bash -n scripts/test-os-floor-publish.sh scripts/test-os-deployment-verification.sh
- bash scripts/test-os-floor-publish.sh
- bash scripts/test-os-deployment-verification.sh
- git diff --check

The new test executes the real workflow block with isolated stubs and observes
arguments and order, not only text matching. Its failure cases suppress a later
success marker. The removed-step mutation must make the test fail. No network,
provider/model call, upload, credential read or real workflow was invoked.

Manager verified SHA256:

- workflow: 8c22a45884772fa4e102e01a9b19612e6afc78d48e9d0a5087e0b63d96f6a733
- existing Floor test: 8b3d279a312835214f85beee113feb33848067271e266790795886c64b6a333b
- new verification test: 84ee7d8b80e6c4edd12372cc28d89486e01bfe9fb5b694f56639e0c4b7f46b8a

Fresh independent Astra judge dispatched with requirements/artifact addresses only,
brief841e1c25a6b1117692c40c499610b8115c44963ca57add41d1729f3b5cb9e4a9.
Verdict pending. Core helper is committed in draftPR4756 at590057f82, not deployed.
This workflow must not activate before that helper lands in core. No runtime,
rollback, scheduled refresh or whole-system claim follows from these local checks.

## Independent acceptance

Fresh judge returned scoped PASS at2026-10-03T07:54:18Z. Manager read the full
verdict. Independent tests additionally exercised the real block under GitHub's
default bash -e behavior, confirmed failure exits19/1/28 and no success marker,
and exposed the removed-step mutation's actual failure. All3artifact hashes
remained unchanged. Core dependency, live release, rollback and scheduled refresh
remain uncertified. Claim4753 reverifiedWON before draft integration.


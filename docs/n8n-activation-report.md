# n8n activation reporting

The scheduled public runner writes aggregate counts and status to
`data/n8n-activate-summary.json`. It publishes the detailed report to the private
`starfire-core` repository at `STATE/n8n-activate-report.json` using the existing
`GH_PAT` writer route. The private report includes workflow IDs, names, result
categories, HTTP codes, and response SHA-256 digests. It does not retain raw API
error bodies or node parameters. The public step log shows counts only.

Pushes to main run only the offline regression job. Scheduled and explicit
manual runs retain the production activation job. This keeps a source merge
from activating workflows as a side effect.

The script exits nonzero if listing, activation, or the never-activate guard
fails. A guard correction counts only after a successful PUT and a read-back
that confirms automatic triggers are disabled. The report still records
partial counts and failure status. Publishing checks that both files have the
current Actions run ID, run attempt, and matching timestamps/status. It pushes private detail
first through core's established retry/rebase helper and fails the job if that
push fails; it then pushes public counts. A
missing or stale report also fails publication. No fallback publishes detail to
the public repository.

The list response's explicit `isArchived: true` marker is counted separately
and never sent to `/activate`. A policy hold takes precedence over this marker.
Missing or false archive markers keep normal eligibility. This follows n8n's
[public list controller](https://github.com/n8n-io/n8n/blob/master/packages/cli/src/public-api/v1/controllers/workflows.public.controller.ts),
which returns `isArchived` for each listed workflow. The production reduction in
activation calls remains to be observed on a natural run.

`scripts/test-n8n-activation-report.sh` runs the actual script with a fake curl
and fake credentials, then runs the workflow's extracted publication block with
a fake git. This is offline evidence only. After integration, inspect the first
natural scheduled run for a matching public summary and private report. Do not
dispatch the workflow to manufacture proof. The old detailed public file was
removed from current source; its history remains recoverable in Git.

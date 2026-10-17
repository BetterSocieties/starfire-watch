#!/usr/bin/env python3
"""core-oj-reconcile-daily must be testable end to end: a workflow_dispatch boolean input inject_gap
runs the script's --inject-gap, fails the real job so the real Slack step posts, labels the post TEST,
and touches nothing real (no Cal backfill, no missing-set record, no dead-man ping)."""
import os
import sys

import yaml

PATH = os.path.join(os.path.dirname(__file__), "..", "..", ".github", "workflows", "core-oj-reconcile-daily.yml")
INJECT = "inputs.inject_gap"


def main() -> int:
    doc = yaml.safe_load(open(PATH))
    on = doc.get(True) or doc.get("on")
    steps = {s.get("name", ""): s for s in doc["jobs"]["reconcile"]["steps"] if s.get("name")}
    inp = (on.get("workflow_dispatch") or {}).get("inputs", {}).get("inject_gap", {})
    reconcile = steps.get("Reconcile the vendors against oj_events", {})
    slack = steps.get("Tell Slack the reconcile is red", {})
    backfill = steps.get("Backfill the Cal bookings the reconcile found missing", {})
    record = steps.get("Record the missing set", {})
    steps_by_uses_upload = next((x for x in doc["jobs"]["reconcile"]["steps"] if str(x.get("uses", "")).startswith("actions/upload-artifact")), {})
    ping = steps.get("Ping the dead-man monitor (green runs only)", {})
    core_ref = on.get("workflow_dispatch", {}).get("inputs", {}).get("core_ref", {})
    checkout = next((x for x in doc["jobs"]["reconcile"]["steps"] if str(x.get("name", "")).startswith("Checkout starfire-core")), {})
    checks = {
        "core_ref is a string dispatch input defaulting main": core_ref.get("type") == "string" and core_ref.get("default") == "main",
        "core checkout uses core_ref, main when empty (scheduled runs)": "inputs.core_ref" in str(checkout.get("with", {}).get("ref")) and "main" in str(checkout.get("with", {}).get("ref")),
        "inject_gap is a boolean dispatch input defaulting false": inp.get("type") == "boolean" and inp.get("default") is False,
        "reconcile step runs --inject-gap when set": "--inject-gap" in reconcile.get("run", "") and INJECT in reconcile.get("run", "") + str(reconcile.get("env", "")),
        "real run still uses the vault wrapper when not injecting": "with-vault-env.sh" in reconcile.get("run", ""),
        "artifact upload skipped for the injected run": INJECT in str(steps_by_uses_upload.get("if")),
        "Slack step stays failure()-gated and unchanged in trigger": slack.get("if") == "failure()",
        "Slack text is labelled TEST for the injected run": "TEST" in slack.get("run", "") and INJECT in slack.get("run", "") + str(slack.get("env", "")),
        "Cal backfill never runs for the injected run": "failure()" in str(backfill.get("if")) and INJECT in str(backfill.get("if")),
        "missing-set record skipped for the injected run": INJECT in str(record.get("if")),
        "dead-man ping stays success-only": ping.get("if") == "success()",
    }
    for label, ok in checks.items():
        print(f"  {'ok  ' if ok else 'FAIL'} {label}")
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    sys.exit(main())

"""vault-get must keep its stdout on the runner.

scripts/vault-get.py prints ::add-mask:: lines for the token it fetches.
GitHub only reads workflow commands from a step's stdout, so redirecting
vault-get itself into a RUNNER_TEMP log hides those lines. The redirect
belongs inside the child command, for example vault-get ... -- bash -c
'exec python3 scripts/... > "$RUNNER_TEMP/....log" 2>&1'.
"""

from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"


def join_continued_lines(text):
    """Join lines continued with a trailing backslash."""
    logical_lines = []
    buf = ""
    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        if line.endswith("\\"):
            buf += line[:-1] + " "
        else:
            logical_lines.append(buf + line)
            buf = ""
    if buf:
        logical_lines.append(buf)
    return logical_lines


def _has_outer_redirect(text):
    """True when text has a > outside single or double quotes."""
    in_single = False
    in_double = False
    for ch in text:
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == ">" and not in_single and not in_double:
            return True
    return False


def _vault_get_violations():
    """Return one entry per vault-get call whose stdout is redirected."""
    violations = []
    for path in sorted(WORKFLOWS_DIR.glob("*.yml")):
        doc = yaml.safe_load(path.read_text())
        jobs = doc.get("jobs") or {}
        for job in jobs.values():
            if not isinstance(job, dict):
                continue
            for step in job.get("steps") or []:
                if not isinstance(step, dict):
                    continue
                run = step.get("run")
                if not isinstance(run, str):
                    continue
                for line in join_continued_lines(run):
                    idx = line.find("scripts/vault-get.py")
                    if idx == -1:
                        continue
                    sep = line.find(" -- ", idx)
                    if sep == -1:
                        continue
                    after = line[sep + len(" -- "):]
                    if _has_outer_redirect(after):
                        violations.append(f"{path.name}: {step.get('name', '')}: {line.strip()}")
    return violations


def test_vault_get_stdout_not_redirected():
    violations = _vault_get_violations()
    assert not violations, (
        "vault-get stdout is redirected into a log, so its ::add-mask:: lines "
        "never reach the runner; move the redirect inside the child command:\n"
        + "\n".join(violations)
    )

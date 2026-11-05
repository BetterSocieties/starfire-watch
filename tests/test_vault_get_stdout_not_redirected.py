"""vault-get must keep its stdout on the runner.

scripts/vault-get.py prints ::add-mask:: lines for the token it fetches.
GitHub only reads workflow commands from a step's stdout, so redirecting
vault-get itself into a RUNNER_TEMP log hides those lines. The redirect
belongs inside the child command, for example vault-get ... -- bash -c
'exec python3 scripts/... > "$RUNNER_TEMP/....log" 2>&1'.

--to-file and --into print those mask lines on vault-get's own stdout
(and, for --to-file, one fingerprint line). A redirect of that stdout,
>, >>, &>, 1> or 2>&1, to any target including /dev/null, drops the mask.
"""

import shlex
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"


def shell_commands(text):
    """One command per entry, with continuations and quotes joined.

    A backslash-newline outside quotes is removed (Bash line continuation).
    A newline inside single or double quotes stays in the same command, so a
    redirect that follows a quote opened on an earlier line is still visible.
    """
    commands = []
    buf = []
    i = 0
    n = len(text)
    in_single = False
    in_double = False
    while i < n:
        ch = text[i]
        if in_single:
            buf.append(ch)
            if ch == "'":
                in_single = False
            i += 1
            continue
        if in_double:
            if ch == "\\" and i + 1 < n and text[i + 1] in ("$", "`", '"', "\\", "\n"):
                if text[i + 1] == "\n":
                    i += 2
                    continue
                buf.append(ch)
                buf.append(text[i + 1])
                i += 2
                continue
            buf.append(ch)
            if ch == '"':
                in_double = False
            i += 1
            continue
        if ch == "\\" and i + 1 < n and text[i + 1] == "\n":
            i += 2
            continue
        # A word-initial # comments out the rest of the line. An apostrophe
        # in that comment must not open a quote, or the next line joins.
        if ch == "#" and (not buf or buf[-1] in " \t|&;()"):
            while i < n and text[i] != "\n":
                i += 1
            continue
        if ch == "'":
            in_single = True
            buf.append(ch)
            i += 1
            continue
        if ch == '"':
            in_double = True
            buf.append(ch)
            i += 1
            continue
        if ch == "\n":
            commands.append("".join(buf))
            buf = []
            i += 1
            continue
        buf.append(ch)
        i += 1
    if buf:
        commands.append("".join(buf))
    return commands


def _has_outer_redirect(text):
    """True when shlex sees a stdout redirect outside quotes.

    punctuation_chars makes an unquoted > its own token. A > inside quotes
    stays inside the word, so a child log redirect is not a hit.
    """
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        return ">" in text
    return any(">" in tok and set(tok) <= set("<>&") for tok in tokens)


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
                for command in shell_commands(run):
                    idx = command.find("scripts/vault-get.py")
                    if idx == -1:
                        continue
                    sep = command.find(" -- ", idx)
                    # A redirect after " -- " is the shell's redirect of
                    # vault-get itself, unless the child keeps it inside quotes.
                    if sep != -1 and _has_outer_redirect(command[sep + len(" -- "):]):
                        violations.append(
                            f"{path.name}: {step.get('name', '')}: {command.strip()}"
                        )
                        continue
                    # --to-file and --into have no separate stdout. The mask
                    # lines are this invocation's own stdout, so an unquoted
                    # redirect here (any target, /dev/null included) hides them.
                    head = command if sep == -1 else command[:sep]
                    if ("--to-file" in head or "--into" in head) and _has_outer_redirect(head):
                        violations.append(
                            f"{path.name}: {step.get('name', '')}: {command.strip()}"
                        )
    return violations


def test_vault_get_stdout_not_redirected():
    violations = _vault_get_violations()
    assert not violations, (
        "vault-get stdout is redirected, so its ::add-mask:: lines never reach "
        "the runner. Put a child redirect inside the child command. A --to-file "
        "or --into call has no child: leave its stdout on the runner.\n"
        + "\n".join(violations)
    )

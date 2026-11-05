"""vault-get must keep its stdout on the runner.

scripts/vault-get.py prints ::add-mask:: lines for the token it fetches.
GitHub only reads workflow commands from a step's stdout, so redirecting
vault-get itself into a RUNNER_TEMP log hides those lines. The redirect
belongs inside the child command, for example vault-get ... -- bash -c
'exec python3 scripts/... > "$RUNNER_TEMP/....log" 2>&1'.

--to-file and --into print those mask lines on vault-get's own stdout
(and, for --to-file, one fingerprint line). A redirect of that stdout,
>, >>, &>, 1> or 2>&1, to any target including /dev/null, drops the mask.
So does a capture: $( ) or backticks take those lines into the variable,
and GitHub never reads them.
"""

import re
import shlex
from pathlib import Path

import pytest
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
    return any(
        ">" in tok and set(tok) <= set("<>&|0123456789") for tok in _outer_tokens(text)
    )


_NEEDLE = "scripts/vault-get.py"
_WITH_VAULT_ENV = "scripts/with-vault-env.sh"
_NEEDLES = (_NEEDLE, _WITH_VAULT_ENV)


_COMMAND_END = ("||", "&&", ";", "&", ";;")


def _outer_tokens(text):
    """shlex tokens up to the end of the call's own command.

    A redirect or pipe inside quotes stays in one word. Tokens after the first
    unquoted ||, &&, ; or & belong to a later command (for example the
    "|| { rc=$?; tail ... | grep ...; }" failure branch), which runs after the
    call has exited, so its pipes and redirects never touch the call's stdout.
    """
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        tokens = text.split()
    for i, tok in enumerate(tokens):
        if tok in _COMMAND_END:
            return tokens[:i]
    return tokens


def _has_outer_pipe(text):
    """True when an unquoted | follows, unless the next command is tee."""
    tokens = _outer_tokens(text)
    for i, tok in enumerate(tokens):
        if tok in ("|", "|&"):
            nxt = tokens[i + 1] if i + 1 < len(tokens) else ""
            if nxt == "tee":
                continue
            return True
    return False


def _inside_substitution(command, needle):
    """True when needle sits inside $(...) or backticks, quote-aware."""
    i = 0
    n = len(command)
    in_single = False
    in_double = False
    stack = []
    arith = 0
    while i < n:
        ch = command[i]
        if in_single:
            if arith == 0 and stack and command.startswith(needle, i):
                return True
            if ch == "'":
                in_single = False
            i += 1
            continue
        if ch == "\\" and i + 1 < n:
            nxt = command[i + 1]
            if not in_double or nxt in ("$", "`", '"', "\\", "\n"):
                i += 2
                continue
        if ch == "'":
            in_single = True
            i += 1
            continue
        if ch == '"':
            in_double = not in_double
            i += 1
            continue
        if arith:
            if ch == "(":
                arith += 1
            elif ch == ")":
                arith -= 1
            elif stack and command.startswith(needle, i):
                return True
            i += 1
            continue
        if ch == "`":
            if stack and stack[-1][0] == "tick":
                _, saved = stack.pop()
                in_double = saved
            else:
                stack.append(("tick", in_double))
                in_double = False
            i += 1
            continue
        if ch == "$" and i + 1 < n and command[i + 1] == "(":
            if i + 2 < n and command[i + 2] == "(":
                arith = 2
                i += 3
                continue
            stack.append(("cmd", in_double))
            in_double = False
            i += 2
            continue
        if ch == ")" and stack and stack[-1][0] == "cmd":
            _, saved = stack.pop()
            in_double = saved
            i += 1
            continue
        if stack and command.startswith(needle, i):
            return True
        i += 1
    return False


def _function_call_violations(run):
    """Flag a function holding a vault call when its call is redirected or piped."""
    funcs = {}
    lines = run.splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{", lines[i])
        if not m:
            i += 1
            continue
        name = m.group(1)
        depth = lines[i].count("{") - lines[i].count("}")
        body = [lines[i]]
        i += 1
        while i < len(lines) and depth > 0:
            depth += lines[i].count("{") - lines[i].count("}")
            body.append(lines[i])
            i += 1
        funcs[name] = "\n".join(body)
    violations = []
    for name, body in funcs.items():
        if not any(needle in body for needle in _NEEDLES):
            continue
        for command in shell_commands(run):
            stripped = command.strip()
            words = stripped.split()
            if not words or words[0] != name:
                continue
            if _has_outer_redirect(command) or _has_outer_pipe(command):
                violations.append(f"function {name} call redirected or piped: {stripped}")
    return violations


def _block_closing_violations(run):
    """Flag a redirect after }, ), fi or done closing a block with a vault call."""
    violations = []
    for command in shell_commands(run):
        for m in re.finditer(r"\{([^{}]*)\}\s*(?:\d*>>?\|?|&>)", command):
            if any(needle in m.group(1) for needle in _NEEDLES):
                violations.append(f"block closed by }} with redirect: {command.strip()}")
        for m in re.finditer(r"\(([^()]*)\)\s*(?:\d*>>?\|?|&>)", command):
            if any(needle in m.group(1) for needle in _NEEDLES):
                violations.append(f"block closed by ) with redirect: {command.strip()}")
        for kw in ("fi", "done"):
            m = re.search(r"\b" + kw + r"\s*(?:\d*>>?\|?|&>)", command)
            if m and any(needle in command[: m.start()] for needle in _NEEDLES):
                violations.append(f"block closed by {kw} with redirect: {command.strip()}")
    commands = shell_commands(run)
    stack = []
    for command in commands:
        stripped = command.strip()
        close_match = re.match(r"^(\}|\))", stripped) or re.match(r"^(fi|done)\b", stripped)
        if close_match:
            closing = close_match.group(1)
            if stack and stack[-1]["vault"] and _has_outer_redirect(command):
                violations.append(f"block closed by {closing} with redirect: {stripped}")
            if stack:
                stack.pop()
            continue
        if stripped.startswith(("if ", "for ", "while ", "{")) and (
            "fi" in stripped or "done" in stripped or "}" in stripped
        ):
            continue
        if stripped == "{" or stripped.startswith("{ "):
            stack.append({"vault": False})
        elif re.match(r"^(if|for|while|until)\b", stripped):
            stack.append({"vault": False})
        elif stripped.startswith("("):
            stack.append({"vault": False})
        if any(needle in command for needle in _NEEDLES):
            for frame in stack:
                frame["vault"] = True
    return violations


def _violations_for_run(run):
    """Return violation descriptions for one run block."""
    violations = []
    commands = shell_commands(run)
    for command in commands:
        needle = next((n for n in _NEEDLES if n in command), None)
        if needle is None:
            continue
        if _inside_substitution(command, needle):
            violations.append(f"captured: {command.strip()}")
            continue
        sep = command.find(" -- ")
        if sep != -1:
            head = command[:sep]
            tail = command[sep + len(" -- "):]
            if _has_outer_redirect(tail) or _has_outer_pipe(tail):
                violations.append(f"redirected or piped: {command.strip()}")
                continue
            if ("--to-file" in head or "--into" in head) and (
                _has_outer_redirect(head) or _has_outer_pipe(head)
            ):
                violations.append(f"redirected or piped: {command.strip()}")
                continue
        elif _has_outer_redirect(command) or _has_outer_pipe(command):
            violations.append(f"redirected or piped: {command.strip()}")
            continue
    exec_seen = False
    for command in commands:
        tokens = _outer_tokens(command)
        if tokens and tokens[0] == "exec" and _has_outer_redirect(command):
            exec_seen = True
        elif exec_seen and any(needle in command for needle in _NEEDLES):
            violations.append(f"exec redirect before vault call: {command.strip()}")
            break
    violations.extend(_function_call_violations(run))
    violations.extend(_block_closing_violations(run))
    return violations


def _vault_get_inside_substitution(command):
    """True when the vault-get path sits inside $(...) or backticks.

    Scans one command already joined by shell_commands. Single quotes hide
    every marker. Double quotes do not. A backslash escapes the next character
    outside quotes, and inside double quotes it escapes only $, `, ", \\, and
    newline. $((...)) is arithmetic, not a capture. Opening $( or ` suspends
    an enclosing double quote so the inner command is scanned on its own.
    """
    i = 0
    n = len(command)
    in_single = False
    in_double = False
    stack = []
    arith = 0
    while i < n:
        ch = command[i]
        if in_single:
            if arith == 0 and stack and command.startswith(_NEEDLE, i):
                return True
            if ch == "'":
                in_single = False
            i += 1
            continue
        if ch == "\\" and i + 1 < n:
            nxt = command[i + 1]
            if not in_double or nxt in "$`\"\\\n":
                i += 2
                continue
        if ch == "'":
            in_single = True
            i += 1
            continue
        if ch == '"':
            in_double = not in_double
            i += 1
            continue
        if arith:
            if ch == "(":
                arith += 1
            elif ch == ")":
                arith -= 1
            elif stack and command.startswith(_NEEDLE, i):
                return True
            i += 1
            continue
        if ch == "`":
            if stack and stack[-1][0] == "tick":
                _, saved = stack.pop()
                in_double = saved
            else:
                stack.append(("tick", in_double))
                in_double = False
            i += 1
            continue
        if ch == "$" and i + 1 < n and command[i + 1] == "(":
            if i + 2 < n and command[i + 2] == "(":
                arith = 2
                i += 3
                continue
            stack.append(("cmd", in_double))
            in_double = False
            i += 2
            continue
        if ch == ")" and stack and stack[-1][0] == "cmd":
            _, saved = stack.pop()
            in_double = saved
            i += 1
            continue
        if stack and command.startswith(_NEEDLE, i):
            return True
        i += 1
    return False


def _vault_get_violations(workflows_dir=None):
    """Return one entry per vault call whose stdout is redirected or captured."""
    base = Path(workflows_dir) if workflows_dir is not None else WORKFLOWS_DIR
    violations = []
    paths = sorted(base.glob("*.yml")) + sorted(base.glob("*.yaml"))
    for path in sorted(paths, key=lambda p: p.name):
        doc = yaml.safe_load(path.read_text())
        if not isinstance(doc, dict):
            continue
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
                for violation in _violations_for_run(run):
                    violations.append(f"{path.name}: {step.get('name', '')}: {violation}")
    return violations


def test_vault_get_stdout_not_redirected():
    violations = _vault_get_violations()
    assert not violations, (
        "vault-get stdout never reaches the runner, so its ::add-mask:: lines "
        "are lost. A redirect hides them. $( ) or backticks capture them. Put a "
        "child redirect inside the child command. A --to-file or --into call has "
        "no child: leave its stdout on the runner.\n"
        + "\n".join(violations)
    )


def test_command_substitution_captures_vault_get_stdout():
    text = 'k="$(python3 scripts/vault-get.py X --to-file f --mode 600)"'
    captured = [c for c in shell_commands(text) if _vault_get_inside_substitution(c)]
    assert captured, "a $( ) capture hides vault-get mask lines"


@pytest.mark.parametrize(
    "run",
    [
        "scripts/with-vault-env.sh K -- python3 scripts/x.py > out.txt",
        "scripts/with-vault-env.sh K -- python3 scripts/x.py | grep foo",
        "python3 scripts/vault-get.py K --to-file f --mode 600 | grep foo",
        "python3 scripts/vault-get.py K --to-file f --mode 600 | head -1",
        "python3 scripts/vault-get.py K --to-file f --mode 600 >| out.txt",
        "scripts/with-vault-env.sh K -- python3 scripts/x.py >| out.txt",
        "exec > out.txt\npython3 scripts/vault-get.py K --to-file f --mode 600",
        "exec 1> out.txt\nscripts/with-vault-env.sh K -- python3 scripts/x.py",
        "load() {\n  python3 scripts/vault-get.py K --to-file f --mode 600\n}\nload K > out.txt",
        "load() {\n  python3 scripts/vault-get.py K --to-file f --mode 600\n}\nload K | grep foo",
        "{ python3 scripts/vault-get.py K --to-file f --mode 600; } > out.txt",
        "( python3 scripts/vault-get.py K --to-file f --mode 600 ) > out.txt",
        "if true; then python3 scripts/vault-get.py K --to-file f --mode 600; fi > out.txt",
        "for i in 1; do python3 scripts/vault-get.py K --to-file f --mode 600; done > out.txt",
        'k="$(python3 scripts/vault-get.py K --to-file f --mode 600)"',
        'k="$(scripts/with-vault-env.sh K -- python3 scripts/x.py)"',
    ],
)
def test_flagged_vault_stdout_shapes(run):
    assert _violations_for_run(run), f"expected a violation for: {run!r}"


@pytest.mark.parametrize(
    "run",
    [
        "scripts/with-vault-env.sh K -- bash -c 'python3 scripts/x.py > \"$RUNNER_TEMP/out.txt\" 2>&1'",
        "python3 scripts/vault-get.py K --to-file f --mode 600 | tee -a out.txt",
        "python3 scripts/vault-get.py K --to-file f --mode 600",
        # core-oj-source-daily.yml: the pipe is in the failure branch, after vault-get exited.
        "python3 scripts/vault-get.py K --into T -- bash -c 'exec python3 scripts/x.py > \"$RUNNER_TEMP/x.log\" 2>&1' || { rc=$?; tail -n 3 \"$RUNNER_TEMP/x.log\" | grep -E 'x' || true; }",
        "python3 scripts/vault-get.py K --to-file f --mode 600 && echo ok > marker.txt",
    ],
)
def test_safe_vault_stdout_shapes(run):
    assert not _violations_for_run(run), f"expected no violation for: {run!r}"


@pytest.mark.parametrize("filename", ["bad.yml", "bad.yaml"])
def test_yaml_and_yml_workflows_are_scanned(tmp_path, filename):
    (tmp_path / filename).write_text(
        "jobs:\n"
        "  job:\n"
        "    steps:\n"
        "      - name: test\n"
        "        run: |\n"
        "          python3 scripts/vault-get.py K --to-file f --mode 600 > out.txt\n"
    )
    assert _vault_get_violations(workflows_dir=tmp_path)

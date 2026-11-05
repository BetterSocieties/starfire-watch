"""Check core scripts for vault-get calls that capture stderr.

Collects every scripts/<name>.py mentioned in this repo's
.github/workflows/*.yml and *.yaml, and checks each one that exists
under <core>/scripts/ for subprocess calls that run vault-get while
capturing stderr (capture_output=True, or stderr=subprocess.PIPE /
subprocess.STDOUT / subprocess.DEVNULL).
"""

import ast
import re
import sys
from pathlib import Path

SCRIPT_RE = re.compile(r"scripts/[A-Za-z0-9_.-]+\.py")
SUBPROCESS_FUNCS = {"run", "check_output", "check_call", "call", "Popen"}
CAPTURED_STDERR_ATTRS = {"PIPE", "STDOUT", "DEVNULL"}


def collect_script_paths(workflows_dir):
    paths = set()
    for pattern in ("*.yml", "*.yaml"):
        for workflow in sorted(workflows_dir.glob(pattern)):
            paths.update(SCRIPT_RE.findall(workflow.read_text(encoding="utf-8")))
    return sorted(paths)


def _contains_vault_get(node):
    for child in ast.walk(node):
        if isinstance(child, ast.Constant) and isinstance(child.value, str):
            if "vault-get" in child.value:
                return True
    return False


def _captures_stderr(node):
    for keyword in node.keywords:
        if keyword.arg == "capture_output":
            if isinstance(keyword.value, ast.Constant) and keyword.value.value is True:
                return True
        if keyword.arg == "stderr":
            value = keyword.value
            if (
                isinstance(value, ast.Attribute)
                and isinstance(value.value, ast.Name)
                and value.value.id == "subprocess"
                and value.attr in CAPTURED_STDERR_ATTRS
            ):
                return True
    return False


def find_violations(source, path):
    tree = ast.parse(source)
    violations = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        if not (
            isinstance(func, ast.Attribute)
            and func.attr in SUBPROCESS_FUNCS
            and isinstance(func.value, ast.Name)
            and func.value.id == "subprocess"
        ):
            continue
        if not node.args:
            continue
        if not _contains_vault_get(node.args[0]):
            continue
        if _captures_stderr(node):
            violations.append((str(path), node.lineno))
    return violations


def check_core(core_dir):
    repo_root = Path(__file__).resolve().parent.parent
    workflows_dir = repo_root / ".github" / "workflows"
    if not workflows_dir.is_dir():
        workflows_dir = Path.cwd() / ".github" / "workflows"
    script_paths = collect_script_paths(workflows_dir)
    checked = 0
    violations = []
    for rel in script_paths:
        script = Path(core_dir) / rel
        if not script.is_file():
            continue
        try:
            source = script.read_text(encoding="utf-8")
            violations.extend(find_violations(source, script))
        except (OSError, SyntaxError):
            continue
        checked += 1
    return checked, violations


def self_test():
    cases = [
        (
            "capture_output=True",
            'import subprocess\nsubprocess.run(["python3", "scripts/vault-get.py", "K"], capture_output=True)\n',
            True,
        ),
        (
            "stderr=subprocess.PIPE",
            'import subprocess\nsubprocess.run(["python3", "scripts/vault-get.py", "K"], stderr=subprocess.PIPE)\n',
            True,
        ),
        (
            "stdout=subprocess.PIPE only",
            'import subprocess\nsubprocess.run(["python3", "scripts/vault-get.py", "K"], stdout=subprocess.PIPE)\n',
            False,
        ),
        (
            "no subprocess keyword",
            'import subprocess\nsubprocess.run(["python3", "scripts/vault-get.py", "K"])\n',
            False,
        ),
    ]
    failed = False
    for name, source, expect_violation in cases:
        got = bool(find_violations(source, "<self-test>"))
        if got == expect_violation:
            print(f"pass: {name}")
        else:
            print(f"FAIL: {name}")
            failed = True
    if failed:
        return 1
    print("ok: self-test passed")
    return 0


def main(argv):
    if "--self-test" in argv:
        return self_test()
    if len(argv) != 1:
        print("usage: python3 scripts/check-core-vault-callers.py <core checkout dir>", file=sys.stderr)
        return 2
    checked, violations = check_core(argv[0])
    for path, lineno in violations:
        print(f"{path}:{lineno} captures vault-get stderr")
    if violations:
        return 1
    print(f"ok: {checked} scripts checked")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

"""Check core scripts for vault-get calls that capture stderr.

Collects every scripts/<name>.py mentioned in this repo's
.github/workflows/*.yml and *.yaml, and checks each one that exists
under <core>/scripts/ for calls that run vault-get while hiding its
stderr: capture_output=True, stderr=subprocess.PIPE/STDOUT/DEVNULL,
a file handle, a shell 2> redirect, os.popen, or an unresolved **kw.
"""

import ast
import re
import sys
from pathlib import Path

SCRIPT_RE = re.compile(r"scripts/[A-Za-z0-9_.-]+\.py")
SUBPROCESS_FUNCS = {"run", "check_output", "check_call", "call", "Popen"}
STDERR_ATTRS = {"PIPE", "STDOUT", "DEVNULL"}
REDIRECT_RE = re.compile(r"2\s*>")
STD_REASON = "captures vault-get stderr"
UNKNOWN_REASON = "cannot prove stderr reaches the runner"


def collect_script_paths(workflows_dir):
    paths = set()
    for pattern in ("*.yml", "*.yaml"):
        for workflow in sorted(workflows_dir.glob(pattern)):
            paths.update(SCRIPT_RE.findall(workflow.read_text(encoding="utf-8")))
    return sorted(paths)


class Context:
    def __init__(self, tree):
        self.tree = tree
        self.subprocess_modules = {"subprocess"}
        self.os_modules = {"os"}
        self.subprocess_funcs = set()
        self.os_funcs = {}
        self._collect_imports()

    def _collect_imports(self):
        for node in ast.walk(self.tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    if alias.name == "subprocess":
                        self.subprocess_modules.add(alias.asname or alias.name)
                    elif alias.name == "os":
                        self.os_modules.add(alias.asname or alias.name)
            elif isinstance(node, ast.ImportFrom):
                if node.module == "subprocess":
                    for alias in node.names:
                        if alias.name in SUBPROCESS_FUNCS:
                            self.subprocess_funcs.add(alias.asname or alias.name)
                elif node.module == "os":
                    for alias in node.names:
                        if alias.name in ("system", "popen"):
                            self.os_funcs[alias.asname or alias.name] = alias.name


def _find_assignment_value(name, tree):
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == name:
                    return node.value
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            if node.target.id == name:
                return node.value
    return None


def _strings_in(node, tree, seen=None):
    """Every string constant anywhere inside node, following a Name to its assignment in this file.

    A list such as ["python3", "scripts/vault-get.py", name] still yields its constants although
    one element is a variable; that is the shape real callers use."""
    seen = set() if seen is None else seen
    out = []
    for child in ast.walk(node):
        if isinstance(child, ast.Constant) and isinstance(child.value, str):
            out.append(child.value)
        elif isinstance(child, ast.Name) and child.id not in seen:
            seen.add(child.id)
            value = _find_assignment_value(child.id, tree)
            if value is not None:
                out.extend(_strings_in(value, tree, seen))
    return out


def _first_arg_strings(node, tree):
    if not node.args:
        return []
    return _strings_in(node.args[0], tree)


def _has_vault_get(commands):
    return any("vault-get" in command for command in commands)


def _stderr_value_captures(value, ctx):
    if isinstance(value, ast.Constant):
        return value.value is not None
    if isinstance(value, ast.Attribute):
        if isinstance(value.value, ast.Name):
            base = value.value.id
            if base == "sys" and value.attr in ("stderr", "stdout"):
                return False
            if base in ctx.subprocess_modules and value.attr in STDERR_ATTRS:
                return True
        return True
    if isinstance(value, ast.Name):
        return True
    if isinstance(value, ast.Call):
        return True
    return True


def _captures_stderr(node, ctx):
    for keyword in node.keywords:
        if keyword.arg == "capture_output":
            if isinstance(keyword.value, ast.Constant) and keyword.value.value is True:
                return True
        elif keyword.arg == "stderr":
            if _stderr_value_captures(keyword.value, ctx):
                return True
    return False


def _kwarg_verdict(node, ctx):
    verdict = None
    for keyword in node.keywords:
        if keyword.arg is not None:
            continue
        value = keyword.value
        if isinstance(value, ast.Name):
            value = _find_assignment_value(value.id, ctx.tree)
        if not isinstance(value, ast.Dict):
            verdict = "unknown"
            continue
        for key, item in zip(value.keys, value.values):
            if not isinstance(key, ast.Constant):
                continue
            if key.value == "capture_output":
                if isinstance(item, ast.Constant) and item.value is True:
                    verdict = "captures"
            elif key.value == "stderr":
                if _stderr_value_captures(item, ctx):
                    verdict = "captures"
    return verdict


def _format(path, lineno, reason):
    if reason is None:
        return f"{path}: cannot parse"
    return f"{path}:{lineno} {reason}"


def find_violations(source, path):
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return [_format(path, None, None)]
    ctx = Context(tree)
    violations = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        kind = None
        realname = None
        if isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name):
            base = func.value.id
            if base in ctx.subprocess_modules and func.attr in SUBPROCESS_FUNCS:
                kind, realname = "subprocess", func.attr
            elif base in ctx.os_modules and func.attr in ("system", "popen"):
                kind, realname = "os", func.attr
        elif isinstance(func, ast.Name):
            if func.id in ctx.subprocess_funcs:
                kind, realname = "subprocess", func.id
            elif func.id in ctx.os_funcs:
                kind, realname = "os", ctx.os_funcs[func.id]
        if kind is None:
            continue

        if kind == "os":
            commands = _first_arg_strings(node, ctx.tree)
            if not _has_vault_get(commands):
                continue
            if realname == "popen" or any(REDIRECT_RE.search(c) for c in commands):
                violations.append(_format(path, node.lineno, STD_REASON))
            continue

        commands = _first_arg_strings(node, ctx.tree)
        if not _has_vault_get(commands):
            continue
        if _captures_stderr(node, ctx):
            violations.append(_format(path, node.lineno, STD_REASON))
            continue
        if any(REDIRECT_RE.search(c) for c in commands if "vault-get" in c):
            violations.append(_format(path, node.lineno, STD_REASON))
            continue
        verdict = _kwarg_verdict(node, ctx)
        if verdict == "captures":
            violations.append(_format(path, node.lineno, STD_REASON))
        elif verdict == "unknown":
            violations.append(_format(path, node.lineno, UNKNOWN_REASON))
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
        except OSError:
            continue
        violations.extend(find_violations(source, script))
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
            "aliased import with capture_output",
            'import subprocess as sp\nsp.run(["python3", "scripts/vault-get.py", "K"], capture_output=True)\n',
            True,
        ),
        (
            "from subprocess import run, PIPE with stderr=PIPE",
            'from subprocess import run, PIPE\nrun(["python3", "scripts/vault-get.py", "K"], stderr=PIPE)\n',
            True,
        ),
        (
            "command in module constant",
            'import subprocess\nCMD = ["python3", "scripts/vault-get.py", "K"]\nsubprocess.run(CMD, capture_output=True)\n',
            True,
        ),
        (
            "command in function-level assignment",
            'import subprocess\ndef f():\n    cmd = ["python3", "scripts/vault-get.py", "K"]\n    subprocess.run(cmd, capture_output=True)\n',
            True,
        ),
        (
            "shell string with 2>/dev/null",
            'import subprocess\nsubprocess.run("python3 scripts/vault-get.py K 2>/dev/null", shell=True)\n',
            True,
        ),
        (
            "shell string with 2>&1",
            'import subprocess\nsubprocess.run("python3 scripts/vault-get.py K 2>&1", shell=True)\n',
            True,
        ),
        (
            "os.system with vault-get and stderr redirect",
            'import os\nos.system("python3 scripts/vault-get.py K 2>log")\n',
            True,
        ),
        (
            "os.popen with vault-get",
            'import os\nos.popen("python3 scripts/vault-get.py K")\n',
            True,
        ),
        (
            "subprocess.run with **kw dict containing capture_output",
            'import subprocess\nkw = {"capture_output": True}\nsubprocess.run(["python3", "scripts/vault-get.py", "K"], **kw)\n',
            True,
        ),
        (
            "subprocess.run with **kw dict containing stderr=PIPE",
            'import subprocess\nkw = {"stderr": subprocess.PIPE}\nsubprocess.run(["python3", "scripts/vault-get.py", "K"], **kw)\n',
            True,
        ),
        (
            "subprocess.run with unresolvable **kw",
            'import subprocess\ndef f(kw):\n    subprocess.run(["python3", "scripts/vault-get.py", "K"], **kw)\n',
            True,
        ),
        (
            "stderr=open(...)",
            'import subprocess\nsubprocess.run(["python3", "scripts/vault-get.py", "K"], stderr=open("log.txt", "w"))\n',
            True,
        ),
        (
            "stderr=fh (file handle)",
            'import subprocess\nfh = open("log.txt", "w")\nsubprocess.run(["python3", "scripts/vault-get.py", "K"], stderr=fh)\n',
            True,
        ),
        (
            "syntax error in source",
            'import subprocess\nsubprocess.run(["python3", "scripts/vault-get.py", "K"], capture_output=True\n',
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
        (
            "real caller shape: list with a variable key and capture_output",
            'import subprocess, sys\ndef f(name):\n    subprocess.run([sys.executable, "scripts/vault-get.py", name], capture_output=True)\n',
            True,
        ),
        (
            "vault-get path in a module constant used inside the list",
            'import subprocess\nVG = "scripts/vault-get.py"\ndef f(name):\n    subprocess.run(["python3", VG, name], stderr=subprocess.STDOUT)\n',
            True,
        ),
        (
            "stdout=subprocess.PIPE with --into",
            'import subprocess\nsubprocess.run(["python3", "scripts/vault-get.py", "K", "--into", "V", "--", "cmd"], stdout=subprocess.PIPE)\n',
            False,
        ),
    ]
    failed = False
    for name, source, expect_violation in cases:
        got = bool(find_violations(source, "<self-test>"))
        if got == expect_violation:
            print(f"pass: {name}")
        else:
            print(f"FAIL: {name} (expected violation={expect_violation}, got={got})")
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
    for line in violations:
        print(line)
    if violations:
        return 1
    print(f"ok: {checked} scripts checked")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

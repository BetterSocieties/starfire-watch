#!/usr/bin/env python3
"""Deploy the OpsJuice Cloudflare Workers from starfire-core main when their code changed.

Why it lives here: starfire-core's own Actions cannot start jobs until 2026-11-01 (billing), so nothing
deploys on merge. This public repo runs free and checks core out read-only.

THIS REPO'S LOGS ARE PUBLIC. Only Worker names, hashes, pass/fail counts and HTTP codes are printed. Every
command that touches core code writes to a file that is never echoed.

Per Worker in config/oj-workers.json:
  1. hash the deployable source (the Worker dir minus tests/node_modules, plus its also_hash dirs);
  2. read the hash the live Worker carries in its DEPLOY_HASH var (Cloudflare settings API);
  3. equal -> current; different or absent -> deploy: npm ci, tests, `wrangler deploy --keep-vars --var DEPLOY_HASH:<h>`;
  4. verify (one route answers the expected HTTP code, or the settings API reads the new hash back);
  5. any failure -> one message to the Slack relay, exit 1.

--keep-vars is load-bearing: without it wrangler deletes every dashboard-set var not in wrangler.toml
(`wrangler deploy --help`), which would drop opsjuice-email-receiver's SUPABASE_URL. Worker secrets are
never set here; a deploy leaves the existing ones in place.

    python3 scripts/oj-workers-deploy.py --core core                 # real run (needs CLOUDFLARE_API_TOKEN)
    python3 scripts/oj-workers-deploy.py --core core --dry-run       # print the plan, change nothing
    python3 scripts/oj-workers-deploy.py --core core --dry-run --deployed oj-events=abc123
    python3 scripts/oj-workers-deploy.py --self-test
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "..", "config", "oj-workers.json")
HASH_VAR = "DEPLOY_HASH"
WRANGLER = "wrangler@4.149.0"
SKIP_DIRS = {"node_modules", ".wrangler", ".git", "test", "tests"}
SKIP_SUFFIX = (".bak", ".md")
CF_API = "https://api.cloudflare.com/client/v4"
UA = "starfire-watch-oj-workers-deploy"


def source_hash(core, dirs):
    """Stable sha256 over (relative path, file sha256) of every deployable file."""
    h = hashlib.sha256()
    for d in dirs:
        base = os.path.join(core, d)
        if not os.path.isdir(base):
            raise SystemExit("hash: %s is not a directory in the core checkout" % d)
        for root, subdirs, files in os.walk(base):
            subdirs[:] = sorted(s for s in subdirs if s not in SKIP_DIRS)
            for f in sorted(files):
                if f.endswith(SKIP_SUFFIX):
                    continue
                p = os.path.join(root, f)
                with open(p, "rb") as fh:
                    h.update(("%s\0%s\n" % (os.path.relpath(p, core), hashlib.sha256(fh.read()).hexdigest())).encode())
    return h.hexdigest()[:16]


def toml_scalar(text, key):
    m = re.search(r'^%s\s*=\s*"([^"]*)"' % re.escape(key), text, re.M)
    return m.group(1) if m else None


def toml_has_var(text, name):
    sect = re.search(r"^\[vars\]\s*$(.*?)(?=^\[|\Z)", text, re.M | re.S)
    return bool(sect and re.search(r"^%s\s*=" % re.escape(name), sect.group(1), re.M))


def cf_get(path, token):
    req = urllib.request.Request(CF_API + path, headers={"Authorization": "Bearer " + token, "User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise RuntimeError("cloudflare settings read answered http %s" % e.code)
    except urllib.error.URLError as e:
        raise RuntimeError("cloudflare unreachable: %s" % e.reason)


def deployed_hash(account, name, token):
    """The DEPLOY_HASH plain_text binding of the live Worker, or None when it has none (404 = not deployed yet)."""
    try:
        body = cf_get("/accounts/%s/workers/scripts/%s/settings" % (account, name), token)
    except RuntimeError as e:
        if "http 404" in str(e):
            return None
        raise
    for b in body.get("result", {}).get("bindings", []):
        if b.get("name") == HASH_VAR and b.get("type") == "plain_text":
            return b.get("text")
    return None


def plan(core, workers, deployed_fn):
    """[{name, local, live, action, gaps}] with action deploy|current."""
    out = []
    for w in workers:
        local = source_hash(core, [w["dir"]] + w.get("also_hash", []))
        with open(os.path.join(core, w["dir"], "wrangler.toml")) as f:
            toml = f.read()
        account = toml_scalar(toml, "account_id")
        if not account:
            raise SystemExit("%s: wrangler.toml has no account_id" % w["name"])
        live = deployed_fn(w["name"], account)
        gaps = [v for v in w.get("requires_vars", []) if not toml_has_var(toml, v)]
        out.append({"name": w["name"], "dir": w["dir"], "local": local, "live": live, "account": account,
                    "action": "current" if live == local else "deploy", "gaps": gaps, "verify": w["verify"]})
    return out


def run_quiet(cmd, cwd, logpath, env=None):
    with open(logpath, "ab") as lg:
        return subprocess.run(cmd, cwd=cwd, stdout=lg, stderr=subprocess.STDOUT, env=env, timeout=900).returncode


def tap_counts(logpath):
    txt = open(logpath, errors="replace").read()
    p = re.findall(r"^# pass (\d+)", txt, re.M)
    f = re.findall(r"^# fail (\d+)", txt, re.M)
    return (int(p[-1]) if p else 0, int(f[-1]) if f else 1)


def alert(relay, channel, text):
    req = urllib.request.Request(relay, data=json.dumps({"channel": channel, "text": text}).encode(), method="POST",
                                 headers={"Content-Type": "application/json; charset=utf-8", "User-Agent": UA})
    try:
        urllib.request.urlopen(req, timeout=45).read()
        print("alert: sent")
    except Exception as e:  # the run already fails; the alert is best effort
        print("alert: not sent (%s)" % type(e).__name__)


def verify(item, token):
    v = item["verify"]
    if v["kind"] == "http":
        req = urllib.request.Request(v["url"], method=v.get("method", "GET"), headers={"User-Agent": UA})
        try:
            code = urllib.request.urlopen(req, timeout=30).status
        except urllib.error.HTTPError as e:
            code = e.code
        print("verify %s: http %s (expect %s)" % (item["name"], code, v["expect"]))
        return code in v["expect"]
    got = deployed_hash(item["account"], item["name"], token)
    print("verify %s: live hash %s local hash" % (item["name"], "matches" if got == item["local"] else "DIFFERS from"))
    return got == item["local"]


def deploy_one(core, item, token, tmp):
    wdir = os.path.join(core, item["dir"])
    log = os.path.join(tmp, item["name"] + ".log")
    env = {k: v for k, v in os.environ.items() if k != "CLOUDFLARE_ACCOUNT_ID"}  # account comes from wrangler.toml
    env["CLOUDFLARE_API_TOKEN"] = token
    if os.path.exists(os.path.join(wdir, "package-lock.json")):
        if run_quiet(["npm", "ci", "--ignore-scripts"], wdir, log) != 0:
            return "npm ci failed"
    run_quiet(["node", "--test", "--test-reporter=tap"], wdir, log)
    passed, failed = tap_counts(log)
    print("tests %s: pass=%d fail=%d" % (item["name"], passed, failed))
    if passed == 0 or failed != 0:
        return "tests failed (pass=%d fail=%d)" % (passed, failed)
    rc = run_quiet(["npx", "--yes", WRANGLER, "deploy", "--keep-vars", "--var", "%s:%s" % (HASH_VAR, item["local"])], wdir, log, env)
    print("wrangler deploy %s: exit=%d" % (item["name"], rc))
    if rc != 0:
        return "wrangler deploy exit %d" % rc
    return None if verify(item, token) else "verify failed"


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--core")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--deployed", action="append", default=[], metavar="NAME=HASH",
                    help="dry-run without a token only: pretend this live hash (default none)")
    ap.add_argument("--manifest", default=MANIFEST)
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args(argv)
    if a.self_test:
        return self_test()
    if not a.core:
        ap.error("--core is required")
    cfg = json.load(open(a.manifest))
    token = os.environ.get("CLOUDFLARE_API_TOKEN", "")
    pretend = dict(d.split("=", 1) for d in a.deployed)
    if a.dry_run and not token:
        deployed_fn = lambda name, _acct: None if pretend.get(name, "none") == "none" else pretend[name]  # noqa: E731
    else:
        if not token:
            raise SystemExit("CLOUDFLARE_API_TOKEN is not set")
        deployed_fn = lambda name, acct: deployed_hash(acct, name, token)  # noqa: E731
    items = plan(a.core, cfg["workers"], deployed_fn)
    for i in items:
        print("plan %s: %s (local %s, live %s)" % (i["name"], i["action"].upper(), i["local"], i["live"] or "none"))
        for g in i["gaps"]:
            print("  config gap %s: var %s is not in wrangler.toml [vars]; it survives a deploy only because of --keep-vars" % (i["name"], g))
    todo = [i for i in items if i["action"] == "deploy"]
    names = ", ".join(i["name"] for i in todo) or "nothing"
    print(("would deploy: " if a.dry_run else "deploying: ") + names)
    if a.dry_run or not todo:
        return 0
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        for i in todo:
            err = deploy_one(a.core, i, token, tmp)
            if err:
                failures.append("%s: %s" % (i["name"], err))
    if failures:
        alert(cfg["relay"], cfg.get("relay_channel", "log"), "core-oj-workers-deploy failed: " + "; ".join(failures))
        return 1
    return 0


def self_test():
    with tempfile.TemporaryDirectory() as core:
        for d in ("cf-workers/w1", "cf-workers/shared"):
            os.makedirs(os.path.join(core, d, "test"))
            open(os.path.join(core, d, "a.js"), "w").write("x")
            open(os.path.join(core, d, "test", "t.js"), "w").write("t")
        open(os.path.join(core, "cf-workers/w1/wrangler.toml"), "w").write('name = "w1"\naccount_id = "acc"\n[vars]\nA = "1"\n')
        dirs = ["cf-workers/w1", "cf-workers/shared"]
        h1 = source_hash(core, dirs)
        open(os.path.join(core, "cf-workers/w1/test/t.js"), "w").write("changed")
        assert source_hash(core, dirs) == h1, "test-only change must not redeploy"
        open(os.path.join(core, "cf-workers/shared/a.js"), "w").write("y")
        h2 = source_hash(core, dirs)
        assert h2 != h1, "shared change must redeploy"
        w = [{"name": "w1", "dir": "cf-workers/w1", "also_hash": ["cf-workers/shared"], "verify": {"kind": "deployed-hash"}, "requires_vars": ["A", "B"]}]
        assert plan(core, w, lambda *_: None)[0]["action"] == "deploy"
        assert plan(core, w, lambda *_: h2)[0]["action"] == "current"
        assert plan(core, w, lambda *_: h1)[0]["action"] == "deploy"
        assert plan(core, w, lambda *_: None)[0]["gaps"] == ["B"], "missing var is reported"
        t = '[vars]\nA = "1"\n[triggers]\nB = 2\n'
        assert toml_has_var(t, "A") and not toml_has_var(t, "B")
    print("self-test ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())

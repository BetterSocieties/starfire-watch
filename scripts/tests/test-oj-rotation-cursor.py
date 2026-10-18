#!/usr/bin/env python3
"""core-oj-source-daily must not lose a day's metros when the database IO gate stops a run before the
import. Proves (1) the cursor script, (2) the workflow wiring, (3) a simulated sequence of runs with a
gate stop, and (4) when OJ_CORE_OVERTURE_SCRIPT points at starfire-core's scripts/oj-source-overture.py,
that the cursor's date maps to the importer's own metros. Stubs only; reaches no host."""
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import date

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
WF = os.path.join(ROOT, ".github", "workflows", "core-oj-source-daily.yml")
CUR = os.path.join(ROOT, "scripts", "oj-rotation-cursor.py")
FAILS = []


def check(name, ok):
    print(("PASS " if ok else "FAIL ") + name)
    if not ok:
        FAILS.append(name)


def load(path, name):
    sys.path.insert(0, os.path.dirname(os.path.abspath(path)))
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def cli(*args):
    r = subprocess.run([sys.executable, CUR, *args], capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def main() -> int:
    cur = load(CUR, "cur")
    # 1. cursor script
    check("day_for_number inverts business_day_number for 400 consecutive business days",
          all(cur.business_day_number(cur.day_for_number(n)) == n and cur.day_for_number(n).weekday() < 5 for n in range(400)))
    with tempfile.TemporaryDirectory() as d:
        f = os.path.join(d, "rotation-cursor", "n")
        rc, out = cli("day", f, "--today", "2026-10-19")
        check("no cursor file: today's date", rc == 0 and out == "2026-10-19")
        rc, out = cli("day", f, "--today", "2026-10-17")
        check("no cursor file on a Saturday: that Friday", out == "2026-10-16")
        rc, _ = cli("advance", f, "--today", "2026-10-19")
        check("advance writes cursor+1", rc == 0 and open(f).read().strip() == str(cur.business_day_number(date(2026, 10, 19)) + 1))
        rc, out = cli("day", f, "--today", "2027-03-01")
        check("an existing cursor wins over the calendar", out == "2026-10-20")
        open(f, "w").write("garbage\n")
        rc, _ = cli("day", f)
        check("a corrupt cursor fails loudly, never falls back to the calendar", rc != 0)

    # 2. workflow wiring
    doc = yaml.safe_load(open(WF))
    steps = doc["jobs"]["source"]["steps"]
    names = [s.get("name", "") for s in steps]
    idx = {n: i for i, n in enumerate(names)}
    imp = next(s for s in steps if s.get("id") == "import")
    i_imp = steps.index(imp)
    adv = next(s for s in steps if s.get("name", "").startswith("Advance the rotation cursor"))
    sav = next(s for s in steps if s.get("name", "").startswith("Save the rotation cursor"))
    rot = next(s for s in steps if s.get("id") == "rotation")
    check("import takes its date from the cursor", "--rotate --date" in imp["run"] and "steps.rotation.outputs.day" in imp["run"])
    check("import is skipped once the IO gate has stopped the run", imp["if"] == "env.OJ_IO_STOP != '1'")
    check("cursor date is not computed after a stop", rot["if"] == "env.OJ_IO_STOP != '1'")
    for label, s in (("advance", adv), ("save", sav)):
        cond = s["if"]
        check(f"{label} runs only when the import step succeeded", "steps.import.outcome == 'success'" in cond)
        check(f"{label} runs only for an applying run (schedule or apply=true)",
              "github.event_name == 'schedule'" in cond and "inputs.apply == 'true'" in cond)
        check(f"{label} is right after the import, before the next IO gate", i_imp < steps.index(s) < next(
            i for i, n in enumerate(names) if n.startswith("IO gate 1 of 6")))
    check("advance comes before save", steps.index(adv) < steps.index(sav))
    check("nothing else moves the cursor", sum("oj-rotation-cursor.py advance" in s.get("run", "") for s in steps) == 1)
    check("the cache save is the only writer of the cursor key", sum("actions/cache/save" in s.get("uses", "") for s in steps) == 1)

    # 3. simulated runs: workflow semantics over a real cursor file, importer stubbed
    ms = [{"name": f"m{i}"} for i in range(53)]
    per_day = 3
    with tempfile.TemporaryDirectory() as d:
        f = os.path.join(d, "n")
        worked = []

        def run(today, gate0_stops=False, import_fails=False, applying=True):  # applying False = manual dry run
            if gate0_stops:
                return  # OJ_IO_STOP=1: restore, rotation, import, advance and save are all skipped
            day = date.fromisoformat(cli("day", f, "--today", today)[1])
            start = cur.business_day_number(day) * per_day
            todays = [ms[(start + i) % len(ms)]["name"] for i in range(per_day)]
            if import_fails:
                return
            if applying:
                worked.extend(todays)
                cli("advance", f, "--today", today)

        run("2026-10-19")                       # Mon works the cursor's metros
        run("2026-10-20", gate0_stops=True)     # Tue stopped by the gate before the import
        run("2026-10-21")                       # Wed
        run("2026-10-22", import_fails=True)    # Thu import raised: not complete
        run("2026-10-23")                       # Fri
        run("2026-10-26", applying=False)       # Mon manual dry run: reads, does not advance
        run("2026-10-26")                       # Mon
        base = (cur.business_day_number(date(2026, 10, 19))) * per_day
        want = [ms[(base + i) % len(ms)]["name"] for i in range(per_day * 4)]  # Mon, Wed, Fri, next Mon: 4 completed imports
        check("after a gate stop and a failed import, every metro is worked in order with none skipped", worked == want)
        check("a dry run does not move the cursor", worked[-3:] == want[-3:])
        calendar = []
        for today in ("2026-10-19", "2026-10-21", "2026-10-23", "2026-10-26"):
            s = cur.business_day_number(date.fromisoformat(today)) * per_day
            calendar += [ms[(s + i) % len(ms)]["name"] for i in range(per_day)]
        check("the calendar rotation would have lost metros in the same sequence", calendar != worked)

    # 4. cross-check with the importer when its script is available
    core = os.environ.get("OJ_CORE_OVERTURE_SCRIPT")
    if core:
        mod = load(core, "ovt")
        per, real = mod.load_metros(os.path.join(os.path.dirname(core), "..", "config", "oj-metros.json"))
        ok = all(mod.metros_for_day(real, per, cur.day_for_number(n)) == real_window(real, per, n) for n in range(0, 300, 7))
        check("the cursor's date gives the importer the metros of that business day number", ok)
        check("the importer's business_day_number agrees with the cursor script",
              all(mod.business_day_number(date.fromordinal(date(2026, 1, 5).toordinal() + k)) ==
                  cur.business_day_number(date.fromordinal(date(2026, 1, 5).toordinal() + k)) for k in range(800)))
    print("FAILED: " + ", ".join(FAILS) if FAILS else "all passed")
    return 1 if FAILS else 0


def real_window(metros, per_day, n):
    return [metros[(n * per_day + i) % len(metros)] for i in range(min(per_day, len(metros)))]


if __name__ == "__main__":
    sys.exit(main())

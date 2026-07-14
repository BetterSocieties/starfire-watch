#!/usr/bin/env python3
"""Import decrypted credentials (from N8N_CREDS_IMPORT env, JSON array of
n8n export:credentials --decrypted) into the pod, then rebind every pod
workflow node that references an old credential id to the newly created id.
Idempotent: skips creation when a credential with the same name+type already
exists is not detectable via API (GET /credentials only lists a subset), so
we always create and rebind; stale unbound duplicates are harmless.
"""
import json, os, sys, urllib.request

N8N_URL = os.environ["N8N_URL"].rstrip("/")
KEY = os.environ["N8N_API_KEY"]
CREDS = json.loads(os.environ["N8N_CREDS_IMPORT"])
H = {"X-N8N-API-KEY": KEY, "Content-Type": "application/json"}


def api(method: str, path: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{N8N_URL}/api/v1{path}", data=data, headers=H, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


# 1. create credentials on pod, map old id -> new id
id_map = {}
for c in CREDS:
    body = {"name": c["name"], "type": c["type"], "data": c["data"]}
    code, resp = api("POST", "/credentials", body)
    if code in (200, 201) and resp.get("id"):
        id_map[c["id"]] = {"id": resp["id"], "name": c["name"]}
        print(f"created {c['type']} '{c['name']}' old={c['id']} new={resp['id']}")
    else:
        print(f"FAILED create '{c['name']}' http={code} resp={json.dumps(resp)[:200]}")

if not id_map:
    sys.exit("no credentials created, aborting rebind")

# 2. page all workflows, rebind node credential references
cursor, rebound, checked = "", 0, 0
while True:
    q = f"/workflows?limit=250" + (f"&cursor={cursor}" if cursor else "")
    code, page = api("GET", q)
    if code != 200:
        sys.exit(f"workflow paging failed http={code}")
    for wf in page.get("data", []):
        checked += 1
        code, full = api("GET", f"/workflows/{wf['id']}")
        if code != 200:
            continue
        changed = False
        for node in full.get("nodes", []):
            for ctype, ref in (node.get("credentials") or {}).items():
                old = ref.get("id")
                if old in id_map:
                    ref["id"] = id_map[old]["id"]
                    ref["name"] = id_map[old]["name"]
                    changed = True
        if changed:
            body = {"name": full["name"], "nodes": full["nodes"],
                    "connections": full["connections"], "settings": full.get("settings") or {}}
            code, resp = api("PUT", f"/workflows/{wf['id']}", body)
            if code == 200:
                rebound += 1
            else:
                print(f"REBIND FAILED wf={wf['id']} '{full['name']}' http={code} {json.dumps(resp)[:150]}")
    cursor = page.get("nextCursor") or ""
    if not cursor:
        break

print(f"IMPORT RESULT: created={len(id_map)} workflows_checked={checked} workflows_rebound={rebound}")

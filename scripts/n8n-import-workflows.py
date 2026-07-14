#!/usr/bin/env python3
"""Import brain workflow bodies (packed in N8N_WFS_CHUNK_00..N secrets, gzipped
+ base64-chunked because a single Actions secret caps at ~48KB) into the cloud
pod. Idempotent: identifies pod duplicates by name and updates in place instead
of creating another copy. Skips activation (n8n-fix-pod handles it after).
"""
import base64, gzip, json, os, sys, urllib.request

N8N_URL = os.environ["N8N_URL"].rstrip("/")
KEY = os.environ["N8N_API_KEY"]
H = {"X-N8N-API-KEY": KEY, "Content-Type": "application/json"}


def api(method: str, path: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{N8N_URL}/api/v1{path}", data=data, headers=H, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


# 1. Reassemble packed workflows from chunk env vars
chunks = []
for i in range(64):
    v = os.environ.get(f"WFS_CHUNK_{i:02d}", "")
    if not v:
        break
    chunks.append(v)
if not chunks:
    sys.exit("no chunks found in env (WFS_CHUNK_00..)")
b64 = "".join(chunks)
wfs = json.loads(gzip.decompress(base64.b64decode(b64)).decode())
print(f"unpacked {len(wfs)} workflows from {len(chunks)} chunks")

# 2. Index pod workflows by name (paged)
by_name, cursor = {}, ""
while True:
    q = "/workflows?limit=250" + (f"&cursor={cursor}" if cursor else "")
    code, page = api("GET", q)
    if code != 200:
        sys.exit(f"pod paging failed http={code}")
    for w in page.get("data", []):
        by_name[w["name"]] = w["id"]
    cursor = page.get("nextCursor") or ""
    if not cursor:
        break
print(f"pod has {len(by_name)} unique-named workflows before import")

# 3. Upsert every brain workflow to the pod
created = updated = failed = 0
for wf in wfs:
    body = {
        "name": wf["name"],
        "nodes": wf["nodes"],
        "connections": wf.get("connections", {}),
        "settings": wf.get("settings") or {},
    }
    existing = by_name.get(wf["name"])
    if existing:
        code, resp = api("PUT", f"/workflows/{existing}", body)
        if code == 200:
            updated += 1
        else:
            failed += 1
            print(f"UPDATE FAIL '{wf['name']}' http={code} {json.dumps(resp)[:200]}")
    else:
        code, resp = api("POST", "/workflows", body)
        if code in (200, 201) and resp.get("id"):
            created += 1
        else:
            failed += 1
            print(f"CREATE FAIL '{wf['name']}' http={code} {json.dumps(resp)[:200]}")

print(f"IMPORT-WORKFLOWS RESULT: created={created} updated={updated} failed={failed} total={len(wfs)}")

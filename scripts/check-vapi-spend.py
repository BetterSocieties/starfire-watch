#!/usr/bin/env python3
"""Daily Vapi spend probe for the OpsJuice demo line. Stdlib only, never prints a secret.

Vapi took over the demo line on 2026-10-12 when Retell answered 402. The account runs on Vapi's
$5 free credit and Vapi's API exposes no balance (GET /org answers 401 to a private key), so this
sums call cost since signup with POST /analytics and alerts Slack once spend reaches ALERT_AT,
before the credit runs out and calls start failing the way Annie's did for 67 days.

Env: VAPI_API_KEY, SLACK_BOT_TOKEN. Flags: --dry-run prints the verdict and posts nothing.
Exit 0 healthy, 1 alert posted, 2 alert could not be posted or the probe failed.
"""
import json, os, sys, urllib.error, urllib.request

SIGNUP = "2026-10-12T00:00:00Z"
CREDIT = 5.00
ALERT_AT = 4.00  # ponytail: fixed threshold for the free credit; read the real balance if Vapi ever exposes it
CHANNEL = "C0AJY9J6RSN"
UA = "curl/8.7.1"


def spent(key):
    body = {"queries": [{"table": "call", "name": "spend", "timeRange": {"start": SIGNUP, "timezone": "UTC"},
                         "operations": [{"operation": "sum", "column": "cost", "alias": "sumCost"}]}]}
    req = urllib.request.Request("https://api.vapi.ai/analytics", data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json",
                                          "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        rows = json.load(r)[0]["result"]
    return float(rows[0]["sumCost"] or 0) if rows else 0.0


def alert(token, text):
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=json.dumps({"channel": CHANNEL, "text": text}).encode(),
        method="POST",
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json; charset=utf-8", "User-Agent": UA},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def main():
    dry = "--dry-run" in sys.argv
    try:
        cost = spent(os.environ["VAPI_API_KEY"])
    except (urllib.error.URLError, KeyError, IndexError, ValueError) as e:
        print(f"PROBE FAILED: {e}")
        return 2
    left = CREDIT - cost
    print(f"vapi spent ${cost:.3f} since {SIGNUP[:10]}, about ${left:.2f} of free credit left")
    if cost < ALERT_AT:
        return 0
    text = (f":rotating_light: *OJ demo line: Vapi credit nearly gone (${left:.2f} left)*\n"
            "Calls to the demo number fail when it hits $0. Add credit and turn on auto reload: "
            "https://dashboard.vapi.ai/org/billing")
    if dry:
        return 1
    res = alert(os.environ["SLACK_BOT_TOKEN"], text)
    print(f"slack ok={res.get('ok')} ts={res.get('ts')} error={res.get('error')}")
    return 1 if res.get("ok") else 2


if __name__ == "__main__":
    sys.exit(main())

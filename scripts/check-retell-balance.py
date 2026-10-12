#!/usr/bin/env python3
"""Daily Retell health probe for OpsJuice Annie. Stdlib only, never prints a secret.

Probe: POST /v2/create-web-call for the Annie agent. A usable workspace answers 201 and a web
call nobody joins, which Retell closes as error_user_not_joined after 30 s at no charge. An
exhausted workspace answers 402 "Credit balance exhausted". Any non-2xx result posts to Slack.

Env: RETELL_API_KEY, SLACK_BOT_TOKEN. Flags: --dry-run prints the verdict and posts nothing.
Exit 0 healthy, 1 unhealthy (alert attempted), 2 alert could not be posted.
"""
import json, os, sys, urllib.error, urllib.request

ANNIE_AGENT = "agent_7613f3c51757de55936d3dd334"
CHANNEL = "C0AJY9J6RSN"
UA = "curl/8.7.1"


def probe(key):
    req = urllib.request.Request(
        "https://api.retellai.com/v2/create-web-call",
        data=json.dumps({"agent_id": ANNIE_AGENT}).encode(),
        method="POST",
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json", "User-Agent": UA},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, ""
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:300]


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
    status, body = probe(os.environ["RETELL_API_KEY"])
    if 200 <= status < 300:
        print(f"healthy: create-web-call HTTP {status}")
        return 0
    print(f"UNHEALTHY: create-web-call HTTP {status} {body}")
    text = (
        f":rotating_light: *OJ Annie is down: Retell refused a probe call (HTTP {status})*\n"
        f"Retell said: {body or 'no body'}\n"
        "Every Annie call is dropped as no_valid_payment until credits are bought and auto recharge is on: "
        "https://dashboard.retellai.com/billing"
    )
    if dry:
        return 1
    res = alert(os.environ["SLACK_BOT_TOKEN"], text)
    print(f"slack ok={res.get('ok')} ts={res.get('ts')} error={res.get('error')}")
    return 1 if res.get("ok") else 2


if __name__ == "__main__":
    sys.exit(main())

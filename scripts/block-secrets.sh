#!/usr/bin/env bash
# Refuse to commit a credential into this repo.
#
# This repo is PUBLIC on purpose: cloud sessions have GitHub-only egress, so they
# read data/live-health.json and friends over raw.githubusercontent.com. That same
# property made it the worst possible place for the n8n workflow JSON that cloud
# fires were staging here, because n8n workflow JSON carries credentials inline in
# node code. On 2026-08-07 that had put two live Supabase service_role keys (the BS
# venture tenant and the OpsJuice tenant, row-level security bypassed on both) in
# public view, alongside a Resend key GitHub had been flagging unactioned since
# 2026-07-17.
#
# Removing the files fixed that day. This stops the next fire from redoing it.
# Install: git config core.hooksPath .githooks   (see .githooks/pre-commit)
set -uo pipefail

# Only the staged content is checked, so the hook stays fast and never judges
# files the commit is not actually adding.
FILES=$(git diff --cached --name-only --diff-filter=ACM)
[ -z "$FILES" ] && exit 0

# A JWT is matched by shape and then filtered on its decoded role, because an
# anon key is public by design and blocking it would train people to use --no-verify.
PATTERNS='AIza[0-9A-Za-z_-]{30,}|sk-[A-Za-z0-9]{20,}|sbp_[a-f0-9]{40}|gh[pousr]_[A-Za-z0-9]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|re_[A-Za-z0-9_]{20,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}'

FAILED=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    # service_role is the one that bypasses row-level security entirely.
    if printf '%s' "$hit" | grep -qE '^eyJ'; then
      payload=$(printf '%s' "$hit" | cut -d. -f2)
      # base64url, pad to a multiple of 4 so the decoder accepts it
      while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload="${payload}="; done
      role=$(printf '%s' "$payload" | tr '_-' '/+' | base64 -d 2>/dev/null \
             | grep -oE '"role" *: *"[a-z_]+"' | head -1)
      case "$role" in
        *anon*) continue ;;
      esac
    fi
    echo "BLOCKED: $f carries a credential-shaped string (${hit:0:6}...)" >&2
    FAILED=1
  done < <(grep -ohE "$PATTERNS" "$f" 2>/dev/null | sort -u)
done <<< "$FILES"

if [ "$FAILED" -ne 0 ]; then
  cat >&2 <<'EOF'

This repo is PUBLIC. Anything committed here is world-readable immediately and
stays readable in history afterwards, so a key pushed here must be rotated, not
just deleted.

Stage the data through a private repo, or strip the credential first. If you are
certain the match is a false positive, commit with --no-verify and say why in the
commit message.
EOF
  exit 1
fi
exit 0

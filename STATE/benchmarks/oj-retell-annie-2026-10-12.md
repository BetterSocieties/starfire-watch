# Benchmark: OpsJuice Annie on Retell, call errors (2026-10-12)

## Sources read (live, 2026-10-12)
- Retell, Debug call disconnection (full reason table): https://docs.retellai.com/reliability/debug-call-disconnect
  - no_valid_payment = status error, "no valid payment registered on file, or service shut down due to bill overdue".
  - credit_exhausted, budget_reached, concurrency_limit_reached, error_llm_websocket_* are separate reasons, so a billing wall and an agent fault are distinguishable from the reason alone.
- Retell, Billing (prepaid credits, auto recharge, monthly budget, 2026-09-30 forced move of legacy monthly workspaces to credit billing at $0): https://docs.retellai.com/accounts/billing
- Retell, Handle failed payments: https://docs.retellai.com/accounts/fail-payment
- Community report 1, same reason, inbound and outbound both fail, 0:00 duration: https://community.retellai.com/t/internal-service-error/296
- Community report 2, call refused before it registers, no_valid_payment named as a cause: https://community.retellai.com/t/error-starting-call-when-running-browser-test-call/3639
- Community report 3, calls stop at zero balance until a manual top-up: https://community.retellai.com/t/i-have-0-remaining-credits-and-i-cant-top-up-until-2-feb-when-it-auto-renew-how-can-i-manually-top-up/331 (listed on the report 1 page; title read, thread body not opened)
- Retell, uptime and provider fallback (LLM and voice provider failover): https://www.retellai.com/blog/how-retell-ai-handles-outages-with-a-99-99-uptime (search excerpt only)
- Retell, alert rules for call and chat metrics: https://docs.retellai.com/features/alerting-overview (title and search excerpt only, page not opened)

## What a best-in-class Retell setup does that ours does not yet do
1. Auto recharge on, with a trigger well above one call's cost (a 25 minute Annie call cost $3.63 on 2026-08-06), so the balance never reaches zero. Ours: balance zero since 2026-08-07.
2. Monthly budget alerts at 80 and 100 percent emailed to a watched address. Ours: none seen.
3. Alert rules on error-status calls routed to Slack or WhatsApp. Ours: the n8n engine writes a no_transcript row and stays silent.
4. Inbound fallback so a failed call reaches a human or voicemail instead of dead air. Ours: OJ-Annie-SIP-Router has no fallback branch when register-phone-call is refused.
5. Webhook handling that separates billing errors from agent errors by disconnection_reason. Ours: every error collapses into status no_transcript.
6. Latency: not measurable until a call connects; nothing to compare yet.

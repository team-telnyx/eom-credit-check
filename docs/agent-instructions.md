# EOM Credit Check — Agent Instructions

## Purpose
Run the end-of-month credit limit check on the 27th of each month and post alerts to Slack.

## Cron Setup
Schedule: `0 9 27 * *` (9:00 AM CT on the 27th)

### OpenClaw Cron Command
```
cd ~/clawd/skills/eom-credit-check && source .env && bash scripts/eom-credit-check.sh | bash scripts/post-alerts.sh
```

## What It Does
1. Reads customer list from `config/config.json`
2. Queries the billing A2A agent for each customer's balance, usage, MRC, and daily run rate
3. Calculates: `Remaining = Credit Limit - |Balance| - MRC - (4 × daily rate)`
   ⚠️ **Do NOT subtract usage separately** — Telnyx is pay-as-you-go; usage is already in the balance in real-time.
4. Posts alerts to Slack for any customer with Remaining < $0
5. Escalates critical cases (severe shortfall) to the escalation channel

## Required Environment
- `SLACK_BOT_TOKEN` — Bot token with `chat:write` scope
- `CONFIG_PATH` — Path to config JSON (defaults to `./config/config.json`)
- Network access to `revenue-agents.query.prod.telnyx.io:8000`

## Troubleshooting
- **No response from billing agent**: Check VPN/network connectivity to internal services
- **Parse errors**: The billing agent may return free-text instead of JSON; check raw response in output
- **Slack post fails**: Verify bot token and that the bot is invited to both channels

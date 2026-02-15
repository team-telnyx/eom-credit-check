# SKILL: EOM Credit Check

## Name
eom-credit-check

## Description
End-of-month credit limit monitor. Checks all credit-limit customers to predict if they'll exhaust credit before the next billing cycle. Auto-escalates to Slack when shortfalls are detected.

## Schedule
Cron: `0 9 27 * *` (9:00 AM on the 27th of each month)

## Commands
```bash
# Run credit check, output JSON to stdout
bash scripts/eom-credit-check.sh

# Save results to file for audit trail
bash scripts/eom-credit-check.sh --output results.json

# Dry run — query the agent but skip any side effects
bash scripts/eom-credit-check.sh --dry-run

# Run and post alerts to Slack
bash scripts/eom-credit-check.sh | bash scripts/post-alerts.sh

# Dry run alerts — prints what would be posted without sending
bash scripts/eom-credit-check.sh | bash scripts/post-alerts.sh --dry-run
```

## Environment Variables
| Variable | Required | Description |
|----------|----------|-------------|
| `SLACK_BOT_TOKEN` | Yes | Slack bot token with `chat:write` scope |
| `CONFIG_PATH` | No | Path to config JSON (default: `./config/config.json`) |
| `DRY_RUN` | No | Set `true` to enable dry-run mode for either script |
| `A2A_URL` | No | Override the billing agent URL (default from config or built-in fallback) |

## Built-in Resilience
- **Config validation** runs at startup — catches missing/invalid settings early
- **Retry logic** — 3 attempts with exponential backoff on transient failures
- **Curl timeouts** — 10s connect, 30s max per request
- **A2A URL** is configurable via config file, `A2A_URL` env var, or built-in default

## Dependencies
- `bash`, `curl`, `jq`
- Network access to `revenue-agents.query.prod.telnyx.io:8000`

## Author
team-telnyx / CSM team

## Tags
billing, credit-limit, monitoring, slack, cron

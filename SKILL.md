# SKILL: EOM Credit Check

## Name
eom-credit-check

## Description
End-of-month credit limit monitor. Checks all credit-limit customers to predict if they'll exhaust credit before the next billing cycle. Auto-escalates to Slack when shortfalls are detected.

## Schedule
Cron: `0 9 27 * *` (9:00 AM on the 27th of each month)

## Commands
- `bash scripts/eom-credit-check.sh` — Run credit check, output JSON results
- `bash scripts/eom-credit-check.sh | bash scripts/post-alerts.sh` — Run and post alerts to Slack

## Environment Variables
| Variable | Required | Description |
|----------|----------|-------------|
| `SLACK_BOT_TOKEN` | Yes | Slack bot token with `chat:write` scope |
| `CONFIG_PATH` | No | Path to config JSON (default: `./config/config.json`) |

## Dependencies
- `bash`, `curl`, `jq`
- Network access to `revenue-agents.query.prod.telnyx.io:8000`

## Author
team-telnyx / CSM team

## Tags
billing, credit-limit, monitoring, slack, cron

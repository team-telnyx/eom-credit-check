# EOM Credit Check (Credit Limit Monitor)

Automated end-of-month credit limit monitor for Telnyx CSMs. Runs on the 27th of each month to identify customers who may exhaust their credit before the next billing cycle, and escalates to Slack.

## How It Works

For each customer in your config, the tool queries the Telnyx billing A2A agent and calculates:

```
Remaining = Credit Limit - |Current Balance| - Current Month Usage - Next Month MRC - (4 × Daily Run Rate)
```

It also detects **auto-recharge status** and **VIP/priority status** from the billing agent, then assigns a risk level to each flagged customer.

If **Remaining < threshold** (default: $0), an alert is posted to Slack with the customer name, shortfall amount, auto-recharge/VIP status, risk level, and a suggested credit limit increase.

## Risk Levels

When a customer's projected remaining credit is negative, risk is assessed based on protective factors:

| Risk | Condition | Escalation |
|------|-----------|------------|
| ✅ OK | Remaining ≥ 0 | None |
| ⚠️ Low (protected) | Remaining < 0 + VIP + auto-recharge | Alert only |
| ⚠️ Medium | Remaining < 0 + one of VIP or auto-recharge | Alert only |
| 🚨 HIGH | Remaining < 0 + neither VIP nor auto-recharge | Alert + auto-escalate to #customersuccess-finance |

Only **🚨 HIGH** risk customers are auto-escalated. VIP and auto-recharge customers have safety nets that reduce urgency.

## Quick Start (10 minutes)

### 1. Clone & Configure

```bash
git clone https://github.com/team-telnyx/telnyx-clawdbot-skills.git
cd telnyx-clawdbot-skills/skills/eom-credit-check

# Create your config from the template
cp config/example-config.json config/config.json
# Edit config/config.json with your actual customer data
```

### 2. Set Environment Variables

```bash
cp .env.example .env
# Edit .env with your actual values:
#   SLACK_BOT_TOKEN=xoxb-your-token
#   CONFIG_PATH=./config/config.json  (optional, this is the default)
```

### 3. Run Manually

```bash
# Check credit — outputs JSON results
bash scripts/eom-credit-check.sh

# Post alerts to Slack
bash scripts/eom-credit-check.sh | bash scripts/post-alerts.sh
```

### 4. Set Up as OpenClaw Cron Job

Add a cron job in OpenClaw to run on the 27th of each month. See `memory/agents/eom-credit-check.md` for agent instructions.

## Config File Format

See `config/example-config.json` for the full template. Key sections:

| Section | Description |
|---------|-------------|
| `customers` | Array of `{name, org_id, credit_limit, currency}` |
| `slack.alert_channel` | Channel ID for alerts |
| `slack.escalation_channel` | Channel ID for critical escalations |
| `thresholds.alert_remaining` | Dollar amount below which to alert (default: `0`) |
| `settings.credit_increase_pct` | Suggested increase % (default: `10`) |
| `settings.buffer_days` | Days of run-rate buffer (default: `4`) |

## Requirements

- `bash`, `curl`, `jq`
- Access to the Telnyx billing A2A agent (internal network)
- Slack bot token with `chat:write` scope
- OpenClaw (for automated cron scheduling)

## Security

- **No secrets in the repo.** All tokens via environment variables.
- **No customer data in the repo.** All customer info via your local config file.
- `config/config.json` and `.env` are gitignored.

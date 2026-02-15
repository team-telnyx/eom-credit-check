#!/usr/bin/env bash
# EOM Credit Check — queries billing agent and calculates remaining credit
# Output: JSON array of results to stdout
set -euo pipefail

CONFIG_PATH="${CONFIG_PATH:-./config/config.json}"
A2A_URL="http://revenue-agents.query.prod.telnyx.io:8000/a2a/billing-account/rpc"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: Config file not found at $CONFIG_PATH" >&2
  echo "Copy config/example-config.json to config/config.json and fill in your data." >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required. Install with: brew install jq" >&2
  exit 1
fi

BUFFER_DAYS=$(jq -r '.settings.buffer_days // 4' "$CONFIG_PATH")
THRESHOLD=$(jq -r '.thresholds.alert_remaining // 0' "$CONFIG_PATH")
INCREASE_PCT=$(jq -r '.settings.credit_increase_pct // 10' "$CONFIG_PATH")
ALERT_CHANNEL=$(jq -r '.slack.alert_channel' "$CONFIG_PATH")
ESCALATION_CHANNEL=$(jq -r '.slack.escalation_channel' "$CONFIG_PATH")
CUSTOMER_COUNT=$(jq '.customers | length' "$CONFIG_PATH")

results="[]"

for i in $(seq 0 $((CUSTOMER_COUNT - 1))); do
  name=$(jq -r ".customers[$i].name" "$CONFIG_PATH")
  org_id=$(jq -r ".customers[$i].org_id" "$CONFIG_PATH")
  credit_limit=$(jq -r ".customers[$i].credit_limit" "$CONFIG_PATH")
  currency=$(jq -r ".customers[$i].currency" "$CONFIG_PATH")

  echo "Checking $name ($org_id)..." >&2

  msg_id="eom-check-$(date +%s)-$i"
  query="For org $org_id, provide the following as JSON: current_balance, current_month_usage, next_month_mrc, daily_run_rate, has_autorecharge_enabled (true/false), is_vip (true if priority is VIP/never auto-disabled, false otherwise). Use numeric values for amounts, booleans for flags."

  response=$(curl -s -X POST "$A2A_URL" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg mid "$msg_id" \
      --arg query "$query" \
      '{
        jsonrpc: "2.0",
        id: $mid,
        method: "message/send",
        params: {
          message: {
            messageId: $mid,
            role: "user",
            parts: [{ kind: "text", text: $query }]
          }
        }
      }')" 2>/dev/null || echo '{"error":"request_failed"}')

  # Extract the text response from A2A result
  agent_text=$(echo "$response" | jq -r '
    .result.artifacts[0].parts[0].text //
    .result.message.parts[0].text //
    .result.parts[0].text //
    empty' 2>/dev/null || echo "")

  if [[ -z "$agent_text" ]]; then
    echo "  WARNING: No response from billing agent for $name" >&2
    results=$(echo "$results" | jq \
      --arg name "$name" \
      --arg org "$org_id" \
      '. + [{
        customer: $name,
        org_id: $org,
        status: "error",
        error: "No response from billing agent"
      }]')
    continue
  fi

  # Parse numeric fields from agent response (expects JSON in the text)
  current_balance=$(echo "$agent_text" | jq -r '.current_balance // empty' 2>/dev/null || echo "")
  current_month_usage=$(echo "$agent_text" | jq -r '.current_month_usage // empty' 2>/dev/null || echo "")
  next_month_mrc=$(echo "$agent_text" | jq -r '.next_month_mrc // empty' 2>/dev/null || echo "")
  daily_run_rate=$(echo "$agent_text" | jq -r '.daily_run_rate // empty' 2>/dev/null || echo "")
  has_autorecharge=$(echo "$agent_text" | jq -r '.has_autorecharge_enabled // false' 2>/dev/null || echo "false")
  is_vip=$(echo "$agent_text" | jq -r '.is_vip // false' 2>/dev/null || echo "false")

  # If agent didn't return clean JSON, try extracting numbers from text
  if [[ -z "$current_balance" ]]; then
    echo "  WARNING: Could not parse structured data for $name. Raw response logged." >&2
    results=$(echo "$results" | jq \
      --arg name "$name" \
      --arg org "$org_id" \
      --arg raw "$agent_text" \
      '. + [{
        customer: $name,
        org_id: $org,
        status: "parse_error",
        raw_response: $raw
      }]')
    continue
  fi

  # Formula: Remaining = Credit Limit - |Current Balance| - Current Month Usage - Next Month MRC - (buffer_days × daily run rate)
  remaining=$(echo "$credit_limit $current_balance $current_month_usage $next_month_mrc $daily_run_rate $BUFFER_DAYS" | \
    awk '{
      abs_balance = ($2 < 0) ? -$2 : $2
      remaining = $1 - abs_balance - $3 - $4 - ($6 * $5)
      printf "%.2f", remaining
    }')

  alert=$(echo "$remaining $THRESHOLD" | awk '{ print ($1 < $2) ? "true" : "false" }')

  suggested_limit=""
  if [[ "$alert" == "true" ]]; then
    suggested_limit=$(echo "$credit_limit $INCREASE_PCT" | awk '{ printf "%.2f", $1 * (1 + $2/100) }')
  fi

  # Determine risk level
  if [[ $(echo "$remaining" | awk '{ print ($1 >= 0) ? "ok" : "negative" }') == "ok" ]]; then
    risk_level="OK"
  elif [[ "$is_vip" == "true" && "$has_autorecharge" == "true" ]]; then
    risk_level="Low (protected)"
  elif [[ "$is_vip" == "true" || "$has_autorecharge" == "true" ]]; then
    risk_level="Medium"
  else
    risk_level="HIGH"
  fi

  results=$(echo "$results" | jq \
    --arg name "$name" \
    --arg org "$org_id" \
    --arg currency "$currency" \
    --argjson credit_limit "$credit_limit" \
    --argjson current_balance "${current_balance}" \
    --argjson usage "${current_month_usage}" \
    --argjson mrc "${next_month_mrc}" \
    --argjson drr "${daily_run_rate}" \
    --argjson remaining "$remaining" \
    --argjson alert "$alert" \
    --arg suggested "$suggested_limit" \
    --argjson buffer "$BUFFER_DAYS" \
    --argjson has_autorecharge "$has_autorecharge" \
    --argjson is_vip "$is_vip" \
    --arg risk_level "$risk_level" \
    '. + [{
      customer: $name,
      org_id: $org,
      currency: $currency,
      credit_limit: $credit_limit,
      current_balance: $current_balance,
      current_month_usage: $usage,
      next_month_mrc: $mrc,
      daily_run_rate: $drr,
      buffer_days: $buffer,
      remaining: $remaining,
      alert: $alert,
      has_autorecharge: $has_autorecharge,
      is_vip: $is_vip,
      risk_level: $risk_level,
      suggested_credit_limit: (if $suggested != "" then ($suggested | tonumber) else null end),
      status: "ok"
    }]')

  if [[ "$alert" == "true" ]]; then
    echo "  ⚠️  ALERT: $name — shortfall of $currency $(echo "$remaining" | tr -d '-')" >&2
  else
    echo "  ✅ $name — $currency $remaining remaining" >&2
  fi
done

# Build final output with metadata
jq -n \
  --argjson results "$results" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg alert_channel "$ALERT_CHANNEL" \
  --arg escalation_channel "$ESCALATION_CHANNEL" \
  --argjson threshold "$THRESHOLD" \
  '{
    timestamp: $timestamp,
    alert_channel: $alert_channel,
    escalation_channel: $escalation_channel,
    threshold: $threshold,
    results: $results
  }'

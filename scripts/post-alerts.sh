#!/usr/bin/env bash
# Post EOM credit check alerts to Slack
# Reads JSON from stdin (output of eom-credit-check.sh)
set -euo pipefail

if [[ -z "${SLACK_BOT_TOKEN:-}" ]]; then
  echo "ERROR: SLACK_BOT_TOKEN is not set" >&2
  exit 1
fi

input=$(cat)
alert_channel=$(echo "$input" | jq -r '.alert_channel')
escalation_channel=$(echo "$input" | jq -r '.escalation_channel')
timestamp=$(echo "$input" | jq -r '.timestamp')

alerts=$(echo "$input" | jq '[.results[] | select(.alert == true)]')
errors=$(echo "$input" | jq '[.results[] | select(.status != "ok")]')
alert_count=$(echo "$alerts" | jq 'length')
error_count=$(echo "$errors" | jq 'length')
total=$(echo "$input" | jq '.results | length')

if [[ "$alert_count" -eq 0 && "$error_count" -eq 0 ]]; then
  echo "✅ All $total customers within credit limits. No alerts to post." >&2
  exit 0
fi

# Build alert message
message="🔴 *EOM Credit Check — $timestamp*\n$alert_count of $total customers flagged\n"

for i in $(seq 0 $((alert_count - 1))); do
  row=$(echo "$alerts" | jq ".[$i]")
  name=$(echo "$row" | jq -r '.customer')
  currency=$(echo "$row" | jq -r '.currency')
  remaining=$(echo "$row" | jq -r '.remaining')
  credit_limit=$(echo "$row" | jq -r '.credit_limit')
  suggested=$(echo "$row" | jq -r '.suggested_credit_limit // "N/A"')
  shortfall=$(echo "$remaining" | tr -d '-')
  has_autorecharge=$(echo "$row" | jq -r '.has_autorecharge // false')
  is_vip=$(echo "$row" | jq -r '.is_vip // false')
  risk_level=$(echo "$row" | jq -r '.risk_level // "HIGH"')

  # Format auto-recharge and VIP indicators
  if [[ "$has_autorecharge" == "true" ]]; then ar_icon="✅ ON"; else ar_icon="❌ OFF"; fi
  if [[ "$is_vip" == "true" ]]; then vip_icon="✅ VIP"; else vip_icon="❌ No"; fi

  # Risk level icon
  case "$risk_level" in
    "OK") risk_icon="✅ OK" ;;
    "Low (protected)") risk_icon="⚠️ Low (protected)" ;;
    "Medium") risk_icon="⚠️ Medium" ;;
    *) risk_icon="🚨 HIGH" ;;
  esac

  message+="\n• *$name*: Shortfall of $currency $shortfall"
  message+=" | Auto-Recharge: $ar_icon | VIP: $vip_icon | Risk: $risk_icon"
  message+=" (limit: $currency $credit_limit → suggested: $currency $suggested)"
done

if [[ "$error_count" -gt 0 ]]; then
  message+="\n\n⚠️ $error_count customer(s) had errors — check logs."
fi

# Post to alert channel
post_to_slack() {
  local channel="$1"
  local text="$2"
  curl -s -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg channel "$channel" --arg text "$text" \
      '{ channel: $channel, text: $text, mrkdwn: true }')" \
    | jq -r 'if .ok then "Posted to " + .channel else "FAILED: " + .error end' >&2
}

echo "Posting to alert channel ($alert_channel)..." >&2
post_to_slack "$alert_channel" "$message"

# Escalate only 🚨 HIGH risk customers (negative remaining + no VIP + no auto-recharge)
critical=$(echo "$alerts" | jq '[.[] | select(.risk_level == "HIGH")]')
critical_count=$(echo "$critical" | jq 'length')

if [[ "$critical_count" -gt 0 ]]; then
  esc_message="🚨 *CRITICAL ESCALATION — $critical_count customer(s) at HIGH risk (no auto-recharge, no VIP)*\n"
  for i in $(seq 0 $((critical_count - 1))); do
    row=$(echo "$critical" | jq ".[$i]")
    name=$(echo "$row" | jq -r '.customer')
    currency=$(echo "$row" | jq -r '.currency')
    remaining=$(echo "$row" | jq -r '.remaining')
    esc_message+="\n• *$name*: $currency $remaining projected remaining"
  done

  echo "Escalating $critical_count HIGH risk case(s) to ($escalation_channel)..." >&2
  post_to_slack "$escalation_channel" "$esc_message"
fi

echo "Done. $alert_count alert(s) posted." >&2

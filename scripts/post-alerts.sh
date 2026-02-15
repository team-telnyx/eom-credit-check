#!/usr/bin/env bash
# Post EOM credit check alerts to Slack
# Reads JSON from stdin (output of eom-credit-check.sh)
set -euo pipefail

# --- Dry-run support ---
DRY_RUN="${DRY_RUN:-false}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ "$DRY_RUN" != "true" && -z "${SLACK_BOT_TOKEN:-}" ]]; then
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

# Build summary message (batched — all customers in one message)
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

  if [[ "$has_autorecharge" == "true" ]]; then ar_icon="✅ ON"; else ar_icon="❌ OFF"; fi
  if [[ "$is_vip" == "true" ]]; then vip_icon="✅ VIP"; else vip_icon="❌ No"; fi

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

# --- Post helper (respects dry-run) ---
post_to_slack() {
  local channel="$1"
  local text="$2"
  local thread_ts="${3:-}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Would post to $channel${thread_ts:+ (thread $thread_ts)}:" >&2
    echo -e "  $text" >&2
    echo '{"ok":true,"ts":"dry-run"}' 
    return 0
  fi

  local payload
  if [[ -n "$thread_ts" ]]; then
    payload=$(jq -n --arg channel "$channel" --arg text "$text" --arg ts "$thread_ts" \
      '{ channel: $channel, text: $text, mrkdwn: true, thread_ts: $ts }')
  else
    payload=$(jq -n --arg channel "$channel" --arg text "$text" \
      '{ channel: $channel, text: $text, mrkdwn: true }')
  fi

  curl --connect-timeout 10 --max-time 30 -s -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

# Post summary message to alert channel
echo "Posting summary to alert channel ($alert_channel)..." >&2
summary_response=$(post_to_slack "$alert_channel" "$message")
summary_ts=$(echo "$summary_response" | jq -r '.ts // empty' 2>/dev/null || true)

# Post threaded details for each HIGH risk customer
high_risk=$(echo "$alerts" | jq '[.[] | select(.risk_level == "HIGH")]')
high_risk_count=$(echo "$high_risk" | jq 'length')

if [[ "$high_risk_count" -gt 0 && -n "$summary_ts" ]]; then
  for i in $(seq 0 $((high_risk_count - 1))); do
    row=$(echo "$high_risk" | jq ".[$i]")
    name=$(echo "$row" | jq -r '.customer')
    org_id=$(echo "$row" | jq -r '.org_id')
    currency=$(echo "$row" | jq -r '.currency')
    remaining=$(echo "$row" | jq -r '.remaining')
    credit_limit=$(echo "$row" | jq -r '.credit_limit')
    usage=$(echo "$row" | jq -r '.current_month_usage')
    mrc=$(echo "$row" | jq -r '.next_month_mrc')
    drr=$(echo "$row" | jq -r '.daily_run_rate')
    suggested=$(echo "$row" | jq -r '.suggested_credit_limit // "N/A"')

    thread_msg="🚨 *$name* — HIGH RISK\n"
    thread_msg+="Org: \`$org_id\`\n"
    thread_msg+="Credit Limit: $currency $credit_limit\n"
    thread_msg+="Current Usage: $currency $usage | MRC: $currency $mrc | Daily Rate: $currency $drr\n"
    thread_msg+="Projected Remaining: $currency $remaining\n"
    thread_msg+="Suggested Limit: $currency $suggested\n"
    thread_msg+="Action: Auto-recharge OFF, not VIP — needs manual review"

    echo "  Threading detail for $name..." >&2
    post_to_slack "$alert_channel" "$thread_msg" "$summary_ts" > /dev/null
  done
fi

# Escalate HIGH risk to escalation channel
if [[ "$high_risk_count" -gt 0 ]]; then
  esc_message="🚨 *CRITICAL ESCALATION — $high_risk_count customer(s) at HIGH risk (no auto-recharge, no VIP)*\n"
  for i in $(seq 0 $((high_risk_count - 1))); do
    row=$(echo "$high_risk" | jq ".[$i]")
    name=$(echo "$row" | jq -r '.customer')
    currency=$(echo "$row" | jq -r '.currency')
    remaining=$(echo "$row" | jq -r '.remaining')
    esc_message+="\n• *$name*: $currency $remaining projected remaining"
  done

  echo "Escalating $high_risk_count HIGH risk case(s) to ($escalation_channel)..." >&2
  post_to_slack "$escalation_channel" "$esc_message" > /dev/null
fi

echo "Done. $alert_count alert(s) posted." >&2

#!/usr/bin/env bash
# EOM Credit Check — queries billing agent and calculates remaining credit
# Output: JSON array of results to stdout
set -euo pipefail

# --- Flags ---
OUTPUT_FILE=""
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

CONFIG_PATH="${CONFIG_PATH:-./config/config.json}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: Config file not found at $CONFIG_PATH" >&2
  echo "Copy config/example-config.json to config/config.json and fill in your data." >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required. Install with: brew install jq" >&2
  exit 1
fi

# --- Config validation ---
if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
  echo "ERROR: $CONFIG_PATH is not valid JSON" >&2
  exit 1
fi

missing_fields=()
if [[ "$(jq 'has("customers") and (.customers | type == "array")' "$CONFIG_PATH")" != "true" ]]; then
  missing_fields+=("customers (array)")
fi
if [[ "$(jq 'has("slack") and (.slack | has("alert_channel"))' "$CONFIG_PATH")" != "true" ]]; then
  missing_fields+=("slack.alert_channel")
fi
if [[ "$(jq 'has("slack") and (.slack | has("escalation_channel"))' "$CONFIG_PATH")" != "true" ]]; then
  missing_fields+=("slack.escalation_channel")
fi
if [[ ${#missing_fields[@]} -gt 0 ]]; then
  echo "ERROR: Config missing required fields: ${missing_fields[*]}" >&2
  exit 1
fi

# --- A2A URL: config → env → hardcoded default ---
A2A_URL=$(jq -r '.a2a.billing_url // empty' "$CONFIG_PATH" 2>/dev/null || true)
A2A_URL="${A2A_URL:-${A2A_ENDPOINT:-http://revenue-agents.query.prod.telnyx.io:8000/a2a/billing-account/rpc}}"

# --- Retry wrapper (3 attempts, exponential backoff) ---
retry_curl() {
  local attempt=1 max=3 delay=2
  while true; do
    local output
    output=$(curl --connect-timeout 10 --max-time 30 -s -X POST "$A2A_URL" \
      -H "Content-Type: application/json" \
      -d "$1" 2>/dev/null) && { echo "$output"; return 0; }
    if [[ $attempt -ge $max ]]; then
      echo '{"error":"request_failed"}'; return 1
    fi
    echo "  Retry $attempt/$max after ${delay}s..." >&2
    sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}

# --- Send a single A2A query and return the text response ---
a2a_query() {
  local msg_id="$1" query="$2"
  local payload
  payload=$(jq -n \
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
    }')

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] Would query: $query" >&2
    echo ""
    return 0
  fi

  local response
  response=$(retry_curl "$payload")

  echo "$response" | jq -r '
    .result.artifacts[0].parts[0].text //
    .result.message.parts[0].text //
    .result.parts[0].text //
    empty' 2>/dev/null || echo ""
}

# --- Extract a number from text near a keyword ---
# Usage: extract_number "response text" "keyword1|keyword2"
# Handles A2A prose like "Balance: -$46,891.29" or "**Balance:** -$46,891.29 USD"
# Also handles "approximately 59%" or "$1,205/day" style responses
extract_number() {
  local text="$1" pattern="$2"
  local result=""

  # Strategy 1: Find line containing keyword, then extract the first dollar amount or number on that line
  result=$(echo "$text" | grep -iE "$pattern" | head -1 | \
    grep -oE '[-]?\$?[0-9][0-9,]*\.?[0-9]*' | head -1 | tr -d '$,' || echo "")

  # Strategy 2: If strategy 1 failed, look for keyword followed by amount within 30 chars
  if [[ -z "$result" ]]; then
    result=$(echo "$text" | tr '\n' ' ' | \
      grep -ioE "${pattern}[^0-9\$-]{0,30}[-\$]{0,2}[0-9][0-9,]*\.?[0-9]*" | head -1 | \
      grep -oE '[-]?\$?[0-9][0-9,]*\.?[0-9]*' | head -1 | tr -d '$,' || echo "")
  fi

  # Strategy 3: For balance specifically, look for negative dollar amounts
  if [[ -z "$result" && "$pattern" =~ balance ]]; then
    result=$(echo "$text" | grep -oE '[-]\$[0-9][0-9,]*\.?[0-9]*' | head -1 | tr -d '$,' || echo "")
  fi

  echo "$result"
}

# --- Extract boolean from text near a keyword ---
extract_bool() {
  local text="$1" pattern="$2"
  local snippet
  snippet=$(echo "$text" | grep -ioE "${pattern}[^.]{0,40}" | head -1 || echo "")
  if echo "$snippet" | grep -iqE '(yes|true|enabled|active|is vip|is a vip|has auto|with auto)'; then
    echo "true"
  elif echo "$snippet" | grep -iqE '(no|false|disabled|inactive|not vip|not a vip|no auto|without auto)'; then
    echo "false"
  else
    # Fallback: check the whole text for the pattern
    if echo "$text" | grep -iqE "(${pattern}).{0,20}(yes|true|enabled|active)"; then
      echo "true"
    else
      echo "false"
    fi
  fi
}

BUFFER_DAYS=$(jq -r '.settings.buffer_days // 4' "$CONFIG_PATH")
THRESHOLD=$(jq -r '.thresholds.alert_remaining // 0' "$CONFIG_PATH")
INCREASE_PCT=$(jq -r '.settings.credit_increase_pct // 10' "$CONFIG_PATH")
ALERT_CHANNEL=$(jq -r '.slack.alert_channel' "$CONFIG_PATH")
ESCALATION_CHANNEL=$(jq -r '.slack.escalation_channel' "$CONFIG_PATH")
CUSTOMER_COUNT=$(jq '.customers | length' "$CONFIG_PATH")

results="[]"
at_risk_count=0

for i in $(seq 0 $((CUSTOMER_COUNT - 1))); do
  name=$(jq -r ".customers[$i].name" "$CONFIG_PATH")
  org_id=$(jq -r ".customers[$i].org_id" "$CONFIG_PATH")
  credit_limit=$(jq -r ".customers[$i].credit_limit" "$CONFIG_PATH")
  currency=$(jq -r ".customers[$i].currency" "$CONFIG_PATH")

  echo "Checking $name ($org_id)..." >&2

  ts=$(date +%s)

  # --- Query 1: Balance, credit limit, available credit ---
  echo "  Query 1/3: balance & credit..." >&2
  q1_text=$(a2a_query "eom-${ts}-${i}-q1" \
    "What is the current balance, credit limit, and available credit for org ${org_id}?")

  # --- Query 2: Usage, MRC, daily run rate ---
  echo "  Query 2/3: usage & MRC..." >&2
  q2_text=$(a2a_query "eom-${ts}-${i}-q2" \
    "What is the current month's total usage, MRC (monthly recurring charges), and daily usage run rate for org ${org_id}?")

  # --- Query 3: Auto-recharge, VIP status ---
  echo "  Query 3/3: auto-recharge & VIP..." >&2
  q3_text=$(a2a_query "eom-${ts}-${i}-q3" \
    "Does org ${org_id} have auto-recharge enabled? What is their VIP/priority status?")

  # Check if we got at least Q1 back
  if [[ -z "$q1_text" && "$DRY_RUN" != "true" ]]; then
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
    at_risk_count=$((at_risk_count + 1))
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    results=$(echo "$results" | jq \
      --arg name "$name" \
      --arg org "$org_id" \
      '. + [{
        customer: $name,
        org_id: $org,
        status: "dry_run"
      }]')
    continue
  fi

  # --- Parse Q1: balance, credit limit (from agent), available credit ---
  current_balance=$(extract_number "$q1_text" "balance")
  agent_credit_limit=$(extract_number "$q1_text" "credit.limit")
  available_credit=$(extract_number "$q1_text" "available")

  # Use config credit_limit as authoritative, but log if agent disagrees
  if [[ -n "$agent_credit_limit" ]]; then
    diff_check=$(awk "BEGIN { d = $credit_limit - $agent_credit_limit; print (d < 0 ? -d : d) }")
    if awk "BEGIN { exit ($diff_check > 1) ? 0 : 1 }" 2>/dev/null; then
      echo "  NOTE: Agent reports credit limit $agent_credit_limit vs config $credit_limit" >&2
    fi
  fi

  # --- Parse Q2: usage, MRC, daily run rate ---
  # The agent returns detailed breakdowns. Try multiple patterns.
  # For usage: look for "Usage Charges:" or "total usage" or "Net Total"
  current_month_usage=$(extract_number "$q2_text" "usage.charges|total.usage|net.total")
  # If we got a negative net total (credits applied), try just usage charges
  if [[ -z "$current_month_usage" || "$current_month_usage" == "0" ]]; then
    current_month_usage=$(extract_number "$q2_text" "usage")
  fi

  # For MRC: look for "Monthly Recurring" or "MRC:" 
  next_month_mrc=$(extract_number "$q2_text" "monthly.recurring|MRC|recurring.charge")
  
  # For daily run rate: look for "Daily Usage" or "daily run rate" or "$X/day" or "Average Daily"
  daily_run_rate=$(extract_number "$q2_text" "daily.usage|daily.run|average.daily")
  # Fallback: look for pattern like $1,205/day
  if [[ -z "$daily_run_rate" ]]; then
    daily_run_rate=$(echo "$q2_text" | grep -oE '\$[0-9,]+\.?[0-9]*/day' | head -1 | tr -d '$/day,' || echo "")
  fi

  # --- Parse Q3: auto-recharge, VIP ---
  has_autorecharge=$(extract_bool "$q3_text" "auto.?recharge")
  is_vip=$(extract_bool "$q3_text" "vip|priority")

  # --- Validate we got the critical numbers ---
  if [[ -z "$current_balance" || -z "$current_month_usage" || -z "$daily_run_rate" ]]; then
    echo "  WARNING: Could not parse all fields for $name" >&2
    echo "    Q1: $q1_text" >&2
    echo "    Q2: $q2_text" >&2
    echo "    Q3: $q3_text" >&2
    results=$(echo "$results" | jq \
      --arg name "$name" \
      --arg org "$org_id" \
      --arg q1 "$q1_text" \
      --arg q2 "$q2_text" \
      --arg q3 "$q3_text" \
      '. + [{
        customer: $name,
        org_id: $org,
        status: "parse_error",
        raw_q1: $q1,
        raw_q2: $q2,
        raw_q3: $q3
      }]')
    at_risk_count=$((at_risk_count + 1))
    continue
  fi

  # Default MRC to 0 if not found (some accounts may not have it)
  next_month_mrc="${next_month_mrc:-0}"

  # Formula: Remaining = Credit Limit - |Current Balance| - MRC - (buffer_days × daily run rate)
  # NOTE: Telnyx is pay-as-you-go — usage hits the balance in real-time and is already in |Balance|.
  # DO NOT subtract current_month_usage separately; doing so double-counts it and creates false alerts.
  # current_month_usage is still fetched above to calculate the daily_run_rate.
  remaining=$(echo "$credit_limit $current_balance $next_month_mrc $daily_run_rate $BUFFER_DAYS" | \
    awk '{
      abs_balance = ($2 < 0) ? -$2 : $2
      remaining = $1 - abs_balance - $3 - ($5 * $4)
      printf "%.2f", remaining
    }')

  alert=$(echo "$remaining $THRESHOLD" | awk '{ print ($1 < $2) ? "true" : "false" }')

  suggested_limit=""
  if [[ "$alert" == "true" ]]; then
    suggested_limit=$(echo "$credit_limit $INCREASE_PCT" | awk '{ printf "%.2f", $1 * (1 + $2/100) }')
    at_risk_count=$((at_risk_count + 1))
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
final_output=$(jq -n \
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
  }')

echo "$final_output"

# Save to file if --output was specified
if [[ -n "$OUTPUT_FILE" ]]; then
  echo "$final_output" > "$OUTPUT_FILE"
  echo "📁 Results saved to $OUTPUT_FILE" >&2
fi

echo "✅ EOM Credit Check completed: $CUSTOMER_COUNT customers checked, $at_risk_count at risk" >&2

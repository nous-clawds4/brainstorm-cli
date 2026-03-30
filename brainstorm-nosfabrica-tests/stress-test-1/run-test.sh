#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Stress Test 1 — Burst Follow Propagation
# ═══════════════════════════════════════════════════════════════════════════
#
# Publishes kind:3 follow events from multiple sender accounts in a burst,
# then monitors propagation across the full NosFabrica pipeline.
#
# Uses a nonce-based rotation to ensure every run publishes a genuinely
# different follow list, eliminating the need for reset.sh between runs.
#
# Nonce rotation (100 accounts, 10 senders, 10 targets):
#   - Each nonce increment slides the target window by 1
#   - When targets hit the ceiling, sender window shifts by 1 and
#     targets reset (avoiding sender/target overlap)
#   - When all combinations are exhausted, a full reset is required
#
# Usage:
#   ./run-test.sh                          # auto-derive from nonce
#   ./run-test.sh --senders 1-10 --targets 11-20   # manual override (skips nonce)
#
# Requires: setup.sh has been run first (accounts.json + keys.env populated)
#
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_ENV="$HOME/.config/nosfabrica-tests/keys.env"
ACCOUNTS_FILE="$SCRIPT_DIR/accounts.json"
STATE_FILE="$SCRIPT_DIR/state.json"
RESULTS_DIR="$SCRIPT_DIR/results"

mkdir -p "$RESULTS_DIR"

# ─── Configuration ──────────────────────────────────────────────────────────
TOTAL_ACCOUNTS=100        # total accounts available (from setup.sh)
WINDOW_SIZE=10            # number of senders and targets per run

GATEWAY_RELAY="wss://wot.grapevine.network"
PROD_RELAY="wss://neofry.nosfabrica.com"
STAGING_RELAY="wss://neofry-staging.nosfabrica.com"
PROD_API="https://brainstormserver.nosfabrica.com"
STAGING_API="https://brainstormserver-staging.nosfabrica.com"
PUBLISH_RELAYS=("wss://relay.primal.net" "wss://relay.damus.io" "wss://nos.lol" "wss://purplepag.es" "ws://localhost:7777")

BURST_INTERVAL=6         # seconds between each sender's publish
INITIAL_WAIT=30          # seconds after last publish before first check
RETRY_INTERVAL=60        # seconds between monitoring rounds
MAX_ELAPSED=3600         # maximum seconds before giving up

# ─── Parse Arguments ───────────────────────────────────────────────────────
MANUAL_OVERRIDE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --senders)
      MANUAL_SENDER_START="${2%%-*}"
      MANUAL_SENDER_END="${2##*-}"
      MANUAL_OVERRIDE=true
      shift 2
      ;;
    --targets)
      MANUAL_TARGET_START="${2%%-*}"
      MANUAL_TARGET_END="${2##*-}"
      MANUAL_OVERRIDE=true
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--senders START-END] [--targets START-END]"
      exit 1
      ;;
  esac
done

# ─── Nonce-based range derivation ──────────────────────────────────────────
if $MANUAL_OVERRIDE; then
  SENDER_START="${MANUAL_SENDER_START:-1}"
  SENDER_END="${MANUAL_SENDER_END:-10}"
  TARGET_START="${MANUAL_TARGET_START:-11}"
  TARGET_END="${MANUAL_TARGET_END:-20}"
  USE_NONCE=false
else
  # Read current nonce
  if [ -f "$STATE_FILE" ]; then
    NONCE=$(jq -r '.nonce // 0' "$STATE_FILE")
  else
    NONCE=0
  fi

  # Derive ranges from nonce
  # With TOTAL_ACCOUNTS=100 and WINDOW_SIZE=10:
  #   - Senders occupy WINDOW_SIZE slots, targets occupy WINDOW_SIZE slots
  #   - For a given sender position, targets can slide from
  #     (sender_end+1) to (TOTAL_ACCOUNTS - WINDOW_SIZE + 1)
  #   - max_target_slides = TOTAL_ACCOUNTS - sender_start - 2*WINDOW_SIZE + 1
  #     (first sender_start=1: 100 - 1 - 20 + 1 = 80 slides, i.e. target_offset 0..80)

  # Sender offset = how many times we've shifted senders (0-based)
  # Max sender positions: TOTAL_ACCOUNTS - 2*WINDOW_SIZE + 1 = 81
  MAX_SENDER_POSITIONS=$((TOTAL_ACCOUNTS - 2 * WINDOW_SIZE + 1))

  # For each sender position, how many target slides are available?
  # sender_start = 1 + sender_offset
  # target_floor = sender_start + WINDOW_SIZE = 1 + sender_offset + WINDOW_SIZE
  # target_ceiling_start = TOTAL_ACCOUNTS - WINDOW_SIZE + 1
  # slides = target_ceiling_start - target_floor + 1
  #        = TOTAL_ACCOUNTS - WINDOW_SIZE + 1 - (1 + sender_offset + WINDOW_SIZE) + 1
  #        = TOTAL_ACCOUNTS - 2*WINDOW_SIZE + 1 - sender_offset
  #        = MAX_SENDER_POSITIONS - sender_offset

  # Walk through sender positions to find which one this nonce falls in
  REMAINING_NONCE=$NONCE
  SENDER_OFFSET=0
  EXHAUSTED=false

  while [ "$SENDER_OFFSET" -lt "$MAX_SENDER_POSITIONS" ]; do
    SLIDES_FOR_THIS_SENDER=$((MAX_SENDER_POSITIONS - SENDER_OFFSET))
    if [ "$REMAINING_NONCE" -lt "$SLIDES_FOR_THIS_SENDER" ]; then
      break
    fi
    REMAINING_NONCE=$((REMAINING_NONCE - SLIDES_FOR_THIS_SENDER))
    SENDER_OFFSET=$((SENDER_OFFSET + 1))
  done

  if [ "$SENDER_OFFSET" -ge "$MAX_SENDER_POSITIONS" ]; then
    echo "❌ All nonce combinations exhausted (nonce=$NONCE)."
    echo "   Run ./reset.sh to clear follow lists and reset the nonce to 0."
    exit 1
  fi

  TARGET_OFFSET=$REMAINING_NONCE

  SENDER_START=$((1 + SENDER_OFFSET))
  SENDER_END=$((SENDER_START + WINDOW_SIZE - 1))
  TARGET_START=$((SENDER_END + 1 + TARGET_OFFSET))
  TARGET_END=$((TARGET_START + WINDOW_SIZE - 1))

  USE_NONCE=true
fi

NUM_SENDERS=$((SENDER_END - SENDER_START + 1))
NUM_TARGETS=$((TARGET_END - TARGET_START + 1))

TIMESTAMP=$(date -u +"%Y-%m-%d_%H-%M-%S")
RESULT_FILE="$RESULTS_DIR/${TIMESTAMP}.json"

# ─── Validate prerequisites ────────────────────────────────────────────────
if [ ! -f "$ACCOUNTS_FILE" ]; then
  echo "❌ accounts.json not found. Run ./setup.sh first."
  exit 1
fi

if [ ! -f "$KEYS_ENV" ]; then
  echo "❌ keys.env not found at $KEYS_ENV. Run ./setup.sh first."
  exit 1
fi

# shellcheck disable=SC1090
source "$KEYS_ENV"

# ─── Helper Functions ───────────────────────────────────────────────────────

# Get nsec for account by index (1-based)
get_account_nsec() {
  local idx="$1"
  local padded
  padded=$(printf "%03d" "$idx")
  local var_name="STRESS_ACCOUNT_${padded}_NSEC"
  echo "${!var_name:-}"
}

# Get hex pubkey for account by index from accounts.json
get_account_hex() {
  local idx="$1"
  jq -r ".[$((idx-1))].hex_pubkey" "$ACCOUNTS_FILE"
}

# Count follows for a pubkey on a relay
count_follows_relay() {
  local relay="$1"
  local hex="$2"
  local result
  result=$(nak req --author "$hex" --kind 3 "$relay" 2>/dev/null \
    | jq '[.tags[] | select(.[0]=="p")] | length' 2>/dev/null)
  echo "${result:-0}"
}

# Authenticate with Brainstorm API
get_auth_token() {
  local api_base="$1"
  local hex_pubkey="$2"
  local nsec="$3"

  local challenge
  challenge=$(curl -sf "$api_base/authChallenge/$hex_pubkey" 2>/dev/null \
    | jq -r '.data.challenge') || { echo ""; return; }
  [ -z "$challenge" ] || [ "$challenge" = "null" ] && { echo ""; return; }

  local signed_event
  signed_event=$(nak event --sec "$nsec" \
    -k 22242 -c "" \
    -t t=brainstorm_login \
    -t challenge="$challenge" 2>/dev/null) || { echo ""; return; }
  [ -z "$signed_event" ] && { echo ""; return; }

  local token
  token=$(curl -sf -X POST \
    -H "Content-Type: application/json" \
    -d "{\"signed_event\": $signed_event}" \
    "$api_base/authChallenge/$hex_pubkey/verify" 2>/dev/null \
    | jq -r '.data.token') || { echo ""; return; }
  echo "${token:-}"
}

# Count follows from Brainstorm API
count_follows_api() {
  local api_base="$1"
  local token="$2"
  local hex="$3"
  local result
  result=$(curl -sf -H "access_token: $token" \
    "$api_base/user/$hex" 2>/dev/null \
    | jq '.data.following | length' 2>/dev/null)
  echo "${result:-0}"
}

echo "═══════════════════════════════════════════════════════════"
echo "  Stress Test 1 — Burst Follow Propagation"
echo "  $TIMESTAMP"
echo "═══════════════════════════════════════════════════════════"
echo "  Senders: accounts $SENDER_START–$SENDER_END ($NUM_SENDERS)"
echo "  Targets: accounts $TARGET_START–$TARGET_END ($NUM_TARGETS)"
echo "  Burst interval: ${BURST_INTERVAL}s"
if $USE_NONCE 2>/dev/null; then
  echo "  Nonce: $NONCE (auto-derived ranges)"
else
  echo "  Nonce: manual override (ranges specified via --senders/--targets)"
fi
echo "═══════════════════════════════════════════════════════════"
echo ""

# ─── Build target list ──────────────────────────────────────────────────────
TARGET_HEXES=()
for i in $(seq "$TARGET_START" "$TARGET_END"); do
  TARGET_HEXES+=("$(get_account_hex "$i")")
done

# Build p-tag args for publishing (reused by every sender)
TARGET_P_ARGS=()
for hex in "${TARGET_HEXES[@]}"; do
  TARGET_P_ARGS+=("-p" "$hex")
done

# ─── Step 1: Baseline ──────────────────────────────────────────────────────
echo "📊 Step 1: Querying baseline follow counts for all senders..."
echo ""

# We'll track state per sender in parallel arrays
declare -a SENDER_HEXES=()
declare -a SENDER_NSECS=()
declare -a BASE_GW=()
declare -a BASE_PROD=()
declare -a BASE_STAGING=()
declare -a BASE_PROD_API=()
declare -a BASE_STAGING_API=()
declare -a PUBLISH_TIMES=()

# Authenticate with APIs using the first sender (tokens are per-user but
# we need one per sender for the API; we'll batch-auth later during monitoring)
# For baseline, just use relay counts — API baseline done per-sender below.

for i in $(seq "$SENDER_START" "$SENDER_END"); do
  IDX=$((i - SENDER_START))
  HEX=$(get_account_hex "$i")
  NSEC=$(get_account_nsec "$i")

  if [ -z "$NSEC" ]; then
    echo "❌ No nsec found for account $i ($HEX). Run ./setup.sh first."
    exit 1
  fi

  SENDER_HEXES[$IDX]="$HEX"
  SENDER_NSECS[$IDX]="$NSEC"

  BASE_GW[$IDX]=$(count_follows_relay "$GATEWAY_RELAY" "$HEX")
  BASE_PROD[$IDX]=$(count_follows_relay "$PROD_RELAY" "$HEX")
  BASE_STAGING[$IDX]=$(count_follows_relay "$STAGING_RELAY" "$HEX")
  BASE_PROD_API[$IDX]=0
  BASE_STAGING_API[$IDX]=0

  echo "   Account #$i ($HEX): gw=${BASE_GW[$IDX]} prod=${BASE_PROD[$IDX]} staging=${BASE_STAGING[$IDX]}"
done
echo ""

# Authenticate each sender with both APIs for baseline + monitoring
echo "🔐 Authenticating senders with Brainstorm APIs..."
declare -a PROD_TOKENS=()
declare -a STAGING_TOKENS=()

for i in $(seq "$SENDER_START" "$SENDER_END"); do
  IDX=$((i - SENDER_START))
  HEX="${SENDER_HEXES[$IDX]}"
  NSEC="${SENDER_NSECS[$IDX]}"

  PROD_TOKENS[$IDX]=$(get_auth_token "$PROD_API" "$HEX" "$NSEC")
  STAGING_TOKENS[$IDX]=$(get_auth_token "$STAGING_API" "$HEX" "$NSEC")

  if [ -n "${PROD_TOKENS[$IDX]}" ] && [ "${PROD_TOKENS[$IDX]}" != "null" ]; then
    BASE_PROD_API[$IDX]=$(count_follows_api "$PROD_API" "${PROD_TOKENS[$IDX]}" "$HEX")
  fi
  if [ -n "${STAGING_TOKENS[$IDX]}" ] && [ "${STAGING_TOKENS[$IDX]}" != "null" ]; then
    BASE_STAGING_API[$IDX]=$(count_follows_api "$STAGING_API" "${STAGING_TOKENS[$IDX]}" "$HEX")
  fi

  echo "   Account #$i: prod_api=${BASE_PROD_API[$IDX]} staging_api=${BASE_STAGING_API[$IDX]}"
done
echo ""

# ─── Step 2: Burst publish ─────────────────────────────────────────────────
echo "📤 Step 2: Burst publishing kind:3 events (${BURST_INTERVAL}s apart)..."
echo ""

BURST_START=$(date +%s)

for i in $(seq "$SENDER_START" "$SENDER_END"); do
  IDX=$((i - SENDER_START))
  NSEC="${SENDER_NSECS[$IDX]}"

  PUB_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  PUBLISH_TIMES[$IDX]="$PUB_TIME"

  echo -n "   Account #$i publishing at $PUB_TIME ... "
  nak event --sec "$NSEC" -k 3 -c "" "${TARGET_P_ARGS[@]}" "${PUBLISH_RELAYS[@]}" 2>/dev/null | tail -1
  echo "done"

  # Wait between events (except after last)
  if [ "$i" -lt "$SENDER_END" ]; then
    sleep "$BURST_INTERVAL"
  fi
done

BURST_END=$(date +%s)
BURST_DURATION=$((BURST_END - BURST_START))
echo ""
echo "   ✅ All $NUM_SENDERS events published in ${BURST_DURATION}s"
echo ""

# ─── Step 3: Monitor propagation ───────────────────────────────────────────
echo "⏳ Waiting ${INITIAL_WAIT}s before first check..."
sleep "$INITIAL_WAIT"

# Track per-sender per-endpoint: current counts, verdicts, first-pass time
declare -a CUR_GW=() CUR_PROD=() CUR_STAGING=() CUR_PROD_API=() CUR_STAGING_API=()
declare -a FIRST_PASS_GW=() FIRST_PASS_PROD=() FIRST_PASS_STAGING=() FIRST_PASS_PROD_API=() FIRST_PASS_STAGING_API=()

for i in $(seq 0 $((NUM_SENDERS - 1))); do
  FIRST_PASS_GW[$i]=""
  FIRST_PASS_PROD[$i]=""
  FIRST_PASS_STAGING[$i]=""
  FIRST_PASS_PROD_API[$i]=""
  FIRST_PASS_STAGING_API[$i]=""
done

ROUND=0
ROUNDS_JSON="["
MONITOR_START=$(date +%s)

query_all_senders() {
  local round_num="$1"
  local elapsed="$2"

  echo "📊 Round $round_num (T+${elapsed}s)"

  local round_senders="["
  local all_passed=true

  for i in $(seq 0 $((NUM_SENDERS - 1))); do
    local acct_num=$((SENDER_START + i))
    local hex="${SENDER_HEXES[$i]}"

    CUR_GW[$i]=$(count_follows_relay "$GATEWAY_RELAY" "$hex")
    CUR_PROD[$i]=$(count_follows_relay "$PROD_RELAY" "$hex")
    CUR_STAGING[$i]=$(count_follows_relay "$STAGING_RELAY" "$hex")
    CUR_PROD_API[$i]=0
    CUR_STAGING_API[$i]=0

    if [ -n "${PROD_TOKENS[$i]}" ] && [ "${PROD_TOKENS[$i]}" != "null" ]; then
      CUR_PROD_API[$i]=$(count_follows_api "$PROD_API" "${PROD_TOKENS[$i]}" "$hex")
    fi
    if [ -n "${STAGING_TOKENS[$i]}" ] && [ "${STAGING_TOKENS[$i]}" != "null" ]; then
      CUR_STAGING_API[$i]=$(count_follows_api "$STAGING_API" "${STAGING_TOKENS[$i]}" "$hex")
    fi

    # Determine verdicts (PASS = count increased)
    local v_gw="FAIL" v_prod="FAIL" v_staging="FAIL" v_prod_api="FAIL" v_staging_api="FAIL"

    if [ "${CUR_GW[$i]}" -gt "${BASE_GW[$i]}" ] 2>/dev/null; then
      v_gw="PASS"
      [ -z "${FIRST_PASS_GW[$i]}" ] && FIRST_PASS_GW[$i]="$elapsed"
    fi
    if [ "${CUR_PROD[$i]}" -gt "${BASE_PROD[$i]}" ] 2>/dev/null; then
      v_prod="PASS"
      [ -z "${FIRST_PASS_PROD[$i]}" ] && FIRST_PASS_PROD[$i]="$elapsed"
    fi
    if [ "${CUR_STAGING[$i]}" -gt "${BASE_STAGING[$i]}" ] 2>/dev/null; then
      v_staging="PASS"
      [ -z "${FIRST_PASS_STAGING[$i]}" ] && FIRST_PASS_STAGING[$i]="$elapsed"
    fi
    if [ "${CUR_PROD_API[$i]}" -gt "${BASE_PROD_API[$i]}" ] 2>/dev/null; then
      v_prod_api="PASS"
      [ -z "${FIRST_PASS_PROD_API[$i]}" ] && FIRST_PASS_PROD_API[$i]="$elapsed"
    fi
    if [ "${CUR_STAGING_API[$i]}" -gt "${BASE_STAGING_API[$i]}" ] 2>/dev/null; then
      v_staging_api="PASS"
      [ -z "${FIRST_PASS_STAGING_API[$i]}" ] && FIRST_PASS_STAGING_API[$i]="$elapsed"
    fi

    # N/A cascade: if gateway fails, downstream is N/A
    if [ "$v_gw" = "FAIL" ]; then
      [ "$v_prod" = "FAIL" ] && v_prod="N/A"
      [ "$v_staging" = "FAIL" ] && v_staging="N/A"
    fi
    if [ "$v_prod" != "PASS" ]; then
      [ "$v_prod_api" = "FAIL" ] && v_prod_api="N/A"
    fi
    if [ "$v_staging" != "PASS" ]; then
      [ "$v_staging_api" = "FAIL" ] && v_staging_api="N/A"
    fi

    # Check if any still failing
    for v in "$v_gw" "$v_prod" "$v_staging" "$v_prod_api" "$v_staging_api"; do
      [ "$v" = "FAIL" ] && all_passed=false
    done

    local status_char="✅"
    for v in "$v_gw" "$v_prod" "$v_staging" "$v_prod_api" "$v_staging_api"; do
      [ "$v" = "FAIL" ] && status_char="❌" && break
    done

    echo "   #$acct_num $status_char gw=$v_gw prod=$v_prod stg=$v_staging p_api=$v_prod_api s_api=$v_staging_api"

    [ "$i" -gt 0 ] && round_senders="$round_senders,"
    round_senders="$round_senders{\"index\":$acct_num,\"counts\":{\"gateway_relay\":${CUR_GW[$i]},\"prod_relay\":${CUR_PROD[$i]},\"staging_relay\":${CUR_STAGING[$i]},\"prod_api\":${CUR_PROD_API[$i]},\"staging_api\":${CUR_STAGING_API[$i]}},\"verdicts\":{\"gateway_relay\":\"$v_gw\",\"prod_relay\":\"$v_prod\",\"staging_relay\":\"$v_staging\",\"prod_api\":\"$v_prod_api\",\"staging_api\":\"$v_staging_api\"}}"
  done
  round_senders="$round_senders]"

  echo ""

  # Append round to JSON
  [ "$round_num" -gt 1 ] && ROUNDS_JSON="$ROUNDS_JSON,"
  ROUNDS_JSON="$ROUNDS_JSON{\"round\":$round_num,\"elapsed_seconds\":$elapsed,\"senders\":$round_senders}"

  if $all_passed; then
    return 0
  else
    return 1
  fi
}

# First check
ROUND=1
ELAPSED=$(($(date +%s) - BURST_START))
if query_all_senders "$ROUND" "$ELAPSED"; then
  ALL_DONE=true
else
  ALL_DONE=false
fi

# Retry loop
while ! $ALL_DONE; do
  ELAPSED=$(($(date +%s) - BURST_START))
  if [ "$ELAPSED" -ge "$MAX_ELAPSED" ]; then
    echo "⏰ Maximum elapsed time (${MAX_ELAPSED}s) reached."
    break
  fi

  REMAINING=$((MAX_ELAPSED - ELAPSED))
  WAIT=$((RETRY_INTERVAL < REMAINING ? RETRY_INTERVAL : REMAINING))

  echo "⏳ Waiting ${WAIT}s until next check (elapsed: ${ELAPSED}s)..."
  sleep "$WAIT"

  ROUND=$((ROUND + 1))
  ELAPSED=$(($(date +%s) - BURST_START))
  if query_all_senders "$ROUND" "$ELAPSED"; then
    ALL_DONE=true
  fi
done

ROUNDS_JSON="$ROUNDS_JSON]"
TOTAL_ELAPSED=$(($(date +%s) - BURST_START))

# ─── Build final results ───────────────────────────────────────────────────

# Per-sender summary
SENDERS_JSON="["
STAGES_PASSED_GW=0 STAGES_PASSED_PROD=0 STAGES_PASSED_STAGING=0 STAGES_PASSED_PROD_API=0 STAGES_PASSED_STAGING_API=0
TOTAL_PASS_GW=0 TOTAL_PASS_PROD=0 TOTAL_PASS_STAGING=0 TOTAL_PASS_PROD_API=0 TOTAL_PASS_STAGING_API=0

for i in $(seq 0 $((NUM_SENDERS - 1))); do
  acct_num=$((SENDER_START + i))
  hex="${SENDER_HEXES[$i]}"

  fp_gw="${FIRST_PASS_GW[$i]:-null}"
  fp_prod="${FIRST_PASS_PROD[$i]:-null}"
  fp_staging="${FIRST_PASS_STAGING[$i]:-null}"
  fp_prod_api="${FIRST_PASS_PROD_API[$i]:-null}"
  fp_staging_api="${FIRST_PASS_STAGING_API[$i]:-null}"

  # Final verdicts
  v_gw="FAIL"; [ -n "${FIRST_PASS_GW[$i]}" ] && v_gw="PASS" && STAGES_PASSED_GW=$((STAGES_PASSED_GW + 1))
  v_prod="FAIL"; [ -n "${FIRST_PASS_PROD[$i]}" ] && v_prod="PASS" && STAGES_PASSED_PROD=$((STAGES_PASSED_PROD + 1))
  v_staging="FAIL"; [ -n "${FIRST_PASS_STAGING[$i]}" ] && v_staging="PASS" && STAGES_PASSED_STAGING=$((STAGES_PASSED_STAGING + 1))
  v_prod_api="FAIL"; [ -n "${FIRST_PASS_PROD_API[$i]}" ] && v_prod_api="PASS" && STAGES_PASSED_PROD_API=$((STAGES_PASSED_PROD_API + 1))
  v_staging_api="FAIL"; [ -n "${FIRST_PASS_STAGING_API[$i]}" ] && v_staging_api="PASS" && STAGES_PASSED_STAGING_API=$((STAGES_PASSED_STAGING_API + 1))

  # Sum for averages
  [ "$fp_gw" != "null" ] && TOTAL_PASS_GW=$((TOTAL_PASS_GW + fp_gw))
  [ "$fp_prod" != "null" ] && TOTAL_PASS_PROD=$((TOTAL_PASS_PROD + fp_prod))
  [ "$fp_staging" != "null" ] && TOTAL_PASS_STAGING=$((TOTAL_PASS_STAGING + fp_staging))
  [ "$fp_prod_api" != "null" ] && TOTAL_PASS_PROD_API=$((TOTAL_PASS_PROD_API + fp_prod_api))
  [ "$fp_staging_api" != "null" ] && TOTAL_PASS_STAGING_API=$((TOTAL_PASS_STAGING_API + fp_staging_api))

  [ "$i" -gt 0 ] && SENDERS_JSON="$SENDERS_JSON,"
  SENDERS_JSON="$SENDERS_JSON
  {
    \"index\": $acct_num,
    \"hex_pubkey\": \"$hex\",
    \"target_count\": $NUM_TARGETS,
    \"publish_time_utc\": \"${PUBLISH_TIMES[$i]}\",
    \"baseline\": {
      \"gateway_relay\": ${BASE_GW[$i]},
      \"prod_relay\": ${BASE_PROD[$i]},
      \"staging_relay\": ${BASE_STAGING[$i]},
      \"prod_api\": ${BASE_PROD_API[$i]},
      \"staging_api\": ${BASE_STAGING_API[$i]}
    },
    \"final_counts\": {
      \"gateway_relay\": ${CUR_GW[$i]},
      \"prod_relay\": ${CUR_PROD[$i]},
      \"staging_relay\": ${CUR_STAGING[$i]},
      \"prod_api\": ${CUR_PROD_API[$i]},
      \"staging_api\": ${CUR_STAGING_API[$i]}
    },
    \"final_verdicts\": {
      \"gateway_relay\": \"$v_gw\",
      \"prod_relay\": \"$v_prod\",
      \"staging_relay\": \"$v_staging\",
      \"prod_api\": \"$v_prod_api\",
      \"staging_api\": \"$v_staging_api\"
    },
    \"first_pass_seconds\": {
      \"gateway_relay\": $fp_gw,
      \"prod_relay\": $fp_prod,
      \"staging_relay\": $fp_staging,
      \"prod_api\": $fp_prod_api,
      \"staging_api\": $fp_staging_api
    }
  }"
done
SENDERS_JSON="$SENDERS_JSON
]"

# Compute averages (integer division)
avg_gw=0; [ "$STAGES_PASSED_GW" -gt 0 ] && avg_gw=$((TOTAL_PASS_GW / STAGES_PASSED_GW))
avg_prod=0; [ "$STAGES_PASSED_PROD" -gt 0 ] && avg_prod=$((TOTAL_PASS_PROD / STAGES_PASSED_PROD))
avg_staging=0; [ "$STAGES_PASSED_STAGING" -gt 0 ] && avg_staging=$((TOTAL_PASS_STAGING / STAGES_PASSED_STAGING))
avg_prod_api=0; [ "$STAGES_PASSED_PROD_API" -gt 0 ] && avg_prod_api=$((TOTAL_PASS_PROD_API / STAGES_PASSED_PROD_API))
avg_staging_api=0; [ "$STAGES_PASSED_STAGING_API" -gt 0 ] && avg_staging_api=$((TOTAL_PASS_STAGING_API / STAGES_PASSED_STAGING_API))

ALL_PASSED_FINAL=true
for v in "$STAGES_PASSED_GW" "$STAGES_PASSED_PROD" "$STAGES_PASSED_STAGING" "$STAGES_PASSED_PROD_API" "$STAGES_PASSED_STAGING_API"; do
  [ "$v" -lt "$NUM_SENDERS" ] && ALL_PASSED_FINAL=false
done

# Determine nonce value for results
if $USE_NONCE 2>/dev/null; then
  NONCE_JSON="$NONCE"
else
  NONCE_JSON="null"
fi

cat > "$RESULT_FILE" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "timestamp_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "config": {
    "nonce": $NONCE_JSON,
    "sender_range": "${SENDER_START}-${SENDER_END}",
    "target_range": "${TARGET_START}-${TARGET_END}",
    "num_senders": $NUM_SENDERS,
    "num_targets": $NUM_TARGETS,
    "burst_interval_seconds": $BURST_INTERVAL,
    "initial_wait_seconds": $INITIAL_WAIT,
    "retry_interval_seconds": $RETRY_INTERVAL,
    "max_elapsed_seconds": $MAX_ELAPSED
  },
  "senders": $SENDERS_JSON,
  "rounds": $ROUNDS_JSON,
  "summary": {
    "total_senders": $NUM_SENDERS,
    "total_events_published": $NUM_SENDERS,
    "all_passed": $ALL_PASSED_FINAL,
    "total_elapsed_seconds": $TOTAL_ELAPSED,
    "total_rounds": $ROUND,
    "burst_duration_seconds": $BURST_DURATION,
    "stages_passed": {
      "gateway_relay": $STAGES_PASSED_GW,
      "prod_relay": $STAGES_PASSED_PROD,
      "staging_relay": $STAGES_PASSED_STAGING,
      "prod_api": $STAGES_PASSED_PROD_API,
      "staging_api": $STAGES_PASSED_STAGING_API
    },
    "stages_failed": {
      "gateway_relay": $((NUM_SENDERS - STAGES_PASSED_GW)),
      "prod_relay": $((NUM_SENDERS - STAGES_PASSED_PROD)),
      "staging_relay": $((NUM_SENDERS - STAGES_PASSED_STAGING)),
      "prod_api": $((NUM_SENDERS - STAGES_PASSED_PROD_API)),
      "staging_api": $((NUM_SENDERS - STAGES_PASSED_STAGING_API))
    },
    "avg_propagation_seconds": {
      "gateway_relay": $avg_gw,
      "prod_relay": $avg_prod,
      "staging_relay": $avg_staging,
      "prod_api": $avg_prod_api,
      "staging_api": $avg_staging_api
    }
  }
}
EOF

echo "═══════════════════════════════════════════════════════════"
echo "  Results Summary"
echo "═══════════════════════════════════════════════════════════"
echo "  Senders: $NUM_SENDERS  |  Rounds: $ROUND  |  Elapsed: ${TOTAL_ELAPSED}s"
echo "  Burst duration: ${BURST_DURATION}s"
echo ""
echo "  Stages passed (out of $NUM_SENDERS):"
echo "    Gateway relay:  $STAGES_PASSED_GW   (avg ${avg_gw}s)"
echo "    Prod relay:     $STAGES_PASSED_PROD   (avg ${avg_prod}s)"
echo "    Staging relay:  $STAGES_PASSED_STAGING   (avg ${avg_staging}s)"
echo "    Prod API:       $STAGES_PASSED_PROD_API   (avg ${avg_prod_api}s)"
echo "    Staging API:    $STAGES_PASSED_STAGING_API   (avg ${avg_staging_api}s)"
echo ""

if $ALL_PASSED_FINAL; then
  echo "  ✅ All senders propagated to all endpoints!"
else
  echo "  ⚠️  Some senders did not fully propagate within ${MAX_ELAPSED}s"
fi

echo ""
echo "📁 Results saved to: $RESULT_FILE"

# ─── Increment nonce ───────────────────────────────────────────────────────
if $USE_NONCE 2>/dev/null; then
  NEW_NONCE=$((NONCE + 1))
  echo "{\"nonce\": $NEW_NONCE}" > "$STATE_FILE"
  echo "🔢 Nonce incremented: $NONCE → $NEW_NONCE"
fi

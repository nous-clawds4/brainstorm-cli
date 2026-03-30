#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# New Brainstorm Customer Test
# ═══════════════════════════════════════════════════════════════════════════
#
# End-to-end test of the new customer onboarding pipeline:
#   1. Create a new nostr identity (kind:0 profile, kind:3 follows)
#   2. Register with Brainstorm staging (creates observer, triggers GrapeRank)
#   3. Fetch NIP-85 setup data and publish kind 10040 event
#   4. Monitor the designated relay for kind 30382 Trusted Assertions
#
# Expected: ~10 min for first TAs to appear, ~15-20 min to stabilize,
# on the order of 100,000 TAs.
#
# Usage:
#   ./run-test.sh
#
# Prerequisites: nak, jq, curl
#
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_ENV="$HOME/.config/nosfabrica-tests/keys.env"
RESULTS_DIR="$SCRIPT_DIR/results"
STATE_FILE="$SCRIPT_DIR/state.json"

mkdir -p "$RESULTS_DIR"

# ─── Configuration ──────────────────────────────────────────────────────────
STAGING_API="https://brainstormserver-staging.nosfabrica.com"
PUBLISH_RELAYS=("wss://relay.primal.net" "wss://relay.damus.io" "wss://nos.lol" "wss://purplepag.es")

# Popular accounts to follow (well-known nostr pubkeys)
# We'll pick 5 at random from this pool
POPULAR_ACCOUNTS=(
  "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"  # fiatjaf
  "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2"  # jack
  "32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245"  # jb55
  "e88a691e98d9987c964521dff60025f60700378a4879180dcbbb4a5027850411"  # NVK
  "04c915daefee38317fa734444acee390a8269fe5810b2241e5e6dd343dfbecc9"  # odell
  "472f440f29ef996e92a186b8d320ff180c855903882e59d50de1b8bd5669301e"  # MartyBent
  "1577e4599dd10c863498fe3c20bd82aafaf829a595ce83c5cf8ac3463531b09b"  # yegorpetrov
  "fa984bd7dbb282f07e16e7ae87b26a2a7b9b90b7246a44771f0cf5ae58018f52"  # pablof7z
  "7fa56f5d6962ab1e3cd424e758c3002b8665f7b0d8dcee9fe9e288d7751ac194"  # verbiricha
  "50d94fc2d8580c682b071a542f8b1e31a200b0508bab95a33bef0855df281d63"  # calle
  "c48e29f04b482cc01ca1f9ef8c86ef8318c059e0e9353235162f080f26e14c11"  # Walker
  "e5272de914bd301755c439b88e6959a43c9d2664831f093c51e9c799a16a102f"  # straycat (Dave)
)

MONITOR_INTERVAL=60       # seconds between TA count checks
MAX_ELAPSED=3600          # maximum seconds before giving up (60 min)

TIMESTAMP=$(date -u +"%Y-%m-%d_%H-%M-%S")
RESULT_FILE="$RESULTS_DIR/${TIMESTAMP}.json"

# ─── Read state (test run counter) ─────────────────────────────────────────
if [ -f "$STATE_FILE" ]; then
  RUN_NUMBER=$(jq -r '.run_number // 0' "$STATE_FILE")
else
  RUN_NUMBER=0
fi
RUN_NUMBER=$((RUN_NUMBER + 1))

# ─── Helper Functions ───────────────────────────────────────────────────────

# Pick N random elements from an array (macOS/GNU compatible)
pick_random() {
  local count="$1"
  shift
  local arr=("$@")
  local len=${#arr[@]}
  local picked=()
  local indices=()

  while [ ${#picked[@]} -lt "$count" ] && [ ${#picked[@]} -lt "$len" ]; do
    local idx=$((RANDOM % len))
    # Check if already picked
    local dup=false
    for i in "${indices[@]+"${indices[@]}"}"; do
      [ "$i" = "$idx" ] && dup=true && break
    done
    if ! $dup; then
      indices+=("$idx")
      picked+=("${arr[$idx]}")
    fi
  done

  echo "${picked[@]}"
}

echo "═══════════════════════════════════════════════════════════"
echo "  New Brainstorm Customer Test"
echo "  $TIMESTAMP"
echo "  Run #$RUN_NUMBER"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1: Create new nostr identity
# ═══════════════════════════════════════════════════════════════════════════
echo "🔑 Step 1: Creating new nostr identity..."

NSEC=$(nak key generate 2>/dev/null)
HEX_PUBKEY=$(echo "$NSEC" | nak key public 2>/dev/null)
NPUB=$(nak encode npub "$HEX_PUBKEY" 2>/dev/null)

echo "   Pubkey (hex): $HEX_PUBKEY"
echo "   Pubkey (npub): $NPUB"

# Store nsec in keys.env
KEY_VAR="NEW_CUSTOMER_${RUN_NUMBER}_NSEC"
touch "$KEYS_ENV"
if ! grep -q "^${KEY_VAR}=" "$KEYS_ENV" 2>/dev/null; then
  echo "${KEY_VAR}=${NSEC}" >> "$KEYS_ENV"
  echo "   nsec saved to keys.env as $KEY_VAR"
else
  echo "   nsec already in keys.env as $KEY_VAR"
fi

# Publish kind:0 profile
echo ""
echo "📝 Publishing kind:0 profile..."
PROFILE_CONTENT="{\"name\":\"Brainstorm Test Customer #${RUN_NUMBER}\",\"about\":\"Automated test account for NosFabrica Brainstorm pipeline testing.\",\"display_name\":\"Test Customer ${RUN_NUMBER}\"}"

nak event --sec "$NSEC" -k 0 -c "$PROFILE_CONTENT" "${PUBLISH_RELAYS[@]}" 2>/dev/null | tail -1
echo "   ✅ kind:0 published"

# Pick 5 random popular accounts to follow
FOLLOWS=($(pick_random 5 "${POPULAR_ACCOUNTS[@]}"))
echo ""
echo "👥 Following 5 random popular accounts:"
for f in "${FOLLOWS[@]}"; do
  echo "   - $f"
done

# Build p-tag args
FOLLOW_P_ARGS=()
for f in "${FOLLOWS[@]}"; do
  FOLLOW_P_ARGS+=("-p" "$f")
done

# Publish kind:3 follow list
echo ""
echo "📝 Publishing kind:3 follow list..."
nak event --sec "$NSEC" -k 3 -c "" "${FOLLOW_P_ARGS[@]}" "${PUBLISH_RELAYS[@]}" 2>/dev/null | tail -1
echo "   ✅ kind:3 published (following ${#FOLLOWS[@]} accounts)"

# Brief pause for relay propagation
echo ""
echo "⏳ Waiting 10s for relay propagation..."
sleep 10

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2: Register with Brainstorm staging
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "🏗️  Step 2: Registering with Brainstorm staging..."

# Call /brainstormPubkey — creates observer + auto-triggers GrapeRank
OBSERVER_RESPONSE=$(curl -sf "$STAGING_API/brainstormPubkey/$HEX_PUBKEY" 2>/dev/null)
BRAINSTORM_PUBKEY=$(echo "$OBSERVER_RESPONSE" | jq -r '.data.brainstorm_pubkey // empty')

if [ -z "$BRAINSTORM_PUBKEY" ]; then
  echo "   ❌ Failed to create observer. Response:"
  echo "   $OBSERVER_RESPONSE"
  exit 1
fi

echo "   Observer (Brainstorm pubkey): $BRAINSTORM_PUBKEY"
echo "   ✅ Observer created, GrapeRank auto-triggered"

SIGNUP_TIME=$(date +%s)
SIGNUP_TIME_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3: Fetch NIP-85 setup data and publish kind 10040
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "📋 Step 3: Fetching NIP-85 setup data..."

SETUP_RESPONSE=$(curl -sf "$STAGING_API/setup/$HEX_PUBKEY" 2>/dev/null)

# Parse the setup tags
# Expected format: [["30382:rank", "<ta_pubkey>", "<relay>"], ["30382:followers", "<ta_pubkey>", "<relay>"]]
NUM_TAGS=$(echo "$SETUP_RESPONSE" | jq 'length')

if [ "$NUM_TAGS" -eq 0 ] || [ "$NUM_TAGS" = "null" ]; then
  echo "   ❌ No setup tags returned. Response:"
  echo "   $SETUP_RESPONSE"
  exit 1
fi

echo "   Received $NUM_TAGS setup tags:"

# Extract info from first tag (all should share the same TA pubkey and relay)
TA_PUBKEY=$(echo "$SETUP_RESPONSE" | jq -r '.[0][1]')
TA_RELAY=$(echo "$SETUP_RESPONSE" | jq -r '.[0][2]')

DESCRIPTORS=()
for i in $(seq 0 $((NUM_TAGS - 1))); do
  DESC=$(echo "$SETUP_RESPONSE" | jq -r ".[$i][0]")
  DESCRIPTORS+=("$DESC")
  echo "   - $DESC → $TA_PUBKEY @ $TA_RELAY"
done

echo ""
echo "   TA pubkey: $TA_PUBKEY"
echo "   TA relay:  $TA_RELAY"

# Verify TA pubkey matches the observer
if [ "$TA_PUBKEY" != "$BRAINSTORM_PUBKEY" ]; then
  echo "   ⚠️  Warning: TA pubkey ($TA_PUBKEY) != observer pubkey ($BRAINSTORM_PUBKEY)"
fi

# Build and publish kind 10040 event
# Tags: one "d" tag with the TA pubkey, plus each setup tag as-is
echo ""
echo "📝 Publishing kind 10040 event..."

# Build tag args for nak
TAG_ARGS=()
for i in $(seq 0 $((NUM_TAGS - 1))); do
  DESC=$(echo "$SETUP_RESPONSE" | jq -r ".[$i][0]")
  TPUB=$(echo "$SETUP_RESPONSE" | jq -r ".[$i][1]")
  TREL=$(echo "$SETUP_RESPONSE" | jq -r ".[$i][2]")
  TAG_ARGS+=("-t" "${DESC}=${TPUB}=${TREL}")
done

EVENT_10040=$(nak event --sec "$NSEC" -k 10040 -c "" "${TAG_ARGS[@]}" "${PUBLISH_RELAYS[@]}" 2>/dev/null | tail -1)
echo "   $EVENT_10040"
echo "   ✅ kind 10040 published"

EVENT_10040_TIME=$(date +%s)
EVENT_10040_TIME_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4: Monitor for Trusted Assertions
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "🔍 Step 4: Monitoring $TA_RELAY for kind 30382 events..."
echo "   Author (TA pubkey): $TA_PUBKEY"
echo "   Checking every ${MONITOR_INTERVAL}s, max ${MAX_ELAPSED}s"
echo ""

MONITOR_START=$(date +%s)
ROUND=0
PREV_COUNT=-1
STABLE_ROUNDS=0
ROUNDS_JSON="["

while true; do
  ELAPSED=$(($(date +%s) - MONITOR_START))

  if [ "$ELAPSED" -ge "$MAX_ELAPSED" ]; then
    echo "⏰ Maximum elapsed time (${MAX_ELAPSED}s) reached."
    break
  fi

  ROUND=$((ROUND + 1))

  # Count kind 30382 events from TA pubkey on the designated relay
  TA_COUNT=$(nak count --author "$TA_PUBKEY" --kind 30382 "$TA_RELAY" 2>/dev/null || echo "0")
  # Fallback: if nak count isn't supported, use req + jq
  if [ -z "$TA_COUNT" ] || [ "$TA_COUNT" = "null" ]; then
    TA_COUNT=$(nak req --author "$TA_PUBKEY" --kind 30382 "$TA_RELAY" 2>/dev/null | wc -l | tr -d ' ')
  fi

  ELAPSED=$(($(date +%s) - MONITOR_START))
  ROUND_TIME_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  echo "   Round $ROUND (T+${ELAPSED}s): $TA_COUNT TAs"

  # Build round JSON
  [ "$ROUND" -gt 1 ] && ROUNDS_JSON="$ROUNDS_JSON,"
  ROUNDS_JSON="$ROUNDS_JSON{\"round\":$ROUND,\"elapsed_seconds\":$ELAPSED,\"ta_count\":$TA_COUNT,\"time_utc\":\"$ROUND_TIME_UTC\"}"

  # Check stopping condition: count > 0 AND not increasing
  if [ "$TA_COUNT" -gt 0 ] && [ "$TA_COUNT" -eq "$PREV_COUNT" ]; then
    STABLE_ROUNDS=$((STABLE_ROUNDS + 1))
    echo "   📊 Count stable for $STABLE_ROUNDS consecutive round(s)"
    if [ "$STABLE_ROUNDS" -ge 1 ]; then
      echo ""
      echo "   ✅ TA count stabilized at $TA_COUNT"
      break
    fi
  else
    STABLE_ROUNDS=0
  fi

  PREV_COUNT=$TA_COUNT

  # Wait for next check
  REMAINING=$((MAX_ELAPSED - ELAPSED))
  WAIT=$((MONITOR_INTERVAL < REMAINING ? MONITOR_INTERVAL : REMAINING))
  if [ "$WAIT" -gt 0 ]; then
    sleep "$WAIT"
  fi
done

ROUNDS_JSON="$ROUNDS_JSON]"
TOTAL_ELAPSED=$(($(date +%s) - MONITOR_START))
FINAL_COUNT=$TA_COUNT

# Determine overall result
FIRST_TA_ROUND=""
FIRST_TA_ELAPSED=""
for i in $(seq 1 "$ROUND"); do
  IDX=$((i - 1))
  COUNT=$(echo "$ROUNDS_JSON" | jq ".[$IDX].ta_count")
  if [ "$COUNT" -gt 0 ] && [ -z "$FIRST_TA_ROUND" ]; then
    FIRST_TA_ROUND=$i
    FIRST_TA_ELAPSED=$(echo "$ROUNDS_JSON" | jq ".[$IDX].elapsed_seconds")
    break
  fi
done

# Verdicts
V_10040="PASS"  # If we got here, 10040 was published
V_TA_APPEARED="FAIL"
V_TA_STABILIZED="FAIL"

[ -n "$FIRST_TA_ROUND" ] && V_TA_APPEARED="PASS"
[ "$STABLE_ROUNDS" -ge 1 ] && [ "$FINAL_COUNT" -gt 0 ] && V_TA_STABILIZED="PASS"

# ═══════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════

cat > "$RESULT_FILE" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "timestamp_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "run_number": $RUN_NUMBER,
  "customer": {
    "hex_pubkey": "$HEX_PUBKEY",
    "npub": "$NPUB",
    "nsec_env_var": "$KEY_VAR",
    "follows": $(printf '%s\n' "${FOLLOWS[@]}" | jq -R . | jq -s .),
    "follow_count": ${#FOLLOWS[@]}
  },
  "brainstorm": {
    "api": "$STAGING_API",
    "observer_pubkey": "$BRAINSTORM_PUBKEY",
    "ta_pubkey": "$TA_PUBKEY",
    "ta_relay": "$TA_RELAY",
    "setup_tags": $(echo "$SETUP_RESPONSE" | jq .),
    "signup_time_utc": "$SIGNUP_TIME_UTC",
    "event_10040_time_utc": "$EVENT_10040_TIME_UTC"
  },
  "monitoring": {
    "monitor_interval_seconds": $MONITOR_INTERVAL,
    "max_elapsed_seconds": $MAX_ELAPSED,
    "total_elapsed_seconds": $TOTAL_ELAPSED,
    "total_rounds": $ROUND,
    "final_ta_count": $FINAL_COUNT,
    "first_ta_round": ${FIRST_TA_ROUND:-null},
    "first_ta_elapsed_seconds": ${FIRST_TA_ELAPSED:-null},
    "stable_rounds": $STABLE_ROUNDS
  },
  "verdicts": {
    "kind_10040_published": "$V_10040",
    "trusted_assertions_appeared": "$V_TA_APPEARED",
    "trusted_assertions_stabilized": "$V_TA_STABILIZED"
  },
  "rounds": $ROUNDS_JSON
}
EOF

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Results Summary"
echo "═══════════════════════════════════════════════════════════"
echo "  Customer: $NPUB"
echo "  Observer: $BRAINSTORM_PUBKEY"
echo "  TA relay: $TA_RELAY"
echo ""
echo "  Verdicts:"
echo "    Kind 10040 published:        $V_10040"
echo "    TAs appeared:                $V_TA_APPEARED"
if [ "$V_TA_APPEARED" = "PASS" ]; then
  echo "      First seen at round $FIRST_TA_ROUND (T+${FIRST_TA_ELAPSED}s)"
fi
echo "    TAs stabilized:              $V_TA_STABILIZED"
if [ "$V_TA_STABILIZED" = "PASS" ]; then
  echo "      Final count: $FINAL_COUNT"
fi
echo ""
echo "  Monitoring: $ROUND rounds over ${TOTAL_ELAPSED}s"
echo ""

if [ "$V_TA_APPEARED" = "PASS" ] && [ "$V_TA_STABILIZED" = "PASS" ]; then
  echo "  ✅ Test PASSED — Full onboarding pipeline working!"
elif [ "$V_TA_APPEARED" = "PASS" ]; then
  echo "  ⚠️  Test PARTIAL — TAs appeared but did not stabilize within ${MAX_ELAPSED}s"
else
  echo "  ❌ Test FAILED — No TAs appeared within ${MAX_ELAPSED}s"
fi

echo ""
echo "📁 Results saved to: $RESULT_FILE"

# Update state
echo "{\"run_number\": $RUN_NUMBER}" > "$STATE_FILE"
echo "🔢 Run number: $RUN_NUMBER"

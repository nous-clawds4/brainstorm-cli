#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Brainstorm NosFabrica Propagation Test
# ═══════════════════════════════════════════════════════════════════════════
#
# Tests whether a new nostr follow event propagates through the full
# NosFabrica Brainstorm pipeline:
#
#   publish (primal/damus)
#     └→ wot.grapevine.network          (gateway relay)
#          ├→ neofry.nosfabrica.com      (prod relay)
#          │    └→ brainstormserver.nosfabrica.com  (prod API / neo4j)
#          └→ neofry-staging.nosfabrica.com         (staging relay)
#               └→ brainstormserver-staging.nosfabrica.com  (staging API / neo4j)
#
# FLOW:
#   1. Query Nous's current follow count from 3 relays + 2 APIs (baseline)
#   2. Publish a new kind 3 event adding one random follow from Dave's list
#   3. Wait 20s, then re-query all 5 endpoints (initial check)
#   4. If any endpoint has NOT incremented:
#      - Re-query ALL 5 endpoints every 5 minutes
#      - Continue until all have incremented OR 1 hour has elapsed
#      - Each round re-queries everything (even previously-passed endpoints)
#        to document that no spurious changes occurred
#   5. Write structured JSON results to results/ directory
#
# PASS/FAIL/N/A LOGIC:
#   - Each stage depends on its upstream stage in the pipeline
#   - If upstream never passed → downstream is N/A (untestable)
#   - PASS = follow count incremented by exactly 1 vs baseline
#   - FAIL = did not increment within the 1-hour window
#
# PREREQUISITES:
#   - nak CLI (v0.18+)
#   - jq, curl
#   - Nous's nsec: set NOSTR_SECRET_KEY env var, or have 1Password desktop
#     app unlocked (script reads from op://Personal/Nous - Nostr Key/password)
#
# USAGE:
#   cd brainstorm-nosfabrica-tests
#   ./run-test.sh
#
# ═══════════════════════════════════════════════════════════════════════════

# ─── Configuration ──────────────────────────────────────────────────────────
NOUS_HEX="15f7dafc4624b1e6b00ab7f863de1a53b71967528070ec7d1837c7a40c1c7270"
DAVE_HEX="e5272de914bd301755c439b88e6959a43c9d2664831f093c51e9c799a16a102f"

GATEWAY_RELAY="wss://wot.grapevine.network"
PROD_RELAY="wss://neofry.nosfabrica.com"
STAGING_RELAY="wss://neofry-staging.nosfabrica.com"

PUBLISH_RELAYS=("wss://relay.primal.net" "wss://relay.damus.io" "wss://nos.lol" "wss://purplepag.es" "ws://localhost:7777")

PROD_API="https://brainstormserver.nosfabrica.com"
STAGING_API="https://brainstormserver-staging.nosfabrica.com"

INITIAL_WAIT=20          # seconds before first check after publish
RETRY_INTERVAL=300       # seconds between retry rounds (5 minutes)
MAX_ELAPSED=3600         # maximum seconds to keep retrying (1 hour)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"

TIMESTAMP=$(date -u +"%Y-%m-%d_%H-%M-%S")
RESULT_FILE="$RESULTS_DIR/${TIMESTAMP}.json"

# ─── Secret Key ─────────────────────────────────────────────────────────────
# Priority: NOSTR_SECRET_KEY env var > keys.env (NOUS_NSEC) > 1Password
# See: brainstorm-nosfabrica-tests/KEYS.md for key management docs
if [ -z "${NOSTR_SECRET_KEY:-}" ]; then
  KEYS_ENV="$HOME/.config/nosfabrica-tests/keys.env"
  if [ -f "$KEYS_ENV" ]; then
    # shellcheck disable=SC1090
    source "$KEYS_ENV"
    if [ -n "${NOUS_NSEC:-}" ]; then
      echo "🔑 Loaded Nous nsec from $KEYS_ENV"
      NOSTR_SECRET_KEY="$NOUS_NSEC"
    fi
  fi
fi
if [ -z "${NOSTR_SECRET_KEY:-}" ]; then
  echo "🔑 Fetching Nous nsec from 1Password..."
  NOSTR_SECRET_KEY=$(op read "op://Personal/Nous - Nostr Key/password" 2>/dev/null) || {
    echo "❌ Failed to retrieve nsec. No keys.env at ~/.config/nosfabrica-tests/keys.env"
    echo "   and 1Password unavailable. See KEYS.md for setup instructions."
    exit 1
  }
fi
export NOSTR_SECRET_KEY

# ─── Helper Functions ───────────────────────────────────────────────────────

# Count p-tags in a kind 3 event from a relay
count_follows_relay() {
  local relay="$1"
  local result
  result=$(nak req --author "$NOUS_HEX" --kind 3 "$relay" 2>/dev/null \
    | jq '[.tags[] | select(.[0]=="p")] | length' 2>/dev/null)
  echo "${result:-0}"
}

# Get follow count from Brainstorm API (requires auth token)
count_follows_api() {
  local api_base="$1"
  local token="$2"
  local result
  result=$(curl -sf -H "access_token: $token" \
    "$api_base/user/$NOUS_HEX" 2>/dev/null \
    | jq '.data.following | length' 2>/dev/null)
  echo "${result:-0}"
}

# Authenticate with Brainstorm API, return JWT token.
# Auth flow:
#   1. GET  /authChallenge/{pubkey}        → { data: { challenge: "..." } }
#   2. Sign a kind 22242 nostr event with tags:
#        ["t", "brainstorm_login"]
#        ["challenge", "<challenge_string>"]
#      Content is empty string. Sign with Nous's nsec via `nak event --sec`.
#   3. POST /authChallenge/{pubkey}/verify  → { data: { token: "..." } }
#      Body: { "signed_event": <full signed nostr event object> }
#   4. Use the returned JWT as: Header `access_token: <token>`
#      Token is valid for ~5 hours.
get_auth_token() {
  local api_base="$1"

  # Step 1: Get challenge
  local challenge
  challenge=$(curl -sf "$api_base/authChallenge/$NOUS_HEX" 2>/dev/null \
    | jq -r '.data.challenge') || { echo ""; return; }

  if [ -z "$challenge" ] || [ "$challenge" = "null" ]; then
    echo ""
    return
  fi

  # Step 2: Sign a kind 22242 auth event with brainstorm_login t-tag and challenge
  local signed_event
  signed_event=$(nak event --sec "$NOSTR_SECRET_KEY" \
    -k 22242 \
    -c "" \
    -t t=brainstorm_login \
    -t challenge="$challenge" 2>/dev/null) || { echo ""; return; }

  if [ -z "$signed_event" ]; then
    echo ""
    return
  fi

  # Step 3: Submit signed event to verify
  local token
  token=$(curl -sf -X POST \
    -H "Content-Type: application/json" \
    -d "{\"signed_event\": $signed_event}" \
    "$api_base/authChallenge/$NOUS_HEX/verify" 2>/dev/null \
    | jq -r '.data.token') || { echo ""; return; }

  echo "${token:-}"
}

# Get the latest kind 3 event for Nous across multiple relays.
# Fetches from all publish relays + gateway, picks the one with highest created_at.
# Outputs the full event JSON (one line).
get_latest_kind3() {
  local best_ts=0
  local best_event=""
  for relay in "${PUBLISH_RELAYS[@]}" "$GATEWAY_RELAY"; do
    local event
    event=$(nak req --author "$NOUS_HEX" --kind 3 "$relay" 2>/dev/null) || continue
    if [ -z "$event" ]; then continue; fi
    local ts
    ts=$(echo "$event" | jq -r '.created_at' 2>/dev/null) || continue
    if [ "$ts" -gt "$best_ts" ] 2>/dev/null; then
      best_ts="$ts"
      best_event="$event"
    fi
  done
  echo "$best_event"
}

# Get all p-tag pubkeys from the latest kind 3 event.
get_current_follows() {
  get_latest_kind3 | jq -r '[.tags[] | select(.[0]=="p") | .[1]] | .[]' 2>/dev/null
}

# Get all p-tag pubkeys from Dave's kind 3
get_dave_follows() {
  nak req --author "$DAVE_HEX" --kind 3 wss://relay.damus.io 2>/dev/null \
    | jq -r '[.tags[] | select(.[0]=="p") | .[1]] | .[]' 2>/dev/null
}

# Evaluate verdict for a single endpoint.
# Args: pre_count, post_count, upstream_verdict
# Prints: PASS, FAIL, or N/A
evaluate_verdict() {
  local pre="$1"
  local post="$2"
  local upstream="$3"  # empty string means no upstream dependency

  if [ -n "$upstream" ] && [ "$upstream" != "PASS" ]; then
    echo "N/A"
    return
  fi
  if [ "$post" != "null" ] && [ "$pre" != "null" ] && \
     [ "$post" -gt "$pre" ] 2>/dev/null; then
    echo "PASS"
  else
    echo "FAIL"
  fi
}

# Query all 5 endpoints and print results.
# Sets global variables: CUR_GATEWAY, CUR_PROD, CUR_STAGING, CUR_PROD_API, CUR_STAGING_API
# and: V_GATEWAY, V_PROD, V_STAGING, V_PROD_API, V_STAGING_API
query_all_and_evaluate() {
  local round_label="$1"

  echo "📊 $round_label — Querying all endpoints..."

  CUR_GATEWAY=$(count_follows_relay "$GATEWAY_RELAY")
  CUR_PROD=$(count_follows_relay "$PROD_RELAY")
  CUR_STAGING=$(count_follows_relay "$STAGING_RELAY")

  CUR_PROD_API="null"
  CUR_STAGING_API="null"
  if [ "$PROD_AUTH_OK" = "true" ]; then
    CUR_PROD_API=$(count_follows_api "$PROD_API" "$PROD_TOKEN")
  fi
  if [ "$STAGING_AUTH_OK" = "true" ]; then
    CUR_STAGING_API=$(count_follows_api "$STAGING_API" "$STAGING_TOKEN")
  fi

  # Evaluate verdicts
  V_GATEWAY=$(evaluate_verdict "$PRE_GATEWAY" "$CUR_GATEWAY" "")
  V_PROD=$(evaluate_verdict "$PRE_PROD" "$CUR_PROD" "$V_GATEWAY")
  V_STAGING=$(evaluate_verdict "$PRE_STAGING" "$CUR_STAGING" "$V_GATEWAY")

  if [ "$PROD_AUTH_OK" != "true" ]; then
    V_PROD_API="N/A (auth failed)"
  else
    V_PROD_API=$(evaluate_verdict "$PRE_PROD_API" "$CUR_PROD_API" "$V_PROD")
  fi

  if [ "$STAGING_AUTH_OK" != "true" ]; then
    V_STAGING_API="N/A (auth failed)"
  else
    V_STAGING_API=$(evaluate_verdict "$PRE_STAGING_API" "$CUR_STAGING_API" "$V_STAGING")
  fi

  echo "   Gateway:     $V_GATEWAY  ($PRE_GATEWAY → $CUR_GATEWAY)"
  echo "   Prod relay:  $V_PROD  ($PRE_PROD → $CUR_PROD)"
  echo "   Staging relay: $V_STAGING  ($PRE_STAGING → $CUR_STAGING)"
  echo "   Prod API:    $V_PROD_API  ($PRE_PROD_API → $CUR_PROD_API)"
  echo "   Staging API: $V_STAGING_API  ($PRE_STAGING_API → $CUR_STAGING_API)"
  echo ""
}

# Check if all testable verdicts have passed (no FAILs remaining)
all_passed() {
  for v in "$V_GATEWAY" "$V_PROD" "$V_STAGING" "$V_PROD_API" "$V_STAGING_API"; do
    case "$v" in
      FAIL) return 1 ;;
    esac
  done
  return 0
}

# ─── Main Test Flow ─────────────────────────────────────────────────────────

echo "═══════════════════════════════════════════════════════════"
echo "  Brainstorm Propagation Test — $TIMESTAMP"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Step 1: Pre-counts (baseline)
echo "📊 Step 1: Querying baseline follow counts..."
PRE_GATEWAY=$(count_follows_relay "$GATEWAY_RELAY")
PRE_PROD=$(count_follows_relay "$PROD_RELAY")
PRE_STAGING=$(count_follows_relay "$STAGING_RELAY")
echo "   Gateway  (wot.grapevine.network):        $PRE_GATEWAY"
echo "   Prod     (neofry.nosfabrica.com):         $PRE_PROD"
echo "   Staging  (neofry-staging.nosfabrica.com): $PRE_STAGING"
echo ""

# Auth with APIs
echo "🔐 Authenticating with Brainstorm APIs..."
PROD_TOKEN=$(get_auth_token "$PROD_API")
STAGING_TOKEN=$(get_auth_token "$STAGING_API")
PROD_AUTH_OK="false"
STAGING_AUTH_OK="false"
if [ -n "$PROD_TOKEN" ] && [ "$PROD_TOKEN" != "null" ]; then
  PROD_AUTH_OK="true"
  echo "   Prod API:    ✅ authenticated"
else
  echo "   Prod API:    ❌ auth failed"
fi
if [ -n "$STAGING_TOKEN" ] && [ "$STAGING_TOKEN" != "null" ]; then
  STAGING_AUTH_OK="true"
  echo "   Staging API: ✅ authenticated"
else
  echo "   Staging API: ❌ auth failed"
fi
echo ""

# Baseline API counts
PRE_PROD_API="null"
PRE_STAGING_API="null"
if [ "$PROD_AUTH_OK" = "true" ]; then
  PRE_PROD_API=$(count_follows_api "$PROD_API" "$PROD_TOKEN")
  echo "   Prod API follow count:    $PRE_PROD_API"
fi
if [ "$STAGING_AUTH_OK" = "true" ]; then
  PRE_STAGING_API=$(count_follows_api "$STAGING_API" "$STAGING_TOKEN")
  echo "   Staging API follow count: $PRE_STAGING_API"
fi
echo ""

# Step 2: Pick a random new follow and publish
echo "🎲 Step 2: Selecting a random new follow from Dave's list..."
NOUS_FOLLOWS=$(get_current_follows)
DAVE_FOLLOWS=$(get_dave_follows)

DAVE_FOLLOWS_ARRAY=()
while IFS= read -r pk; do
  [ -n "$pk" ] && DAVE_FOLLOWS_ARRAY+=("$pk")
done <<< "$DAVE_FOLLOWS"

NOUS_FOLLOWS_SET=$(echo "$NOUS_FOLLOWS" | sort)

CANDIDATES=()
for pk in "${DAVE_FOLLOWS_ARRAY[@]}"; do
  if ! echo "$NOUS_FOLLOWS_SET" | grep -qF "$pk"; then
    CANDIDATES+=("$pk")
  fi
done

if [ ${#CANDIDATES[@]} -eq 0 ]; then
  echo "❌ No new candidates found (Nous already follows everyone Dave follows?!)"
  exit 1
fi

RANDOM_INDEX=$((RANDOM % ${#CANDIDATES[@]}))
NEW_FOLLOW="${CANDIDATES[$RANDOM_INDEX]}"
echo "   Selected: $NEW_FOLLOW"
echo ""

# Build and publish the new kind 3 event
echo "📤 Publishing new kind 3 event..."
P_TAG_ARGS=()
while IFS= read -r pk; do
  [ -n "$pk" ] && P_TAG_ARGS+=("-p" "$pk")
done <<< "$NOUS_FOLLOWS"
P_TAG_ARGS+=("-p" "$NEW_FOLLOW")

TOTAL_FOLLOWS=$((${#P_TAG_ARGS[@]} / 2))
echo "   New kind 3 will contain $TOTAL_FOLLOWS follows"

PUBLISH_START=$(date +%s)

nak event --sec "$NOSTR_SECRET_KEY" -k 3 -c "" "${P_TAG_ARGS[@]}" "${PUBLISH_RELAYS[@]}" 2>&1 | while read -r line; do
  echo "   $line"
done
echo ""

# ─── Step 3: Initial check after INITIAL_WAIT ──────────────────────────────

echo "⏳ Waiting ${INITIAL_WAIT}s for initial propagation..."
sleep "$INITIAL_WAIT"

ROUND=1
query_all_and_evaluate "Round $ROUND (T+${INITIAL_WAIT}s)"

# Collect rounds for JSON output
# Each round: { round, elapsed_seconds, counts: {gw, prod, staging, prod_api, staging_api}, verdicts: {...} }
ROUNDS_JSON="[{\"round\":$ROUND,\"elapsed_seconds\":$INITIAL_WAIT,\"counts\":{\"gateway_relay\":$CUR_GATEWAY,\"prod_relay\":$CUR_PROD,\"staging_relay\":$CUR_STAGING,\"prod_api\":${CUR_PROD_API:-null},\"staging_api\":${CUR_STAGING_API:-null}},\"verdicts\":{\"gateway_relay\":\"$V_GATEWAY\",\"prod_relay\":\"$V_PROD\",\"staging_relay\":\"$V_STAGING\",\"prod_api\":\"$V_PROD_API\",\"staging_api\":\"$V_STAGING_API\"}}"

# ─── Step 4: Retry loop if anything failed ──────────────────────────────────

if ! all_passed; then
  echo "═══════════════════════════════════════════════════════════"
  echo "  Not all stages passed — entering retry loop"
  echo "  Interval: ${RETRY_INTERVAL}s (5 min)  |  Max: ${MAX_ELAPSED}s (1 hour)"
  echo "═══════════════════════════════════════════════════════════"
  echo ""
fi

while ! all_passed; do
  ELAPSED=$(( $(date +%s) - PUBLISH_START ))

  if [ "$ELAPSED" -ge "$MAX_ELAPSED" ]; then
    echo "⏰ Maximum elapsed time (${MAX_ELAPSED}s / 1 hour) reached. Stopping retries."
    echo ""
    break
  fi

  REMAINING=$(( MAX_ELAPSED - ELAPSED ))
  WAIT=$(( RETRY_INTERVAL < REMAINING ? RETRY_INTERVAL : REMAINING ))

  echo "⏳ Waiting ${WAIT}s until next check (elapsed: ${ELAPSED}s)..."
  sleep "$WAIT"

  ROUND=$((ROUND + 1))
  ELAPSED=$(( $(date +%s) - PUBLISH_START ))
  query_all_and_evaluate "Round $ROUND (T+${ELAPSED}s)"

  ROUNDS_JSON="$ROUNDS_JSON,{\"round\":$ROUND,\"elapsed_seconds\":$ELAPSED,\"counts\":{\"gateway_relay\":$CUR_GATEWAY,\"prod_relay\":$CUR_PROD,\"staging_relay\":$CUR_STAGING,\"prod_api\":${CUR_PROD_API:-null},\"staging_api\":${CUR_STAGING_API:-null}},\"verdicts\":{\"gateway_relay\":\"$V_GATEWAY\",\"prod_relay\":\"$V_PROD\",\"staging_relay\":\"$V_STAGING\",\"prod_api\":\"$V_PROD_API\",\"staging_api\":\"$V_STAGING_API\"}}"
done

ROUNDS_JSON="$ROUNDS_JSON]"
TOTAL_ELAPSED=$(( $(date +%s) - PUBLISH_START ))

# ─── Final Results ──────────────────────────────────────────────────────────

echo "═══════════════════════════════════════════════════════════"
echo "  Final Results  (${ROUND} round(s), ${TOTAL_ELAPSED}s elapsed)"
echo "═══════════════════════════════════════════════════════════"
echo "   Gateway relay:  $V_GATEWAY  ($PRE_GATEWAY → $CUR_GATEWAY)"
echo "   Prod relay:     $V_PROD  ($PRE_PROD → $CUR_PROD)"
echo "   Staging relay:  $V_STAGING  ($PRE_STAGING → $CUR_STAGING)"
echo "   Prod API:       $V_PROD_API  ($PRE_PROD_API → $CUR_PROD_API)"
echo "   Staging API:    $V_STAGING_API  ($PRE_STAGING_API → $CUR_STAGING_API)"
echo ""

# ─── Save Results ───────────────────────────────────────────────────────────

cat > "$RESULT_FILE" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "timestamp_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "nous_pubkey": "$NOUS_HEX",
  "new_follow_pubkey": "$NEW_FOLLOW",
  "total_follows_after_publish": $TOTAL_FOLLOWS,
  "initial_wait_seconds": $INITIAL_WAIT,
  "retry_interval_seconds": $RETRY_INTERVAL,
  "max_elapsed_seconds": $MAX_ELAPSED,
  "total_elapsed_seconds": $TOTAL_ELAPSED,
  "total_rounds": $ROUND,
  "baseline": {
    "gateway_relay": $PRE_GATEWAY,
    "prod_relay": $PRE_PROD,
    "staging_relay": $PRE_STAGING,
    "prod_api": ${PRE_PROD_API:-null},
    "staging_api": ${PRE_STAGING_API:-null}
  },
  "auth": {
    "prod_api": $PROD_AUTH_OK,
    "staging_api": $STAGING_AUTH_OK
  },
  "rounds": $ROUNDS_JSON,
  "final_verdicts": {
    "gateway_relay": "$V_GATEWAY",
    "prod_relay": "$V_PROD",
    "staging_relay": "$V_STAGING",
    "prod_api": "$V_PROD_API",
    "staging_api": "$V_STAGING_API"
  }
}
EOF

echo "📁 Results saved to: $RESULT_FILE"
echo ""

# Summary
ALL_PASS="true"
for v in "$V_GATEWAY" "$V_PROD" "$V_STAGING" "$V_PROD_API" "$V_STAGING_API"; do
  case "$v" in
    FAIL*) ALL_PASS="false" ;;
  esac
done

if [ "$ALL_PASS" = "true" ]; then
  echo "✅ All tested stages passed!"
else
  echo "⚠️  One or more stages failed after ${TOTAL_ELAPSED}s (${ROUND} rounds) — see details above."
fi

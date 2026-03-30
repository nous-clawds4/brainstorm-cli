#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Stress Test 1 — Setup
# ═══════════════════════════════════════════════════════════════════════════
#
# Creates 100 test accounts + 1 coordinator account, publishes profiles,
# has the coordinator follow all 100, and verifies Brainstorm registration.
#
# Idempotent: re-running skips accounts that already exist in keys.env.
#
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_ENV="$HOME/.config/nosfabrica-tests/keys.env"
ACCOUNTS_FILE="$SCRIPT_DIR/accounts.json"
COORDINATOR_FILE="$SCRIPT_DIR/coordinator.json"

NUM_ACCOUNTS=100

PUBLISH_RELAYS=("wss://relay.primal.net" "wss://relay.damus.io" "wss://nos.lol" "wss://purplepag.es")
GATEWAY_RELAY="wss://wot.grapevine.network"
PROD_RELAY="wss://neofry.nosfabrica.com"
STAGING_RELAY="wss://neofry-staging.nosfabrica.com"
PROD_API="https://brainstormserver.nosfabrica.com"
STAGING_API="https://brainstormserver-staging.nosfabrica.com"

# Ensure keys.env exists
mkdir -p "$(dirname "$KEYS_ENV")"
touch "$KEYS_ENV"
chmod 600 "$KEYS_ENV"

# ─── Helper: Add key to keys.env if not present ────────────────────────────
add_key_if_missing() {
  local var_name="$1"
  local nsec="$2"
  if ! grep -q "^export ${var_name}=" "$KEYS_ENV" 2>/dev/null; then
    echo "export ${var_name}=\"${nsec}\"" >> "$KEYS_ENV"
  fi
}

# ─── Helper: Get key from keys.env ─────────────────────────────────────────
get_key() {
  local var_name="$1"
  local line
  line=$(grep "^export ${var_name}=" "$KEYS_ENV" 2>/dev/null || true)
  if [ -n "$line" ]; then
    echo "$line" | sed 's/^export [^=]*="\(.*\)"/\1/'
  fi
}

# ─── Helper: nsec → hex pubkey ─────────────────────────────────────────────
nsec_to_hex_pubkey() {
  local nsec="$1"
  nak key public "$nsec" 2>/dev/null
}

# ─── Helper: hex pubkey → npub ─────────────────────────────────────────────
hex_to_npub() {
  local hex="$1"
  nak encode npub "$hex" 2>/dev/null
}

# ─── Helper: Authenticate with Brainstorm API ─────────────────────────────
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

# ─── Helper: Count follows for a pubkey on a relay ─────────────────────────
count_follows_relay() {
  local relay="$1"
  local hex="$2"
  local result
  result=$(nak req --author "$hex" --kind 3 "$relay" 2>/dev/null \
    | jq '[.tags[] | select(.[0]=="p")] | length' 2>/dev/null)
  echo "${result:-0}"
}

# ─── Helper: Count follows from Brainstorm API ────────────────────────────
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
echo "  Stress Test 1 — Setup"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ─── Step 1: Generate keypairs ──────────────────────────────────────────────
echo "🔑 Step 1: Generating keypairs..."

# Coordinator
COORD_NSEC=$(get_key "STRESS_COORDINATOR_NSEC")
if [ -z "$COORD_NSEC" ]; then
  COORD_HEX_SECRET=$(nak key generate)
  COORD_NSEC=$(nak encode nsec "$COORD_HEX_SECRET")
  add_key_if_missing "STRESS_COORDINATOR_NSEC" "$COORD_NSEC"
  echo "   ✅ Created coordinator keypair"
else
  echo "   ♻️  Coordinator keypair already exists"
fi
COORD_HEX=$(nsec_to_hex_pubkey "$COORD_NSEC")
COORD_NPUB=$(hex_to_npub "$COORD_HEX")

# Save coordinator metadata
cat > "$COORDINATOR_FILE" <<EOF
{
  "env_var": "STRESS_COORDINATOR_NSEC",
  "hex_pubkey": "$COORD_HEX",
  "npub": "$COORD_NPUB",
  "name": "Brainstorm Stress Test Coordinator"
}
EOF

# Test accounts
ACCOUNTS_JSON="["
CREATED=0
REUSED=0
for i in $(seq 1 $NUM_ACCOUNTS); do
  PADDED=$(printf "%03d" "$i")
  VAR_NAME="STRESS_ACCOUNT_${PADDED}_NSEC"
  
  NSEC=$(get_key "$VAR_NAME")
  if [ -z "$NSEC" ]; then
    HEX_SECRET=$(nak key generate)
    NSEC=$(nak encode nsec "$HEX_SECRET")
    add_key_if_missing "$VAR_NAME" "$NSEC"
    CREATED=$((CREATED + 1))
  else
    REUSED=$((REUSED + 1))
  fi

  HEX=$(nsec_to_hex_pubkey "$NSEC")
  NPUB=$(hex_to_npub "$HEX")

  [ "$i" -gt 1 ] && ACCOUNTS_JSON="$ACCOUNTS_JSON,"
  ACCOUNTS_JSON="$ACCOUNTS_JSON
  {
    \"index\": $i,
    \"env_var\": \"$VAR_NAME\",
    \"hex_pubkey\": \"$HEX\",
    \"npub\": \"$NPUB\",
    \"name\": \"Brainstorm Stress Test Account #$i\"
  }"

  # Progress every 10
  if [ $((i % 10)) -eq 0 ]; then
    echo "   ... $i / $NUM_ACCOUNTS"
  fi
done
ACCOUNTS_JSON="$ACCOUNTS_JSON
]"

echo "$ACCOUNTS_JSON" | jq '.' > "$ACCOUNTS_FILE"
echo "   ✅ $CREATED new + $REUSED reused = $NUM_ACCOUNTS accounts"
echo ""

# ─── Step 2: Publish kind:0 profiles ───────────────────────────────────────
echo "📝 Step 2: Publishing kind:0 profiles to public relays..."
echo "   (This may take a few minutes — 101 events)"
echo ""

# Coordinator profile
echo "   Publishing coordinator profile..."
COORD_PROFILE="{\"name\":\"Brainstorm Stress Test Coordinator\",\"about\":\"Automated test coordinator for NosFabrica Brainstorm pipeline stress testing.\",\"display_name\":\"Stress Test Coordinator\"}"
nak event --sec "$COORD_NSEC" -k 0 -c "$COORD_PROFILE" "${PUBLISH_RELAYS[@]}" 2>&1 | while read -r line; do
  echo "     $line"
done
echo ""

# Test account profiles
for i in $(seq 1 $NUM_ACCOUNTS); do
  PADDED=$(printf "%03d" "$i")
  VAR_NAME="STRESS_ACCOUNT_${PADDED}_NSEC"
  NSEC=$(get_key "$VAR_NAME")

  PROFILE="{\"name\":\"Brainstorm Stress Test Account #$i\",\"about\":\"Automated test account #$i for NosFabrica Brainstorm pipeline stress testing.\",\"display_name\":\"Stress Test #$i\"}"
  
  nak event --sec "$NSEC" -k 0 -c "$PROFILE" "${PUBLISH_RELAYS[@]}" 2>/dev/null | tail -1
  
  if [ $((i % 10)) -eq 0 ]; then
    echo "   ... $i / $NUM_ACCOUNTS profiles published"
  fi

  # Small delay to avoid overwhelming relays
  sleep 0.5
done
echo "   ✅ All profiles published"
echo ""

# ─── Step 3: Coordinator follows all 100 accounts ──────────────────────────
echo "🤝 Step 3: Coordinator following all $NUM_ACCOUNTS test accounts..."

P_TAG_ARGS=()
for i in $(seq 1 $NUM_ACCOUNTS); do
  HEX=$(jq -r ".[$((i-1))].hex_pubkey" "$ACCOUNTS_FILE")
  P_TAG_ARGS+=("-p" "$HEX")
done

nak event --sec "$COORD_NSEC" -k 3 -c "" "${P_TAG_ARGS[@]}" "${PUBLISH_RELAYS[@]}" "ws://localhost:7777" 2>&1 | while read -r line; do
  echo "   $line"
done
echo "   ✅ Published kind:3 with $NUM_ACCOUNTS follows"
echo ""

# ─── Step 4: Verify propagation ────────────────────────────────────────────
echo "⏳ Step 4: Verifying coordinator follows propagated..."
echo "   Waiting 30s for initial propagation..."
sleep 30

# Check relays
GW_COUNT=$(count_follows_relay "$GATEWAY_RELAY" "$COORD_HEX")
PROD_COUNT=$(count_follows_relay "$PROD_RELAY" "$COORD_HEX")
STAGING_COUNT=$(count_follows_relay "$STAGING_RELAY" "$COORD_HEX")

echo "   Gateway relay:  $GW_COUNT / $NUM_ACCOUNTS"
echo "   Prod relay:     $PROD_COUNT / $NUM_ACCOUNTS"
echo "   Staging relay:  $STAGING_COUNT / $NUM_ACCOUNTS"

# Check APIs
PROD_TOKEN=$(get_auth_token "$PROD_API" "$COORD_HEX" "$COORD_NSEC")
STAGING_TOKEN=$(get_auth_token "$STAGING_API" "$COORD_HEX" "$COORD_NSEC")

if [ -n "$PROD_TOKEN" ] && [ "$PROD_TOKEN" != "null" ]; then
  PROD_API_COUNT=$(count_follows_api "$PROD_API" "$PROD_TOKEN" "$COORD_HEX")
  echo "   Prod API:       $PROD_API_COUNT / $NUM_ACCOUNTS"
else
  echo "   Prod API:       ❌ auth failed"
fi

if [ -n "$STAGING_TOKEN" ] && [ "$STAGING_TOKEN" != "null" ]; then
  STAGING_API_COUNT=$(count_follows_api "$STAGING_API" "$STAGING_TOKEN" "$COORD_HEX")
  echo "   Staging API:    $STAGING_API_COUNT / $NUM_ACCOUNTS"
else
  echo "   Staging API:    ❌ auth failed"
fi

echo ""

# Retry check if needed (up to 5 minutes)
ELAPSED=30
MAX_SETUP_WAIT=300
SETUP_RETRY=30
while [ "$ELAPSED" -lt "$MAX_SETUP_WAIT" ]; do
  ALL_OK=true
  [ "$GW_COUNT" -lt "$NUM_ACCOUNTS" ] && ALL_OK=false
  [ "$PROD_COUNT" -lt "$NUM_ACCOUNTS" ] && ALL_OK=false
  [ "$STAGING_COUNT" -lt "$NUM_ACCOUNTS" ] && ALL_OK=false

  if $ALL_OK; then
    break
  fi

  echo "   ⏳ Not all endpoints have full count yet. Retrying in ${SETUP_RETRY}s..."
  sleep "$SETUP_RETRY"
  ELAPSED=$((ELAPSED + SETUP_RETRY))

  GW_COUNT=$(count_follows_relay "$GATEWAY_RELAY" "$COORD_HEX")
  PROD_COUNT=$(count_follows_relay "$PROD_RELAY" "$COORD_HEX")
  STAGING_COUNT=$(count_follows_relay "$STAGING_RELAY" "$COORD_HEX")
  echo "   Gateway: $GW_COUNT  |  Prod: $PROD_COUNT  |  Staging: $STAGING_COUNT"
done

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Setup Complete"
echo "═══════════════════════════════════════════════════════════"
echo "  Coordinator: $COORD_NPUB"
echo "  Accounts:    $NUM_ACCOUNTS (saved to accounts.json)"
echo "  Keys:        $KEYS_ENV"
echo ""
echo "  Next: run ./run-test.sh to execute the stress test"
echo "═══════════════════════════════════════════════════════════"

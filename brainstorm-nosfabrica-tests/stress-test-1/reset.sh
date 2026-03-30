#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Stress Test 1 — Reset
# ═══════════════════════════════════════════════════════════════════════════
#
# Clears follow lists for sender accounts by publishing empty kind:3 events,
# and resets the nonce counter in state.json back to 0.
#
# With the nonce rotation system, you should rarely need this — only when
# all nonce combinations are exhausted (thousands of runs) or for manual
# cleanup.
#
# Usage:
#   ./reset.sh                    # resets accounts 1-10 (default senders)
#   ./reset.sh --senders 1-20    # reset a custom range
#   ./reset.sh --all             # reset ALL 100 accounts
#
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_ENV="$HOME/.config/nosfabrica-tests/keys.env"
ACCOUNTS_FILE="$SCRIPT_DIR/accounts.json"
STATE_FILE="$SCRIPT_DIR/state.json"

PUBLISH_RELAYS=("wss://relay.primal.net" "wss://relay.damus.io" "wss://nos.lol" "wss://purplepag.es" "ws://localhost:7777")

SENDER_START=1
SENDER_END=10
RESET_ALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --senders)
      SENDER_START="${2%%-*}"
      SENDER_END="${2##*-}"
      shift 2
      ;;
    --all)
      TOTAL_ACCOUNTS=$(jq length "$ACCOUNTS_FILE")
      SENDER_START=1
      SENDER_END="$TOTAL_ACCOUNTS"
      RESET_ALL=true
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--senders START-END] [--all]"
      exit 1
      ;;
  esac
done

if [ ! -f "$ACCOUNTS_FILE" ]; then
  echo "❌ accounts.json not found. Run ./setup.sh first."
  exit 1
fi

# shellcheck disable=SC1090
source "$KEYS_ENV"

get_account_nsec() {
  local idx="$1"
  local padded
  padded=$(printf "%03d" "$idx")
  local var_name="STRESS_ACCOUNT_${padded}_NSEC"
  echo "${!var_name:-}"
}

echo "═══════════════════════════════════════════════════════════"
echo "  Stress Test 1 — Reset"
if $RESET_ALL; then
  echo "  Clearing follow lists for ALL accounts ($SENDER_START–$SENDER_END)"
else
  echo "  Clearing follow lists for accounts $SENDER_START–$SENDER_END"
fi
echo "═══════════════════════════════════════════════════════════"
echo ""

for i in $(seq "$SENDER_START" "$SENDER_END"); do
  NSEC=$(get_account_nsec "$i")
  if [ -z "$NSEC" ]; then
    echo "   ❌ Account #$i: no nsec found, skipping"
    continue
  fi

  echo -n "   Account #$i: publishing empty kind:3 ... "
  nak event --sec "$NSEC" -k 3 -c "" "${PUBLISH_RELAYS[@]}" 2>/dev/null | tail -1
  echo "done"

  sleep 0.5
done

# Reset nonce
echo '{"nonce": 0}' > "$STATE_FILE"

echo ""
echo "✅ Reset complete."
echo "   Follow lists cleared for accounts $SENDER_START–$SENDER_END."
echo "   Nonce reset to 0."
echo "   Wait ~30s for propagation before re-running the test."

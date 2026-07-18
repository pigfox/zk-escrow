#!/usr/bin/env bash
#
# ACT II — the AI dispute path.
#
# Delivery is contested. There is no proof to settle it, so the escrow goes to
# an arbiter — and the arbiter is a Go agent that reads both parties' evidence,
# asks Claude for a ruling, and executes it on chain.
#
#   create -> fund -> dispute (buyer) -> evidence (seller) -> [agent rules]
#
# This script sets the stage and stops. The agent is started separately so you
# can watch it poll, reason and rule.
#
# Usage: ./scripts/demo-dispute.sh [escrowAddress]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENV_FILE="../.env"
BASE_SEPOLIA_CHAIN_ID=84532
DEFAULT_RPC_URL="https://sepolia.base.org"

AMOUNT_WEI="${AMOUNT_WEI:-1000000000000000}" # 0.001 ETH

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
step() { printf '\n\033[1;36m--- %s ---\033[0m\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

REDACTED='***REDACTED***'

# Echo a command, then run it, with any signing key replaced in the echoed
# form. `cast` takes keys as arguments, so the printed and executed forms are
# built separately and the real key only ever reaches argv.
run() {
    local shown=() arg
    for arg in "$@"; do
        if { [ -n "${PRIVATE_KEY:-}" ] && [ "$arg" = "$PRIVATE_KEY" ]; } \
            || { [ -n "${SELLER_KEY:-}" ] && [ "$arg" = "$SELLER_KEY" ]; }; then
            shown+=("$REDACTED")
        else
            shown+=("$arg")
        fi
    done
    printf '\033[0;90m$ %s\033[0m\n' "${shown[*]}"
    "$@"
}

[ -f "$ENV_FILE" ] || die "no $ENV_FILE. Copy .env.example to ../.env and populate it."
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

[ -n "${ADDRESS:-}" ] || die "ADDRESS is empty in $ENV_FILE"
[ -n "${PRIVATE_KEY:-}" ] || die "PRIVATE_KEY is empty in $ENV_FILE"

ESCROW="${1:-${ESCROW_ADDRESS:-}}"
[ -n "$ESCROW" ] || die "no escrow address. Pass one, or set ESCROW_ADDRESS in $ENV_FILE. Deploy with ./scripts/deploy.sh"

RPC_URL="${RPC_URL:-$DEFAULT_RPC_URL}"

ACTUAL_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
[ "$ACTUAL_CHAIN_ID" = "$BASE_SEPOLIA_CHAIN_ID" ] \
    || die "refusing to run: chain $ACTUAL_CHAIN_ID is not Base Sepolia ($BASE_SEPOLIA_CHAIN_ID)"

# The buyer is you. The seller is a throwaway key so it can post its own
# evidence. The arbiter is ALSO you — the agent signs with the same key from
# ../.env, which is what lets it execute the ruling.
SELLER_KEY="${SELLER_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
SELLER_ADDR="$(cast wallet address --private-key "$SELLER_KEY")"
ARBITER_ADDR="$ADDRESS"

[ "$SELLER_ADDR" != "$ADDRESS" ] || die "seller and buyer must differ"

cat <<BANNER

  zk-escrow — ACT II: the AI dispute path
  ---------------------------------------
  escrow contract : $ESCROW
  buyer           : $ADDRESS
  seller          : $SELLER_ADDR
  arbiter         : $ARBITER_ADDR   (the agent signs as this)
  amount          : $AMOUNT_WEI wei

BANNER

# The contract requires buyer, seller and arbiter to be three distinct
# addresses, and here the buyer and the arbiter are the same key. So the BUYER
# role is played by the throwaway address and the SELLER by another, leaving
# your key free to act purely as the arbiter.
BUYER_KEY="$SELLER_KEY"
BUYER_ADDR="$SELLER_ADDR"
SELLER2_KEY="${SELLER2_KEY:-0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba}"
SELLER2_ADDR="$(cast wallet address --private-key "$SELLER2_KEY")"

log "Funding the throwaway buyer with gas + escrow value"
run cast send "$BUYER_ADDR" --value "$((AMOUNT_WEI * 3))" \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$PRIVATE_KEY"

log "Funding the throwaway seller with gas dust so it can post evidence"
run cast send "$SELLER2_ADDR" --value 200000000000000 \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$PRIVATE_KEY"

# ----------------------------------------------------------------------------
step "1. Buyer creates an escrow naming YOU as arbiter"
# ----------------------------------------------------------------------------
NEXT_ID="$(cast call "$ESCROW" "nextEscrowId()(uint256)" --rpc-url "$RPC_URL")"
NEXT_ID="${NEXT_ID%% *}"

# The commitment is irrelevant in this act — nobody will ever prove delivery.
COMMITMENT="$(cast keccak "undeliverable-$NEXT_ID")"

run cast send "$ESCROW" \
    "createEscrow(address,address,uint256,uint256)" \
    "$SELLER2_ADDR" "$ARBITER_ADDR" "$AMOUNT_WEI" "$COMMITMENT" \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$BUYER_KEY"

ESCROW_ID="$NEXT_ID"
log "Created escrow #$ESCROW_ID"

# ----------------------------------------------------------------------------
step "2. Buyer funds it"
# ----------------------------------------------------------------------------
run cast send "$ESCROW" "fund(uint256)" "$ESCROW_ID" \
    --value "$AMOUNT_WEI" \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$BUYER_KEY"

# ----------------------------------------------------------------------------
step "3. Buyer raises a dispute with evidence"
# ----------------------------------------------------------------------------
BUYER_EVIDENCE="${BUYER_EVIDENCE:-I paid on the 3rd for a next-day delivery of one hardware wallet. Nothing arrived. The tracking number the seller gave me (1Z999AA10123456784) is not recognised on the carrier website. I have asked twice for a replacement number and received no reply.}"

run cast send "$ESCROW" "raiseDispute(uint256,string)" \
    "$ESCROW_ID" "$BUYER_EVIDENCE" \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$BUYER_KEY"

log "Disputed (state: Disputed)"

# ----------------------------------------------------------------------------
step "4. Seller answers with its own evidence"
# ----------------------------------------------------------------------------
# Both sides get to speak. The agent reads every DisputeRaised event for the
# escrow, not just the first.
SELLER_EVIDENCE="${SELLER_EVIDENCE:-The item shipped on the 3rd. I accept the tracking number I sent was mistyped; the correct one is 1Z999AA10123456785. The carrier shows it as delivered and signed for on the 5th. I have the signed proof-of-delivery scan and can forward it. I am not able to refund an item that was delivered.}"

run cast send "$ESCROW" "submitEvidence(uint256,string)" \
    "$ESCROW_ID" "$SELLER_EVIDENCE" \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$SELLER2_KEY"

log "Both sides have spoken. Current state:"
run cast call "$ESCROW" "getState(uint256)(uint8)" "$ESCROW_ID" --rpc-url "$RPC_URL"
echo "(5 = Disputed)"

# ----------------------------------------------------------------------------
cat <<DONE

  The stage is set. Escrow #$ESCROW_ID is Disputed, with evidence from both sides.
  ---------------------------------------------------------------------------

  Now start the arbiter and watch it work:

      export ESCROW_ADDRESS=$ESCROW
      cd agent && go run .

  It will:
    1. poll Base Sepolia for DisputeRaised events via eth_getLogs
    2. group both submissions for escrow #$ESCROW_ID
    3. ask Claude for a ruling as strict JSON {ruling, rationale}
    4. print the exact 'cast send' it is about to run (with the key redacted)
    5. execute resolveDispute() and settle the escrow

  ANTHROPIC_API_KEY must be set in ../.env for step 3.

  Watch the outcome:
      cast call $ESCROW "getState(uint256)(uint8)" $ESCROW_ID --rpc-url $RPC_URL
      # 6 = Resolved

      cast logs --address $ESCROW \\
          "DisputeResolved(uint256,address,uint8,address,uint256,string)" \\
          --rpc-url $RPC_URL
      # the full rationale is emitted on chain, verbatim

  What the contract guarantees regardless of what the model decides: the funds
  can only reach the buyer or the seller. resolveDispute takes a side, not a
  destination address. A compromised or hallucinating arbiter can pick the
  wrong winner — it cannot pay itself.

DONE

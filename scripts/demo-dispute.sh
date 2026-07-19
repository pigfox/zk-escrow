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

# shellcheck source=scripts/demo-lib.sh
. scripts/demo-lib.sh

AMOUNT_WEI="${AMOUNT_WEI:-1000000000000000}" # 0.001 ETH
PARTY_GAS_WEI="${PARTY_GAS_WEI:-400000000000000}"

demo_preflight

ESCROW="${1:-${ESCROW_ADDRESS:-}}"
[ -n "$ESCROW" ] || die "no escrow address. Pass one, or set ESCROW_ADDRESS in ../.env. Deploy with ./scripts/deploy.sh"

log "Throwaway identities"
ensure_demo_keys

# The operator's key acts purely as the ARBITER here — that is the key the
# agent signs with. Buyer and seller are both throwaways, so all three parties
# are distinct as the contract requires.
BUYER_ADDR="$DEMO_BUYER_ADDR"
BUYER_KEY="$DEMO_BUYER_KEY"
SELLER_ADDR="$DEMO_SELLER_ADDR"
SELLER_KEY="$DEMO_SELLER_KEY"
ARBITER_ADDR="$ADDRESS"

cat <<BANNER

  zk-escrow — ACT II: the AI dispute path
  ---------------------------------------
  escrow contract : $ESCROW
  buyer           : $BUYER_ADDR   (throwaway)
  seller          : $SELLER_ADDR   (throwaway)
  arbiter         : $ARBITER_ADDR   (the agent signs as this)
  amount          : $AMOUNT_WEI wei

BANNER

# Both throwaways need gas, and the buyer additionally needs the escrow value.
fund_to "$BUYER_ADDR" "$((AMOUNT_WEI + PARTY_GAS_WEI))" "demo buyer"
fund_to "$SELLER_ADDR" "$PARTY_GAS_WEI" "demo seller"

# ----------------------------------------------------------------------------
step "1. Buyer creates an escrow naming YOU as arbiter"
# ----------------------------------------------------------------------------
NEXT_ID="$(cast call "$ESCROW" "nextEscrowId()(uint256)" --rpc-url "$RPC_URL")"
NEXT_ID="${NEXT_ID%% *}"

# The commitment is irrelevant in this act — nobody will ever prove delivery.
COMMITMENT="$(cast keccak "undeliverable-$NEXT_ID")"

run cast send "$ESCROW" \
    "createEscrow(address,address,uint256,uint256)" \
    "$SELLER_ADDR" "$ARBITER_ADDR" "$AMOUNT_WEI" "$COMMITMENT" \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$BUYER_KEY" > /dev/null

ESCROW_ID="$NEXT_ID"
log "Created escrow #$ESCROW_ID"

# ----------------------------------------------------------------------------
step "2. Buyer funds it"
# ----------------------------------------------------------------------------
run cast send "$ESCROW" "fund(uint256)" "$ESCROW_ID" \
    --value "$AMOUNT_WEI" \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$BUYER_KEY" > /dev/null

# ----------------------------------------------------------------------------
step "3. Buyer raises a dispute with evidence"
# ----------------------------------------------------------------------------
BUYER_EVIDENCE="${BUYER_EVIDENCE:-I paid on the 3rd for a next-day delivery of one hardware wallet. Nothing arrived. The tracking number the seller gave me (1Z999AA10123456784) is not recognised on the carrier website. I have asked twice for a replacement number and received no reply.}"

run cast send "$ESCROW" "raiseDispute(uint256,string)" \
    "$ESCROW_ID" "$BUYER_EVIDENCE" \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$BUYER_KEY" > /dev/null

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
    --private-key "$SELLER_KEY" > /dev/null

log "Both sides have spoken. Current state:"
run cast call "$ESCROW" "getState(uint256)(uint8)" "$ESCROW_ID" --rpc-url "$RPC_URL"
echo "(5 = Disputed)"

# ----------------------------------------------------------------------------
cat <<DONE

  The stage is set. Escrow #$ESCROW_ID is Disputed, with evidence from both sides.
  ---------------------------------------------------------------------------

  Now start the arbiter and watch it work:

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

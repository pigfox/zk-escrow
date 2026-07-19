#!/usr/bin/env bash
#
# ACT I — the ZK happy path.
#
# A buyer escrows funds against a commitment. The seller delivers, proves
# knowledge of the delivery secret in zero knowledge, and the proof itself
# releases the money. No arbiter, no trust, no one revealing the secret.
#
#   create -> fund -> prove -> release -> withdraw
#
# Every cast command is echoed before it runs (with signing keys masked), so
# the walkthrough doubles as copy-pasteable documentation.
#
# Usage: ./scripts/demo-happy-path.sh [escrowAddress]
#   escrowAddress defaults to $ESCROW_ADDRESS from ../.env
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/demo-lib.sh
. scripts/demo-lib.sh

# The delivery secret. In a real deal this is whatever the seller and buyer
# agreed identifies delivery — a tracking number's hash, a signed receipt.
SECRET="${SECRET:-12345}"
AMOUNT_WEI="${AMOUNT_WEI:-1000000000000000}" # 0.001 ETH
SELLER_GAS_WEI="${SELLER_GAS_WEI:-300000000000000}" # enough for one withdraw

demo_preflight

ESCROW="${1:-${ESCROW_ADDRESS:-}}"
[ -n "$ESCROW" ] || die "no escrow address. Pass one, or set ESCROW_ADDRESS in ../.env. Deploy with ./scripts/deploy.sh"

log "Throwaway identities"
ensure_demo_keys

# The buyer is the operator; the seller is a throwaway. The arbiter is never
# used in this act, but the contract requires three distinct addresses, so the
# throwaway buyer identity stands in as a placeholder arbiter.
SELLER_ADDR="$DEMO_SELLER_ADDR"
SELLER_KEY="$DEMO_SELLER_KEY"
ARBITER_ADDR="$DEMO_BUYER_ADDR"

cat <<BANNER

  zk-escrow — ACT I: the ZK happy path
  ------------------------------------
  escrow contract : $ESCROW
  buyer           : $ADDRESS
  seller          : $SELLER_ADDR
  arbiter         : $ARBITER_ADDR   (never used in this act)
  amount          : $AMOUNT_WEI wei
  rpc             : $RPC_URL

BANNER

# ----------------------------------------------------------------------------
step "0. Derive the commitment from the delivery secret"
# ----------------------------------------------------------------------------
# The commitment is Poseidon(secret). Only its hash goes on chain — the secret
# never leaves the seller's machine.
echo "Deriving Poseidon(secret) locally (the secret itself never goes on chain)"
NEXT_ID="$(cast call "$ESCROW" "nextEscrowId()(uint256)" --rpc-url "$RPC_URL")"
NEXT_ID="${NEXT_ID%% *}"
echo "This will be escrow #$NEXT_ID"

HASHES="$(node scripts/poseidon.js "$SECRET" "$NEXT_ID")"
COMMITMENT="$(echo "$HASHES" | sed -n 's/^ *"commitment": "\([0-9]*\)".*/\1/p')"
[ -n "$COMMITMENT" ] || die "could not derive the commitment"
echo "commitment = $COMMITMENT"

# ----------------------------------------------------------------------------
step "1. Buyer creates the escrow"
# ----------------------------------------------------------------------------
run cast send "$ESCROW" \
    "createEscrow(address,address,uint256,uint256)" \
    "$SELLER_ADDR" "$ARBITER_ADDR" "$AMOUNT_WEI" "$COMMITMENT" \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$PRIVATE_KEY" > /dev/null

ESCROW_ID="$NEXT_ID"
log "Created escrow #$ESCROW_ID (state: Created)"

# ----------------------------------------------------------------------------
step "2. Buyer funds it"
# ----------------------------------------------------------------------------
run cast send "$ESCROW" "fund(uint256)" "$ESCROW_ID" \
    --value "$AMOUNT_WEI" \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$PRIVATE_KEY" > /dev/null

log "Funded (state: Funded). The money is now locked in the contract."
run cast call "$ESCROW" "getState(uint256)(uint8)" "$ESCROW_ID" --rpc-url "$RPC_URL"

# ----------------------------------------------------------------------------
step "3. Seller proves delivery in zero knowledge"
# ----------------------------------------------------------------------------
# The nullifier is a circuit OUTPUT derived from Poseidon(secret, escrowId).
# That binding is what makes the proof unusable against any other escrow.
echo "Generating a Groth16 proof that the seller knows the preimage of the commitment"
./scripts/prove.sh "$SECRET" "$ESCROW_ID"

PROOF_DIR="circuits/build/proofs/$ESCROW_ID"
[ -f "$PROOF_DIR/release-args.json" ] || die "proof generation failed"

# Read the cast-ready proof points, not the JSON ones: cast's array literals
# are bare and unspaced ([0xab,0xcd]), and it rejects the quoted, comma-space
# form snarkjs emits.
NULLIFIER="$(sed -n 's/^ *"nullifierDecimal": "\([0-9]*\)".*/\1/p' "$PROOF_DIR/release-args.json")"
PA="$(sed -n 's/^ *"castPA": "\(.*\)".*/\1/p' "$PROOF_DIR/release-args.json")"
PB="$(sed -n 's/^ *"castPB": "\(.*\)".*/\1/p' "$PROOF_DIR/release-args.json")"
PC="$(sed -n 's/^ *"castPC": "\(.*\)".*/\1/p' "$PROOF_DIR/release-args.json")"

[ -n "$NULLIFIER" ] && [ -n "$PA" ] && [ -n "$PB" ] && [ -n "$PC" ] \
    || die "could not read proof arguments from $PROOF_DIR/release-args.json"

# ----------------------------------------------------------------------------
step "4. The proof releases the funds"
# ----------------------------------------------------------------------------
# Note who sends this: it does not matter. release() is authorized by the
# proof, not by msg.sender. The money goes to the seller regardless.
run cast send "$ESCROW" \
    "release(uint256,uint256,uint256[2],uint256[2][2],uint256[2])" \
    "$ESCROW_ID" "$NULLIFIER" "$PA" "$PB" "$PC" \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$PRIVATE_KEY" > /dev/null

log "Released (state: Released). The secret was never revealed on chain."
run cast call "$ESCROW" "getState(uint256)(uint8)" "$ESCROW_ID" --rpc-url "$RPC_URL"

echo
echo "Seller's pending balance:"
run cast call "$ESCROW" "pendingWithdrawals(address)(uint256)" "$SELLER_ADDR" --rpc-url "$RPC_URL"

# ----------------------------------------------------------------------------
step "5. Seller withdraws (pull payment)"
# ----------------------------------------------------------------------------
# The contract never pushes ETH. The seller pulls, through a nonReentrant,
# CEI-ordered withdraw().
fund_to "$SELLER_ADDR" "$SELLER_GAS_WEI" "demo seller"

run cast send "$ESCROW" "withdraw()" \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$SELLER_KEY" > /dev/null

log "Withdrawn. Seller's on-chain balance:"
run cast balance "$SELLER_ADDR" --rpc-url "$RPC_URL"

cat <<DONE

  ACT I complete — escrow #$ESCROW_ID settled on a zero-knowledge proof.
  ---------------------------------------------------------------
  The buyer learned nothing about the secret; the chain learned nothing about
  the secret; and the proof that unlocked escrow #$ESCROW_ID is mathematically useless
  against any other escrow, because the nullifier is derived from the secret
  AND the escrow id.

  Next: ./scripts/demo-dispute.sh — what happens when delivery is contested.

DONE

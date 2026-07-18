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
# Every cast command is echoed before it runs, so the walkthrough doubles as
# copy-pasteable documentation.
#
# Usage: ./scripts/demo-happy-path.sh [escrowAddress]
#   escrowAddress defaults to $ESCROW_ADDRESS from ../.env
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENV_FILE="../.env"
BASE_SEPOLIA_CHAIN_ID=84532
DEFAULT_RPC_URL="https://sepolia.base.org"

# The delivery secret. In a real deal this is whatever the seller and buyer
# agreed identifies delivery — a tracking number's hash, a signed receipt.
SECRET="${SECRET:-12345}"
AMOUNT_WEI="${AMOUNT_WEI:-1000000000000000}" # 0.001 ETH

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
step() { printf '\n\033[1;36m--- %s ---\033[0m\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

REDACTED='***REDACTED***'

# Echo a command, then run it.
#
# `cast` takes signing keys as command-line arguments, so the echoed form is
# built separately from the executed one: any argument matching a known secret
# is replaced with a placeholder before printing. The real value only ever
# reaches argv, never stdout.
run() {
    local shown=() arg
    for arg in "$@"; do
        if [ -n "${PRIVATE_KEY:-}" ] && [ "$arg" = "$PRIVATE_KEY" ]; then
            shown+=("$REDACTED")
        elif [ -n "${SELLER_KEY:-}" ] && [ "$arg" = "$SELLER_KEY" ]; then
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

# This walkthrough drives buyer, seller and arbiter from one key for
# simplicity. The contract requires the three to be distinct addresses, so we
# derive two throwaway ones for the seller and arbiter roles.
SELLER_KEY="${SELLER_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
ARBITER_ADDR="${ARBITER_ADDR:-0x90F79bf6EB2c4f870365E785982E1f101E93b906}"
SELLER_ADDR="$(cast wallet address --private-key "$SELLER_KEY")"

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
echo "commitment = $COMMITMENT"

# ----------------------------------------------------------------------------
step "1. Buyer creates the escrow"
# ----------------------------------------------------------------------------
run cast send "$ESCROW" \
    "createEscrow(address,address,uint256,uint256)" \
    "$SELLER_ADDR" "$ARBITER_ADDR" "$AMOUNT_WEI" "$COMMITMENT" \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$PRIVATE_KEY"

ESCROW_ID="$NEXT_ID"
log "Created escrow #$ESCROW_ID (state: Created)"

# ----------------------------------------------------------------------------
step "2. Buyer funds it"
# ----------------------------------------------------------------------------
run cast send "$ESCROW" "fund(uint256)" "$ESCROW_ID" \
    --value "$AMOUNT_WEI" \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$PRIVATE_KEY"

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

NULLIFIER="$(sed -n 's/^ *"nullifierDecimal": "\([0-9]*\)".*/\1/p' "$PROOF_DIR/release-args.json")"
PA="$(sed -n 's/^ *"pA": \(\[.*\]\),$/\1/p' "$PROOF_DIR/release-args.json")"
PB="$(sed -n 's/^ *"pB": \(\[.*\]\),$/\1/p' "$PROOF_DIR/release-args.json")"
PC="$(sed -n 's/^ *"pC": \(\[.*\]\)$/\1/p' "$PROOF_DIR/release-args.json")"

# ----------------------------------------------------------------------------
step "4. The proof releases the funds"
# ----------------------------------------------------------------------------
# Note who sends this: it does not matter. release() is authorized by the
# proof, not by msg.sender. The money goes to the seller regardless.
run cast send "$ESCROW" \
    "release(uint256,uint256,uint256[2],uint256[2][2],uint256[2])" \
    "$ESCROW_ID" "$NULLIFIER" "$PA" "$PB" "$PC" \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$PRIVATE_KEY"

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
echo "Funding the throwaway seller address with gas dust so it can withdraw"
run cast send "$SELLER_ADDR" --value 100000000000000 \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$PRIVATE_KEY"

run cast send "$ESCROW" "withdraw()" \
    --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
    --private-key "$SELLER_KEY"

log "Withdrawn. Seller's on-chain balance:"
run cast balance "$SELLER_ADDR" --rpc-url "$RPC_URL"

cat <<'DONE'

  ACT I complete.
  ---------------
  A payment settled on a zero-knowledge proof of delivery. The buyer learned
  nothing about the secret; the chain learned nothing about the secret; and
  the proof that unlocked escrow #N is mathematically useless against escrow
  #N+1, because the nullifier is derived from the secret AND the escrow id.

  Next: ./scripts/demo-dispute.sh — what happens when delivery is contested.

DONE

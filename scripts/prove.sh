#!/usr/bin/env bash
#
# Generates a Groth16 delivery proof and prints it in the shape `cast send`
# wants for EscrowUpgradeable.release().
#
# Usage:
#   ./scripts/prove.sh <secret> <escrowId> [outDir]
#
#   secret    — the delivery secret, as a decimal field element
#   escrowId  — the escrow this proof may be spent against
#   outDir    — where to write proof.json / public.json / calldata
#               (default: circuits/build/proofs/<escrowId>)
#
# The commitment and nullifier are DERIVED here, not supplied: the circuit
# constrains commitment == Poseidon(secret) and nullifier == Poseidon(secret,
# escrowId), so any other value simply fails to witness. The commitment printed
# below is the one to pass to createEscrow().
#
# Requires ./scripts/build-circuit.sh to have been run first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CIRCUIT_NAME="delivery"
BUILD_DIR="circuits/build"
ZKEY="$BUILD_DIR/${CIRCUIT_NAME}_final.zkey"
WASM="$BUILD_DIR/${CIRCUIT_NAME}_js/${CIRCUIT_NAME}.wasm"
VKEY="$BUILD_DIR/verification_key.json"

SNARKJS="npx --no-install snarkjs"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ $# -ge 2 ] || die "usage: $0 <secret> <escrowId> [outDir]"

SECRET="$1"
ESCROW_ID="$2"
OUT_DIR="${3:-$BUILD_DIR/proofs/$ESCROW_ID}"

[ -f "$ZKEY" ] || die "proving key missing at $ZKEY. Run: ./scripts/build-circuit.sh"
[ -f "$WASM" ] || die "witness calculator missing at $WASM. Run: ./scripts/build-circuit.sh"
[ -d "node_modules/circomlibjs" ] || die "circomlibjs missing. Run: npm install"

mkdir -p "$OUT_DIR"

log "Deriving commitment and nullifier"
HASHES="$(node scripts/poseidon.js "$SECRET" "$ESCROW_ID")"
COMMITMENT="$(echo "$HASHES" | sed -n 's/^ *"commitment": "\([0-9]*\)".*/\1/p')"
NULLIFIER="$(echo "$HASHES" | sed -n 's/^ *"nullifier": "\([0-9]*\)".*/\1/p')"
COMMITMENT_HEX="$(echo "$HASHES" | sed -n 's/^ *"commitmentHex": "\(0x[0-9a-f]*\)".*/\1/p')"
NULLIFIER_HEX="$(echo "$HASHES" | sed -n 's/^ *"nullifierHex": "\(0x[0-9a-f]*\)".*/\1/p')"

[ -n "$COMMITMENT" ] || die "failed to derive commitment"
[ -n "$NULLIFIER" ] || die "failed to derive nullifier"
[ -n "$COMMITMENT_HEX" ] || die "failed to derive commitment (hex)"
[ -n "$NULLIFIER_HEX" ] || die "failed to derive nullifier (hex)"

cat > "$OUT_DIR/input.json" <<EOF
{
  "secret": "$SECRET",
  "commitment": "$COMMITMENT",
  "escrowId": "$ESCROW_ID"
}
EOF

log "Computing witness"
$SNARKJS wtns calculate "$WASM" "$OUT_DIR/input.json" "$OUT_DIR/witness.wtns"

log "Generating Groth16 proof"
$SNARKJS groth16 prove "$ZKEY" "$OUT_DIR/witness.wtns" \
    "$OUT_DIR/proof.json" "$OUT_DIR/public.json"

log "Verifying proof locally before printing calldata"
$SNARKJS groth16 verify "$VKEY" "$OUT_DIR/public.json" "$OUT_DIR/proof.json"

log "Exporting Solidity calldata"
$SNARKJS zkey export soliditycalldata "$OUT_DIR/public.json" "$OUT_DIR/proof.json" \
    > "$OUT_DIR/calldata.txt"

# snarkjs prints: [a], [[b]], [c], [pubSignals] — split into the four groups so
# callers can drop them straight into `cast send`.
CALLDATA="$(cat "$OUT_DIR/calldata.txt")"
PA="$(echo "$CALLDATA" | sed -n 's/^\(\[[^]]*\]\),\[\[.*/\1/p')"
PB="$(echo "$CALLDATA" | sed -n 's/^\[[^]]*\],\(\[\[[^]]*\],\[[^]]*\]\]\),\[.*/\1/p')"
PC="$(echo "$CALLDATA" | sed -n 's/.*\]\],\(\[[^]]*\]\),\[[^]]*\]$/\1/p')"

# snarkjs emits the proof points as a JSON array — quoted, comma-space
# separated. `cast` will not parse that: its array literals are bare and
# unspaced, e.g. [0xab,0xcd]. Keep both forms rather than making callers guess
# which one they need — the JSON `pA`/`pB`/`pC` for the Solidity fixtures, and
# `castPA`/`castPB`/`castPC` for anything shelling out to cast.
PA_CAST="$(echo "$PA" | tr -d '" ')"
PB_CAST="$(echo "$PB" | tr -d '" ')"
PC_CAST="$(echo "$PC" | tr -d '" ')"

# All field elements are written as 0x-hex so Solidity fixtures can read them
# with vm.parseBytes32; the decimal forms are kept alongside for humans and for
# pasting into `cast`.
cat > "$OUT_DIR/release-args.json" <<EOF
{
  "escrowId": "$(printf '0x%064x' "$ESCROW_ID")",
  "escrowIdDecimal": "$ESCROW_ID",
  "commitment": "$COMMITMENT_HEX",
  "commitmentDecimal": "$COMMITMENT",
  "nullifier": "$NULLIFIER_HEX",
  "nullifierDecimal": "$NULLIFIER",
  "pA": $PA,
  "pB": $PB,
  "pC": $PC,
  "castPA": "$PA_CAST",
  "castPB": "$PB_CAST",
  "castPC": "$PC_CAST"
}
EOF

echo
echo "commitment (pass to createEscrow): $COMMITMENT"
echo "nullifier  (pass to release):      $NULLIFIER"
echo
echo "release() arguments, ready to paste into cast:"
echo "  escrowId  $ESCROW_ID"
echo "  nullifier $NULLIFIER"
echo "  pA        $PA_CAST"
echo "  pB        $PB_CAST"
echo "  pC        $PC_CAST"
echo
echo "artifacts: $OUT_DIR/{proof.json,public.json,calldata.txt,release-args.json}"

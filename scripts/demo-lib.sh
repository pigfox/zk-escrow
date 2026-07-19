#!/usr/bin/env bash
#
# Shared helpers for the two demo walkthroughs.
#
# Not executable on its own — source it:
#   . "$(dirname "${BASH_SOURCE[0]}")/demo-lib.sh"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
step() { printf '\n\033[1;36m--- %s ---\033[0m\n' "$*"; }
warn() { printf '\033[1;33mnote:\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Secret redaction
# ---------------------------------------------------------------------------
REDACTED='***REDACTED***'

# Every private key the script might pass to cast. `run` redacts anything in
# here when echoing. Register a key the moment you obtain it — a key that is
# used but never registered is exactly the bug this list exists to prevent.
REDACT_KEYS=()

redact_register() {
    local k
    for k in "$@"; do
        [ -n "$k" ] && REDACT_KEYS+=("$k")
    done
}

# Echo a command with every registered secret masked, then run it for real.
#
# cast takes signing keys as command-line arguments and will not read them from
# the environment, so the printed form is built separately from the executed
# one. The real value only ever reaches argv.
run() {
    local shown=() arg key masked
    for arg in "$@"; do
        masked="$arg"
        for key in "${REDACT_KEYS[@]}"; do
            [ -n "$key" ] && [ "$arg" = "$key" ] && masked="$REDACTED" && break
        done
        shown+=("$masked")
    done
    printf '\033[0;90m$ %s\033[0m\n' "${shown[*]}"
    "$@"
}

# ---------------------------------------------------------------------------
# Throwaway demo identities
# ---------------------------------------------------------------------------
#
# The escrow needs three distinct addresses, but the operator only has one key.
# The demos therefore need throwaway seller/buyer identities.
#
# These MUST NOT be the well-known Anvil/Hardhat test keys. Those are published
# in every Foundry install, and on a public testnet they are actively swept:
# fund one and the ETH is gone before the next block. Base Sepolia's Anvil #4
# even carries an EIP-7702 delegation to a sweeper contract, so a transfer to
# it is forwarded on immediately and the account is left at zero — which shows
# up later as a baffling "gas required exceeds allowance (0)".
#
# So: generate real random keys on first run, and cache them in a gitignored,
# 0600 file so repeat runs reuse the same addresses and their leftover gas dust
# accumulates instead of being stranded one address at a time.
DEMO_KEYS_FILE="${DEMO_KEYS_FILE:-.demo-keys.env}"

ensure_demo_keys() {
    if [ -f "$DEMO_KEYS_FILE" ]; then
        # shellcheck disable=SC1090
        . "$DEMO_KEYS_FILE"
    fi

    local created=0
    local name
    for name in DEMO_SELLER_KEY DEMO_BUYER_KEY; do
        if [ -z "${!name:-}" ]; then
            local generated
            generated="$(cast wallet new 2>/dev/null \
                | sed -n 's/^Private key: *\(0x[0-9a-fA-F]\{64\}\)$/\1/p')"
            [ -n "$generated" ] || die "could not generate a throwaway key with 'cast wallet new'"
            printf '%s=%s\n' "$name" "$generated" >> "$DEMO_KEYS_FILE"
            export "$name=$generated"
            created=1
        fi
    done

    chmod 600 "$DEMO_KEYS_FILE"

    DEMO_SELLER_ADDR="$(cast wallet address --private-key "$DEMO_SELLER_KEY")"
    DEMO_BUYER_ADDR="$(cast wallet address --private-key "$DEMO_BUYER_KEY")"

    redact_register "$DEMO_SELLER_KEY" "$DEMO_BUYER_KEY"

    if [ "$created" = "1" ]; then
        log "Generated throwaway demo identities -> $DEMO_KEYS_FILE (gitignored, 0600)"
        echo "  These are freshly random, NOT the published Anvil keys, so testnet"
        echo "  sweeper bots cannot drain them. Reused on subsequent runs."
    fi
    echo "  demo seller: $DEMO_SELLER_ADDR"
    echo "  demo buyer : $DEMO_BUYER_ADDR"
}

# Tops a throwaway address up to `need` wei, skipping the transfer when it is
# already funded — so repeat runs do not spray dust.
#
# Verifies the balance AFTER transferring rather than trusting the receipt: a
# swept or delegating recipient can accept a transfer and still end at zero,
# and failing here with a clear message beats failing three steps later with an
# opaque gas error.
fund_to() {
    local addr="$1" need="$2" label="$3"
    local have
    have="$(cast balance "$addr" --rpc-url "$RPC_URL")"

    if [ "$(echo "$have >= $need" | bc)" = "1" ]; then
        echo "  $label $addr already holds $(cast from-wei "$have") ETH — skipping top-up"
        return 0
    fi

    local top_up=$((need - have))
    log "Funding $label with $(cast from-wei "$top_up") ETH"
    run cast send "$addr" --value "$top_up" \
        --rpc-url "$RPC_URL" --chain-id "$BASE_SEPOLIA_CHAIN_ID" \
        --private-key "$PRIVATE_KEY" > /dev/null

    have="$(cast balance "$addr" --rpc-url "$RPC_URL")"
    if [ "$(echo "$have >= $need" | bc)" = "1" ]; then
        echo "  $label now holds $(cast from-wei "$have") ETH"
    else
        die "$label is at $(cast from-wei "$have") ETH after funding — expected at least $(cast from-wei "$need"). The address may be swept or delegating; delete $DEMO_KEYS_FILE to regenerate identities."
    fi
}

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
BASE_SEPOLIA_CHAIN_ID=84532
DEFAULT_RPC_URL="https://sepolia.base.org"

# Loads ../.env, asserts the basics, and pins the network.
demo_preflight() {
    local env_file="../.env"
    [ -f "$env_file" ] || die "no $env_file. Copy .env.example to ../.env and populate it."
    # shellcheck disable=SC1090
    set -a; . "$env_file"; set +a

    [ -n "${ADDRESS:-}" ] || die "ADDRESS is empty in $env_file"
    [ -n "${PRIVATE_KEY:-}" ] || die "PRIVATE_KEY is empty in $env_file"
    redact_register "$PRIVATE_KEY"

    RPC_URL="${RPC_URL:-$DEFAULT_RPC_URL}"

    local actual
    actual="$(cast chain-id --rpc-url "$RPC_URL")" || die "cannot reach $RPC_URL"
    [ "$actual" = "$BASE_SEPOLIA_CHAIN_ID" ] \
        || die "refusing to run: chain $actual is not Base Sepolia ($BASE_SEPOLIA_CHAIN_ID)"

    command -v bc >/dev/null 2>&1 || die "bc is required for balance arithmetic"
}

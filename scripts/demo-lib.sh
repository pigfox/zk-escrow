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
# Demo identities — the unified DEMO_* roles
# ---------------------------------------------------------------------------
#
# The escrow needs three distinct addresses (createEscrow reverts with
# DuplicateParty otherwise), and the estate provides exactly three standing
# ones: Investor A buys, Investor B sells, and the arbiter settles. They are
# the same roles every other demo in the estate uses, so an address seen here
# is the address seen there — and they are long-lived, so their leftover gas
# dust accumulates instead of being stranded one throwaway at a time.
#
# Earlier revisions generated random per-run identities into a gitignored
# .demo-keys.env. That file is obsolete: the roles below replace it.
load_demo_roles() {
    [ -n "${DEMO_INVESTOR_A_PK:-}" ] || die "DEMO_INVESTOR_A_PK is empty in ../.env"
    [ -n "${DEMO_INVESTOR_B_PK:-}" ] || die "DEMO_INVESTOR_B_PK is empty in ../.env"
    [ -n "${DEMO_ARBITER_ADDR:-}" ] || die "DEMO_ARBITER_ADDR is empty in ../.env"

    redact_register "$DEMO_INVESTOR_A_PK" "$DEMO_INVESTOR_B_PK"

    # Derive rather than trust the *_ADDR values: a key/address pair that has
    # drifted would otherwise fail three steps later as an opaque revert.
    BUYER_ADDR="$(cast wallet address --private-key "$DEMO_INVESTOR_A_PK")"
    SELLER_ADDR="$(cast wallet address --private-key "$DEMO_INVESTOR_B_PK")"
    BUYER_KEY="$DEMO_INVESTOR_A_PK"
    SELLER_KEY="$DEMO_INVESTOR_B_PK"
    ARBITER_ADDR="$DEMO_ARBITER_ADDR"

    echo "  buyer   (Investor A): $BUYER_ADDR"
    echo "  seller  (Investor B): $SELLER_ADDR"
    echo "  arbiter             : $ARBITER_ADDR"
}

# Tops a role address up to `need` wei, skipping the transfer when it is
# already funded — so repeat runs do not spray dust. The treasury role
# (DEMO_OPERATOR) pays, because it is the one holding the consolidated float.
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
        --private-key "$DEMO_OPERATOR_PK" > /dev/null

    have="$(cast balance "$addr" --rpc-url "$RPC_URL")"
    if [ "$(echo "$have >= $need" | bc)" = "1" ]; then
        echo "  $label now holds $(cast from-wei "$have") ETH"
    else
        die "$label is at $(cast from-wei "$have") ETH after funding — expected at least $(cast from-wei "$need"). The address may be swept or delegating."
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

    [ -n "${DEMO_OPERATOR_PK:-}" ] || die "DEMO_OPERATOR_PK is empty in $env_file"
    redact_register "$DEMO_OPERATOR_PK"

    # DEMO_RPC_URL is where OUR clients talk. It is deliberately not the
    # endpoint the site advertises to a wallet: sepolia.base.org throttles an
    # operator box that has been running the chain suites all day.
    RPC_URL="${DEMO_RPC_URL:-${RPC_URL:-$DEFAULT_RPC_URL}}"

    local actual
    actual="$(cast chain-id --rpc-url "$RPC_URL")" || die "cannot reach $RPC_URL"
    [ "$actual" = "$BASE_SEPOLIA_CHAIN_ID" ] \
        || die "refusing to run: chain $actual is not Base Sepolia ($BASE_SEPOLIA_CHAIN_ID)"

    command -v bc >/dev/null 2>&1 || die "bc is required for balance arithmetic"
}

#!/usr/bin/env bash
#
# Deploys zk-escrow to Base Sepolia.
#
# Secrets are read from ../.env — one directory ABOVE this repo, so they can
# never be committed. If they are not populated yet this script says so and
# exits 0, because "the operator has not set up credentials" is not a build
# failure.
#
# Base Sepolia only. The chain id is checked here AND asserted inside
# script/Deploy.s.sol, so neither a typo'd RPC URL nor a stale env var can
# point this at a network that matters.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENV_FILE="../.env"
BASE_SEPOLIA_CHAIN_ID=84532
DEFAULT_RPC_URL="https://sepolia.base.org"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mnote:\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [ ! -f "$ENV_FILE" ]; then
    warn "no $ENV_FILE found."
    echo
    echo "  Create it from the template in this repo, then re-run:"
    echo "    cp .env.example ../.env"
    echo "    \$EDITOR ../.env      # fill in ADDRESS and PRIVATE_KEY"
    echo "    ./scripts/deploy.sh"
    echo
    exit 0
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

if [ -z "${ADDRESS:-}" ] || [ -z "${PRIVATE_KEY:-}" ]; then
    warn "ADDRESS and/or PRIVATE_KEY are empty in $ENV_FILE."
    echo
    echo "  Populate ../.env then re-run scripts/deploy.sh:"
    echo "    ADDRESS=0xYourBaseSepoliaAddress"
    echo "    PRIVATE_KEY=0xYourPrivateKey"
    echo
    echo "  Fund the address with Base Sepolia ETH first:"
    echo "    https://www.alchemy.com/faucets/base-sepolia"
    echo
    echo "  Nothing was deployed. This is not a failure — the build, test and"
    echo "  CI paths never need these values."
    exit 0
fi

RPC_URL="${RPC_URL:-$DEFAULT_RPC_URL}"

log "Verifying the RPC endpoint is Base Sepolia"
ACTUAL_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")" \
    || die "could not reach $RPC_URL"

if [ "$ACTUAL_CHAIN_ID" != "$BASE_SEPOLIA_CHAIN_ID" ]; then
    die "refusing to deploy: $RPC_URL is chain $ACTUAL_CHAIN_ID, expected Base Sepolia ($BASE_SEPOLIA_CHAIN_ID)"
fi

# Confirm the key matches the declared address before spending gas on a
# deploy that would end up owned by someone else.
DERIVED="$(cast wallet address --private-key "$PRIVATE_KEY")"
if [ "${DERIVED,,}" != "${ADDRESS,,}" ]; then
    die "PRIVATE_KEY derives to $DERIVED but ADDRESS is $ADDRESS — check ../.env"
fi

BALANCE="$(cast balance "$ADDRESS" --rpc-url "$RPC_URL")"
log "Deployer $ADDRESS has $(cast from-wei "$BALANCE") ETH on Base Sepolia"
if [ "$BALANCE" = "0" ]; then
    die "deployer has no ETH. Fund it: https://www.alchemy.com/faucets/base-sepolia"
fi

FORGE_ARGS=(
    script script/Deploy.s.sol:Deploy
    --rpc-url "$RPC_URL"
    --broadcast
)

if [ -n "${ETHERSCAN_API_KEY:-}" ]; then
    log "ETHERSCAN_API_KEY present — will verify on BaseScan"
    FORGE_ARGS+=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")
else
    warn "no ETHERSCAN_API_KEY — broadcasting without source verification."
    warn "Set it in ../.env to verify on BaseScan."
fi

log "Deploying"
# PRIVATE_KEY reaches the script through the environment, never the command
# line, so it cannot show up in shell history or process listings.
forge "${FORGE_ARGS[@]}"

echo
log "Done. Copy the proxy address into ../.env as ESCROW_ADDRESS and into the"
log "README's deployed-addresses block."

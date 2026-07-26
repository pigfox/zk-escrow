#!/usr/bin/env bash
#
# Starts the AI arbiter agent against the live deployment.
#
# The agent reads its whole configuration from the process environment and
# nothing from disk, and it predates the unified DEMO_* roles — so its env
# interface (PRIVATE_KEY, ESCROW_ADDRESS, RPC_URL) still uses generic names.
# This script is the one place that mapping lives, so no operator has to
# remember that the agent's PRIVATE_KEY means the ARBITER's key specifically,
# and never the deployer's.
#
# It polls every config.PollInterval and runs until interrupted (Ctrl-C).
#
# Usage: ./scripts/run-arbiter.sh [escrowAddress]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENV_FILE="../.env"
[ -f "$ENV_FILE" ] || { echo "error: no $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

[ -n "${DEMO_ARBITER_PK:-}" ] || { echo "error: DEMO_ARBITER_PK is empty in $ENV_FILE" >&2; exit 1; }

ESCROW="${1:-${DEMO_ESCROW_ADDRESS:-}}"
[ -n "$ESCROW" ] || { echo "error: no escrow address (pass one or set DEMO_ESCROW_ADDRESS)" >&2; exit 1; }

# The arbiter signs rulings; the deployer key must never reach the agent.
export PRIVATE_KEY="$DEMO_ARBITER_PK"
export ESCROW_ADDRESS="$ESCROW"

# ARBITER_RPC_URL overrides DEMO_RPC_URL for this one client, because the agent
# needs something DEMO_RPC_URL is not guaranteed to give it: a node at the head
# of the chain that will serve eth_getLogs over the lookback window. A free
# endpoint that lags by an hour, or that fences historical filters behind a
# token, makes the agent scan blocks that predate the dispute and find nothing.
export RPC_URL="${ARBITER_RPC_URL:-${DEMO_RPC_URL:-${RPC_URL:-https://sepolia.base.org}}}"

echo "arbiter agent -> escrow $ESCROW as ${DEMO_ARBITER_ADDR:-<derived>}"
cd agent && exec go run .

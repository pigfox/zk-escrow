# zk-escrow

[![CI](https://github.com/pigfox/zk-escrow/actions/workflows/ci.yml/badge.svg)](https://github.com/pigfox/zk-escrow/actions/workflows/ci.yml)
![Solidity coverage](https://img.shields.io/badge/solidity%20coverage-100%25-brightgreen)
![Go coverage](https://img.shields.io/badge/go%20coverage-100.0%25-brightgreen)
![Foundry](https://img.shields.io/badge/tested%20with-foundry-orange)
![Echidna](https://img.shields.io/badge/fuzzed%20with-echidna-blue)
![Medusa](https://img.shields.io/badge/fuzzed%20with-medusa-blue)
![Slither](https://img.shields.io/badge/analyzed%20with-slither-informational)
![Base Sepolia](https://img.shields.io/badge/network-base%20sepolia-lightgrey)

An upgradeable escrow on Base Sepolia with two ways out. On the happy path the
seller releases the funds by proving, in zero knowledge, that they know a
delivery secret — the money moves on a Groth16 proof, not on anyone's say-so,
and the secret never touches the chain. When delivery is contested there is no
proof to be had, so the escrow falls to an arbiter, and the arbiter here is a Go
agent that reads both parties' evidence, asks a frontier model for a ruling
(Claude or GPT, whichever `AI_PROVIDER` names), and executes
it on chain with `cast`. The contract is deliberately built so that the AI
cannot be trusted with more than it needs: `resolveDispute` takes a *side*, not
a destination, so a compromised or hallucinating arbiter can pick the wrong
winner but can never pay itself.

---

## Live on Base Sepolia

| Contract | Address |
| --- | --- |
| **Proxy** ← interact with this | [`0x4421E53D0dd051159d1a0F03d45554313e3e9774`](https://sepolia.basescan.org/address/0x4421E53D0dd051159d1a0F03d45554313e3e9774#code) |
| Implementation — **live** | [`0x22c90633D3537B3F4555541F23b4A243F6a91b8A`](https://sepolia.basescan.org/address/0x22c90633D3537B3F4555541F23b4A243F6a91b8A#code) |
| Implementation — superseded | [`0x36dDB82CCE0AE251d68369C794070a09021D6825`](https://sepolia.basescan.org/address/0x36dDB82CCE0AE251d68369C794070a09021D6825#code) |
| Verifier | [`0x20B98B460c1252974177215EaDa7A61259Ad5825`](https://sepolia.basescan.org/address/0x20B98B460c1252974177215EaDa7A61259Ad5825#code) |
| Owner | `0xb6c3a56CA2f99e3F5d7d16ad968df9f71cCC184D` |

All verified on BaseScan. Chain id 84532. Deployed **2026-07-26**, fresh, then
seeded with the two acts this repo exists to demonstrate.

The implementation was **upgraded on 2026-07-31** (PF-S124) after natspec was
added to `EscrowUpgradeable`. The proxy address did not change and neither did
anything it holds: all 14 escrows, the settlement history and the spent-nullifier
set are exactly where they were. That is what the proxy is for — a source change
that alters no storage layout and no behaviour is an upgrade, never a
redeployment. `upgradeToAndCall` was called with empty calldata, since there is no
reinitializer to run. Rehearsed first on throwaway contracts with
`script/RecoveryDrill.s.sol`, and read back afterwards: implementation slot
holds the new address, `nextEscrowId` is still 14, owner and verifier unchanged,
escrow 0 still `Released` and escrow 1 still `Resolved`.

| Escrow | Act | Outcome |
| --- | --- | --- |
| #0 | `scripts/demo-happy-path.sh` | `Released` — settled by a real Groth16 proof of the delivery secret; the seller pulled the payment. |
| #1 | `scripts/demo-dispute.sh` + the agent | `Resolved` — contested delivery, settled by the AI arbiter, ruling `SellerWins` and the full rationale written on chain ([tx](https://sepolia.basescan.org/tx/0xb6b43f7e587f9aba983190b9553017df6fb2d2d958c71d39690b12ab118345e9)). |

Everything past #1 is visitor traffic. The site's counters are live chain reads,
so they show whatever is actually there.

> **Everything below this line describes the v1 deployment**, which is retired but
> still on chain: the four completed escrows, the nine stranded disputes, the UUPS
> upgrade that recovered them, and the AI rulings all happened *there*. It is kept
> because it is the honest record of how this contract behaved under real traffic —
> but none of those numbers belong to the deployment above. v1 addresses are listed
> under [v1 deployment (retired)](#v1-deployment-retired-2026-07-26).

## The v1 record

Four escrows ran to completion on v1: **#0 and #1 released by zero-knowledge
proof**, **#2 and #3 settled by the AI arbiter**. Across all four the arbiter
routed 0.003 ETH between buyers and sellers and took **nothing** — its
`pendingWithdrawals` balance was `0`, and the contract's ETH balance equalled
`totalPendingWithdrawals` to the wei. Invariants (a) and (b) below are not just
fuzzer output; they held against real traffic.

---

## Recovery: the V2 arbiter rotation — on the RETIRED v1 deployment

> Everything in this section happened on the **v1 proxy
> [`0x8bB2ae77…8A84` (retired)](https://sepolia.basescan.org/address/0x8bB2ae77AcE1424a9418f32bb2b2077563eE8A84)**,
> not on the live deployment at the top of this file. The addresses below are v1
> artifacts and are kept as the record; nothing here reads them.

A later audit of the then-live v1 deployment found **nine escrows stranded in `Disputed`**
(#5, #6, #8, #10, #14, #15, #16, #20, #22). Every one named the same arbiter — an
address that, by an earlier design choice, was **address-only: no private key
existed for it anywhere.** A keyless arbiter can never call `resolveDispute`, so
those nine could never be settled. The funds were never at risk (they can only ever
reach the buyer or seller), but they were frozen.

The fix used the one authority that was still keyed — the `owner` (the UUPS upgrade
authority) — without touching the escrow logic or the funds:

1. **A fresh keyed arbiter** was generated locally and funded with gas dust.
2. **`EscrowUpgradeableV2`** was deployed and the proxy upgraded to it
   (`upgradeToAndCall`). V2's only addition is one owner-only function,
   `setArbiter(escrowId, newArbiter)`, guarded to a `Disputed` escrow and a new
   arbiter distinct from the two parties (it emits `ArbiterRotated`). The storage
   layout is byte-identical to V1 — the upgrade is a pure function + event append.
3. **All nine arbiters were rotated** to the fresh keyed address, each read back on
   chain to confirm.

The upgrade was rehearsed before any real transaction was broadcast: deploy V2 →
upgrade → `setArbiter` → `resolveDispute` as the new arbiter, asserting funds route
to the ruled side, the state reaches `Resolved`, and the arbiter is never credited.

That rehearsal originally ran against a local *copy* of live chain state. It no
longer does — pointing the EVM at a copied chain is now banned outright in this
repo — and ships as two pieces:

- **`test/RecoveryDrill.t.sol`** — the same sequence in pure EVM, built from
  scratch with no RPC access. Runs on every `forge test`, including in CI, and
  covers the ruled-either-way outcomes plus the owner-only and stale-arbiter
  refusals.
- **`script/RecoveryDrill.s.sol`** — the same sequence against **real Base
  Sepolia**, on contracts it deploys itself. It never learns the live proxy's
  address, so it cannot touch the demo. Gated behind `RECOVERY_DRILL=true`:

  ```sh
  RECOVERY_DRILL=true forge script script/RecoveryDrill.s.sol:RecoveryDrill \
    --rpc-url "$DEMO_RPC_URL" --broadcast -vv
  ```

| Step | Address / tx |
| --- | --- |
| V2 implementation (retired, v1 estate) | [`0x1cB2207f11baE16d194a9C187a9bE1F0b38a1637` (retired)](https://sepolia.basescan.org/address/0x1cB2207f11baE16d194a9C187a9bE1F0b38a1637#code) |
| Upgrade (`upgradeToAndCall`) on the v1 proxy | [`0x875a9d68…` (retired)](https://sepolia.basescan.org/tx/0x875a9d68b8249575a4ef61de6e1fc457db758ca2182b18604b977db2488c7e63) |
| New arbiter — on nine **v1** escrows only, never a global role | `0x6BBc782624B3c604e32Ed8b8C00d273970F67d0C` (retired, keyless) |
| Nine rotations | escrows 5, 6, 8, 10, 14, 15, 16, 20, 22 — hashes in [`deployments/base-sepolia.json`](deployments/base-sepolia.json) |
| Nine settlements | escrows 5, 6, 8, 10, 14, 15, 16, 20, 22 — all `BuyerWins`, tx hashes in [`docs/settlements-2026-07.md`](docs/settlements-2026-07.md) |

With the arbiter keyed and funded, the **nine stranded disputes were settled by the
AI arbiter, all rulings on-chain** — the agent scanned each `DisputeRaised` evidence
trail, ruled, and called `resolveDispute` as the fresh arbiter, writing both the
ruling and its full reasoning to chain; every escrow was read back to `Resolved`. The
rulings, rationales, and transaction hashes are tabulated in
[`docs/settlements-2026-07.md`](docs/settlements-2026-07.md). To reproduce a run the
agent needs an `ANTHROPIC_API_KEY` (or `OPENAI_API_KEY` with `AI_PROVIDER=openai`) and
a `START_BLOCK_LOOKBACK` deep enough to reach the oldest dispute — see
[Agent configuration](#agent-configuration).

---

## The AI rulings

Both disputes were decided by a model reading the parties' on-chain evidence,
and both rationales are stored verbatim in the `DisputeResolved` event. Nothing
below is paraphrased — it is what the chain says.

### Escrow #3 — both sides heard
[`0x8725c2e7…`](https://sepolia.basescan.org/tx/0x8725c2e7e78baea855f82a744733f16112aa9bc7aeb6fbb0060be6c61f281a8d)
· ruling **SellerWins** · 0.001 ETH to the seller

The buyer complained the tracking number was unrecognised and nothing arrived.
Taken alone that reads as non-delivery. The seller then conceded the number was
mistyped, supplied the corrected one, and cited a signed proof of delivery. The
model weighed the two accounts against each other and **reversed the naive
reading**, because a corrected-and-evidenced account beats an unevidenced one:

> Buyer: you provided that the tracking number you received was unrecognized and
> that nothing arrived, but you did not provide any evidence of non-delivery
> (e.g., carrier claim, return, or proof you never received the package).
> Seller: you credibly corrected the tracking number (explaining the buyer’s
> mistype) and provided that the carrier shows the shipment as delivered and
> signed for on the 5th, with signed proof-of-delivery available. With delivery
> confirmation and no counter-evidence from the Buyer, the escrow should be
> released to the Seller.

### Escrow #2 — arbitration on an incomplete record
[`0xd79a68d3…`](https://sepolia.basescan.org/tx/0xd79a68d3222bac8bcac4f4ebc6f7f41991a964468678a4e28e024e1f773e5fb5)
· ruling **BuyerWins** · 0.001 ETH to the buyer

Only the buyer's evidence reached the chain here: the seller's `submitEvidence`
transaction was the one killed by the sweeper bug described in
[Lessons from a live testnet](#lessons-from-a-live-testnet). The model ruled on
what it actually had, which is the honest behaviour — but it is a one-sided
record, and the ruling should be read as such:

> Buyer provided evidence of timely payment (on the 3rd) and requested next-day
> delivery of a hardware wallet, but the item did not arrive. The tracking
> number provided by the Seller (1Z999AA10123456784) is not recognized by the
> carrier, and Buyer states they asked twice for a replacement tracking number
> and received no response. This supports non-delivery and lack of timely
> communication by the Seller, so the Buyer should be awarded the escrow.

Whatever the model decides, the contract bounds the damage: `resolveDispute`
takes a *side*, not a destination, so a wrong ruling misroutes between the two
parties and can never pay the arbiter. See [Trust model](#trust-model).

---

## Architecture

```mermaid
flowchart TB
    subgraph offchain["Off-chain"]
        seller["Seller"]
        buyer["Buyer"]
        circuit["delivery.circom<br/>Poseidon commitment<br/>+ escrow-bound nullifier"]
        prove["scripts/prove.sh<br/>snarkjs groth16"]
        agent["Go agent<br/>ticker + eth_getLogs"]
        claude["Claude API<br/>JSON ruling + rationale"]
        cast["cast send"]
    end

    subgraph onchain["Base Sepolia (chain 84532)"]
        proxy["ERC-1967 Proxy"]
        impl["EscrowUpgradeable<br/>UUPS · state machine · pull payments"]
        verifier["Groth16Verifier<br/>generated by snarkjs"]
        pending["pendingWithdrawals<br/>(pull payments)"]
    end

    buyer -->|createEscrow / fund| proxy
    seller --> circuit
    circuit --> prove
    prove -->|proof + nullifier| proxy
    proxy -.->|delegatecall| impl
    impl -->|verifyProof| verifier

    buyer -->|raiseDispute + evidence| proxy
    seller -->|submitEvidence| proxy
    proxy -->|DisputeRaised logs| agent
    agent --> claude
    claude -->|ruling + rationale| agent
    agent --> cast
    cast -->|resolveDispute| proxy

    impl -->|credit| pending
    pending -->|withdraw| buyer
    pending -->|withdraw| seller
```

### State machine

```mermaid
stateDiagram-v2
    [*] --> Created: createEscrow
    Created --> Funded: fund (buyer, exact amount)
    Funded --> Released: release (valid Groth16 proof)
    Funded --> Refunded: refund (seller)
    Funded --> Disputed: raiseDispute (either party)
    Disputed --> Resolved: resolveDispute (arbiter only)
    Released --> [*]
    Refunded --> [*]
    Resolved --> [*]
```

Every settlement credits `pendingWithdrawals`; nothing is ever pushed. Payees
pull via `withdraw()`, which is `nonReentrant` and orders effects before the
external call.

---

## The two-act demo

### Act I — the ZK happy path

```bash
./scripts/demo-happy-path.sh
```

`create → fund → prove → release → withdraw`. The seller generates a proof that
they know `s` such that `Poseidon(s) == commitment`, and the proof releases the
escrow. Note who sends the release transaction: it does not matter. `release()`
is authorized by the proof, not by `msg.sender`.

Escrows [#0](https://sepolia.basescan.org/tx/0xdf38bcdc280addfb012696c6e5fcc6655abedf1648727c012d2f7e096e5a03d7)
and [#1](https://sepolia.basescan.org/tx/0xfedaf8127505c68bc759b86f35dc0158572f5d527844f03794dce7f2acb65f87)
did exactly that on chain — the same secret, so an identical commitment, but a
different nullifier each, both now spent:

```
commitment (both)   4267533774488295900887461483015112262021273608761099826938271132511348470966
nullifier escrow #0  540663689097534992617434090946771188169151136163418449976754366008491461789
nullifier escrow #1 4213355460611018654523924795294902999663126022355729006200928612083214729114
```

That difference is the anti-replay property, live: the nullifier is
`Poseidon(secret, escrowId)`, so escrow #0's proof is not merely rejected
against escrow #1 — it is unprovable there.

### Act II — the AI dispute path

```bash
./scripts/demo-dispute.sh
# then, in another shell:
./scripts/run-arbiter.sh
```

`create → fund → dispute → counter-evidence → agent rules → settle`. The agent
polls for `DisputeRaised`, gathers every submission for the escrow, asks the
configured model for a ruling as strict JSON, prints the exact `cast send` it is about to run
(with the key redacted), and executes it. The full rationale is emitted on chain
in the `DisputeResolved` event.

#### Agent configuration

Read from the environment only — `source ../.env` before running.

| Variable | Default | Meaning |
| --- | --- | --- |
| `AI_PROVIDER` | `anthropic` | Reasoning backend: `anthropic` or `openai`. |
| `ANTHROPIC_API_KEY` | — | Required when `AI_PROVIDER=anthropic`. |
| `OPENAI_API_KEY` | — | Required when `AI_PROVIDER=openai`. |
| `START_BLOCK_LOOKBACK` | `5000` | Cold-start scan depth, in blocks. |
| `ESCROW_ADDRESS` | — | The deployed proxy. |
| `PRIVATE_KEY` | — | The ARBITER's signing key — never the deployer's. Never logged. |

The last two are the agent's own generic names, which predate the unified
`DEMO_*` roles. `scripts/run-arbiter.sh` is the one place that mapping lives
(`DEMO_ARBITER_PK` → `PRIVATE_KEY`, `DEMO_ESCROW_ADDRESS` → `ESCROW_ADDRESS`), so
no operator has to remember which key `PRIVATE_KEY` means here. It also honours
`ARBITER_RPC_URL`, because the agent needs a node at the head of the chain that
will serve `eth_getLogs` over the lookback window — not every free endpoint does.

The backend is pluggable because the prompt and the `{ruling, rationale}`
contract are identical either way — only the request envelope differs, so a
ruling does not depend on the vendor. **Only the selected provider's key is
required**: an operator on OpenAI is never asked for an Anthropic key, and the
agent refuses to start if the one it needs is missing, rather than discovering
it on the first dispute. Escrows #2 and #3 above were settled through the OpenAI
backend while Anthropic billing was blocked.

`START_BLOCK_LOOKBACK` matters more than it looks: at Base Sepolia's ~2s blocks
the 5000-block default is only about three hours, and a dispute older than that
is invisible to a fresh agent — see
[Lessons from a live testnet](#lessons-from-a-live-testnet). Raise it when
catching up on a backlog.

---

## Cast one-liners

Set up first:

```bash
set -a; source ../.env; set +a
export ESCROW="$DEMO_ESCROW_ADDRESS"
export RPC="${DEMO_RPC_URL:-https://sepolia.base.org}"

# The three parties. They MUST be three distinct addresses — createEscrow
# reverts with DuplicateParty otherwise.
export BUYER_KEY="$DEMO_INVESTOR_A_PK"
export SELLER_KEY="$DEMO_INVESTOR_B_PK"
export ARBITER_KEY="$DEMO_ARBITER_PK"
export SELLER="$DEMO_INVESTOR_B_ADDR"
export ARBITER="$DEMO_ARBITER_ADDR"
```

```bash
# Derive a commitment from a delivery secret (the secret stays local)
node scripts/poseidon.js 12345 0

# Create an escrow (caller becomes the buyer; the three parties must differ)
cast send $ESCROW "createEscrow(address,address,uint256,uint256)" \
    $SELLER $ARBITER 1000000000000000 $COMMITMENT \
    --rpc-url $RPC --chain-id 84532 --private-key $BUYER_KEY

# Fund it (buyer only, exact amount)
cast send $ESCROW "fund(uint256)" 0 --value 1000000000000000 \
    --rpc-url $RPC --chain-id 84532 --private-key $BUYER_KEY

# Generate a proof, then release with it (anyone may send this)
./scripts/prove.sh 12345 0
cast send $ESCROW "release(uint256,uint256,uint256[2],uint256[2][2],uint256[2])" \
    0 $NULLIFIER $PA $PB $PC \
    --rpc-url $RPC --chain-id 84532 --private-key $BUYER_KEY

# Seller returns the money without a dispute
cast send $ESCROW "refund(uint256)" 0 \
    --rpc-url $RPC --chain-id 84532 --private-key $SELLER_KEY

# Escalate, and add evidence afterwards
cast send $ESCROW "raiseDispute(uint256,string)" 0 "nothing arrived" \
    --rpc-url $RPC --chain-id 84532 --private-key $BUYER_KEY
cast send $ESCROW "submitEvidence(uint256,string)" 0 "signed POD attached" \
    --rpc-url $RPC --chain-id 84532 --private-key $SELLER_KEY

# Arbiter rules. 0 = BuyerWins, 1 = SellerWins.
# ONLY the escrow's named arbiter may send this — no other key can.
cast send $ESCROW "resolveDispute(uint256,uint8,string)" 0 1 "tracking confirms delivery" \
    --rpc-url $RPC --chain-id 84532 --private-key $ARBITER_KEY

# Pull your money out (whichever side the settlement credited)
cast send $ESCROW "withdraw()" \
    --rpc-url $RPC --chain-id 84532 --private-key $SELLER_KEY

# Reads
cast call $ESCROW "getState(uint256)(uint8)" 0 --rpc-url $RPC
# 0 None · 1 Created · 2 Funded · 3 Released · 4 Refunded · 5 Disputed · 6 Resolved
cast call $ESCROW "pendingWithdrawals(address)(uint256)" $SELLER --rpc-url $RPC
cast call $ESCROW "nullifierUsed(uint256)(bool)" $NULLIFIER --rpc-url $RPC
cast logs --address $ESCROW \
    "DisputeResolved(uint256,address,uint8,address,uint256,string)" --rpc-url $RPC
```

> **On `--private-key`.** `cast` only accepts signing keys as command-line
> arguments — it will not read them from the environment. The demo scripts
> therefore build the *echoed* form of every command separately from the
> executed one and substitute `***REDACTED***`, so no key is ever printed. The
> real value still appears in the process's argv, which is visible to other
> local users via `ps`. On a shared machine, use a key you are willing to treat
> as public. See [Trust model](#trust-model).

---

## Building the circuit

Requires Node 20+, [circom 2.1.9+](https://docs.circom.io/getting-started/installation/)
and the pinned npm dependencies.

```bash
npm install                  # circomlib 2.0.5, circomlibjs 0.1.7, snarkjs 0.7.5
./scripts/build-circuit.sh   # compile + trusted setup + export src/Verifier.sol
./scripts/prove.sh 12345 0   # generate a proof for secret=12345, escrow #0
```

`build-circuit.sh` writes `src/Verifier.sol` (checked in) and proving artifacts
into `circuits/build/` (gitignored). Only the `.circom` source, the scripts and
the generated verifier are tracked.

> Re-running `build-circuit.sh` performs a *fresh* setup, so the verification
> key — and with it `src/Verifier.sol` — changes. The checked-in fixture proofs
> were generated against the previous key and must be regenerated alongside it;
> the script header gives the two commands. `forge test` fails loudly if you
> forget, so this cannot slip through silently.

The circuit is 932 R1CS constraints — one private input (`secret`), two public
inputs (`commitment`, `escrowId`) and one public output (`nullifier`).

> ### ⚠ The trusted setup is demo-grade
>
> `build-circuit.sh` generates the powers-of-tau **and** the phase-2
> contribution locally, on one machine, with entropy the script supplies itself.
> Whoever runs it knows the toxic waste and could forge proofs for this circuit
> at will. That is acceptable for a Base Sepolia demo and unacceptable for real
> value. Production needs a multi-party ceremony — a Perpetual Powers of Tau
> file plus independent phase-2 contributors — where no single participant sees
> all the randomness.

### npm advisories

`package.json` carries `overrides` pinning `ws`, `underscore` and `elliptic`
forward past their advisories, because the direct dependencies (`snarkjs`,
`circomlibjs`) have no releases that do it themselves. That clears every high
and moderate finding.

What remains is 15 low-severity findings, all one root cause: `elliptic@6.6.1`
is the newest published version and its advisory has no fix. It reaches the
tree through `circomlibjs → ethers@5`, and nothing here signs with it — the
only thing this project uses `circomlibjs` for is computing Poseidon hashes.
It is not in the trust path for proofs or for any key.

### Why the nullifier is derived from the escrow id

`commitment = Poseidon(secret)` and `nullifier = Poseidon(secret, escrowId)`.
Binding the nullifier to the escrow is what makes replay *unprovable* rather
than merely rejected: the same secret yields a different nullifier per escrow,
and the contract stores spent nullifiers, so one proof settles exactly one
escrow exactly once. `test_Release_RejectsProofFromAnotherEscrow` pins this with
two real checked-in proofs that share a commitment and differ in nullifier.

---

## Testing

Verified by the
[**PIGFOX SOLIDITY PIPELINE v1**](https://github.com/pigfox/solidity-pipeline) —
the estate's single definition of green. Most of it came *from* this repo: the
forced rebuild before fuzzing, the property-count assertion, the coverage gate
that refuses to pass on a report it cannot parse, and the doctrine gate that
plants a token to prove it still matches were all written here, then factored out
so the other three demo repos get them too and a fix lands once instead of four
times.

The pipeline is vendored as a submodule at `lib/solidity-pipeline`, so the gates
that run in CI are the same bytes you run locally:

```bash
git submodule update --init --recursive   # brings in lib/solidity-pipeline
forge test                  # 105 tests: unit, fuzz, invariants
lib/solidity-pipeline/scripts/coverage.sh          # fails below 100% on src/
lib/solidity-pipeline/scripts/no-chain-copy-gate.sh all
echidna . --contract Properties --config echidna.yaml       # 6/6, 100k calls
medusa fuzz --config medusa.json                            # 6/6, 100k calls
slither . --ignore-compile --fail-low \
  --config-file lib/solidity-pipeline/slither.config.json   # 0 findings
cd agent && go test ./... -race -coverprofile=coverage.out
```

### One property contract, three engines

`test/Properties.sol` is the single source of truth for the invariants, consumed
by **Foundry**, **Echidna** and **Medusa** alike, so a property cannot hold in
one engine and silently rot in another. Six properties:

- **(a)** the contract's ETH balance always equals the sum of its obligations —
  amounts credited to payees *plus* amounts still locked against `Funded` or
  `Disputed` escrows. Both halves are recomputed independently of the contract's
  own bookkeeping, so a bug in `totalPendingWithdrawals` cannot hide behind
  itself.
- **(b)** no settlement ever credits the arbiter *of the escrow it settles*.
  This is a flow-level check, not an address-level one: each wrapper snapshots
  that escrow's arbiter around the call and flags an increase. An address may
  legitimately hold credits it earned as the buyer or seller of some *other*
  escrow, which is exactly the state the rotating actor pool produces, so
  "this address holds zero" would be the wrong question to ask.
- **(c)** every escrow only ever moves along an edge of the declared state
  machine.
- **(d)** obligations never exceed the total ever funded — nothing can be owed
  that was never paid in.
- **(e)** a nullifier settles at most one escrow, ever. Nullifiers are bounded
  into a pool of eight so that collisions actually *occur* inside a fuzz
  sequence; with a raw `uint256` the fuzzer never collided, so the replay guard
  was never exercised and this property passed vacuously while looking green.
- **(f)** the progress ledger is consistent: every ghost success counter is
  dominated by an opportunity registered in the same call frame. Without this,
  the canary below can silently start asserting luck instead of behaviour.

The harness drives every party as a real `Actor` contract rather than a
cheatcode prank, because Echidna and Medusa have no `prank` — without that, the
fuzzers would bounce off `resolveDispute`'s access-control guard forever and
never reach `Resolved`. It rotates a pool of six actors, deriving three distinct
roles per escrow from the fuzz input, so one address can be the seller of one
escrow and the buyer or arbiter of another. A fixed party triple can never
produce the case where an address is owed money from two escrows in two
different capacities. `test/PropertiesHarness.t.sol` exists to prove the harness
is not vacuous: it walks every terminal state deterministically, so a green fuzz
run means something.

### The harness audits itself

A property suite that never reaches an interesting state reports green forever,
which is indistinguishable from a correct protocol. So `afterInvariant` asserts
the run was not inert — but as *implications*, not raw counts: each opportunity
counter tallies only calls whose preconditions were all satisfied, and the
assertion is that anything which should have succeeded did. Raw counts flake,
because `afterInvariant` fires after every run of every invariant — roughly 1500
samples per `forge test` — and a sequence that draws no `fund` selector in 64
picks is unlucky, not broken. That canary then caught a real defect in itself:
`fund` picked uniformly over every escrow ever created, so its hit rate decayed
as a sequence ran and whole runs were starved of any funded escrow. `fund` now
splits on its seed — three quarters scan forward for a `Created` escrow, one
quarter keeps the uniform pick so the state guard still gets probed with
wrong-state calls, which are counted separately rather than diluting the
conversion rate the canary measures.

### What CI enforces about the fuzzers

Three guards, each closing a way a fuzz suite can fail by looking green.

`fail_on_revert = true`. Every harness entry point swallows its expected
reverts by design, so a revert reaching the engine is a harness bug rather than
a protocol finding — and left unchecked it silently shrinks the search space.

`EXPECTED_PROPERTIES`. Both fuzz jobs assert the run registered exactly that
many properties. A predicate that stops being picked up — a rename, a bad
build — otherwise reports as a smaller green run, not an error.

A forced rebuild before each fuzzer. `forge coverage` overwrites `out/` with
coverage-instrumented artifacts, and crytic-compile consumes those, or a stale
`crytic-export/`, without complaint — registering a property set that does not
match the source. That once cut the suite to four of five properties silently.
Each fuzz job now deletes `crytic-export/` and runs `forge build --force`
immediately beforehand, unconditionally, so a future job reorder cannot bring
it back.

### Coverage

| Target | Lines | Statements | Branches | Functions |
| --- | --- | --- | --- | --- |
| `src/EscrowUpgradeable.sol` | **100%** (92/92) | **100%** (116/116) | **100%** (20/20) | **100%** (16/16) |
| `src/Verifier.sol` *(excluded — see below)* | 93.65% | 93.22% | 33.33% | 100% |
| Go agent (all packages) | — | **100.0%** | — | — |

Both gates are hard failures in CI, not reports.

#### The one documented exclusion: `src/Verifier.sol`

`lib/solidity-pipeline/scripts/coverage.sh` requires 100% on all four metrics for
every file under `src/`, with exactly one exclusion — named on the command line
and printed as `SKIP` on every run, never folded into a percentage. The gate also
fails if that name ever stops matching a real file, so the exclusion cannot rot
into a hole that reads as a decision. `Verifier.sol` is generated verbatim by
snarkjs from the proving key. Its residual uncovered lines are the
inline-assembly early-exit paths taken when the BN254 `ecAdd` / `ecMul` /
pairing **precompiles themselves** report failure. Those cannot be provoked from
a test: inputs that are merely wrong — off-curve points, out-of-range field
elements — are rejected by the reachable `checkField` branch, which *is* covered
by `test_Verifier_RejectsOutOfRangeNullifier` and friends. Reaching the rest
would require a broken EVM, not a broken proof.

The verifier is not untested for it. `test/ZkRelease.t.sol` drives real Groth16
proofs through the escrow end to end, including tampered public signals,
off-curve points, zero proofs, wrong commitments and cross-escrow replay.

Analyzer exclusions are documented the same way. The reasoning now lives once, in
the pipeline's
[shared exclusions document](https://github.com/pigfox/solidity-pipeline/blob/main/docs/slither-exclusions.md);
[`docs/slither-exclusions.md`](docs/slither-exclusions.md) records where each one
fires *in this repo* — seven detectors, six of which fire only on the generated
verifier. CI fails on any finding that survives them.

---

## Lessons from a live testnet

Everything below was found by running against Base Sepolia, not by testing.
Each one passed unit tests, CI, both fuzzers and Slither first.

**snarkjs and cast disagree about arrays.** snarkjs exports proof points as
quoted, comma-space JSON (`["0xab", "0xcd"]`); `cast` array literals are bare
and unspaced (`[0xab,0xcd]`) and it rejects the other form outright. Act I died
at the release step on the first run. `prove.sh` now emits both encodings —
`pA`/`pB`/`pC` for the Solidity fixtures, `castPA`/`castPB`/`castPC` for
anything shelling out.

**Published test keys are actively swept, and the failure is misdirected.** The
demos originally used the standard Anvil accounts for the throwaway
seller/buyer. Their private keys ship with every Foundry install, so on a public
testnet they are drained continuously — Base Sepolia's Anvil #4 sits at nonce
229 and carries an **EIP-7702 delegation** (`0xef0100…`) to a sweeper contract.
Funding it does not fail; the transfer succeeds and is forwarded away
atomically in the same transaction, leaving the account at zero. The symptom
surfaces three steps later as `gas required exceeds allowance (0)`, which points
at entirely the wrong thing. The demos now generate real random identities on
first run and cache them in a gitignored, `0600` `.demo-keys.env`, and
`fund_to()` re-reads the balance after transferring rather than trusting the
receipt.

**Redaction as a list of names silently rots.** `run()` masked `PRIVATE_KEY` and
`SELLER_KEY` before echoing each `cast` command — but a later edit introduced
`SELLER2_KEY`, which printed in clear. It happened to be a published key, so
nothing secret leaked, but the same logic would have leaked an operator's. The
enumerated list is now a registry: keys are registered as they are obtained and
`run()` masks anything in it, so adding a key cannot quietly bypass redaction.

**100% statement coverage did not catch a ten-block miss.** The agent begins
scanning `StartBlockLookback` blocks behind head, and 5000 blocks is about three
hours of Base Sepolia. By the time the disputes were settled they had aged past
that: a fresh agent started at block 44347290 while escrow #3's dispute sat at
44347280 — **ten blocks out of reach** — and reported nothing at all rather than
an error. `START_BLOCK_LOOKBACK` now overrides the window. The regression test
asserts the override *moves the first scanned block*, not merely that the branch
executes; branch-execution coverage was already 100% and would have missed this
exactly as it did the first time.

The through-line: the contract logic was fine every time. What broke was
everything around it — encodings, key hygiene, operational windows — which is
the part a test suite is worst at reaching.

## Trust model

The interesting question is not "is the AI right?" but "what happens when it is
wrong?" The contract is designed so that the answer is bounded.

**The arbiter is a trusted oracle, and only that.** It decides *who wins*, never
*where the money goes*. `resolveDispute(escrowId, ruling, rationale)` takes a
`Ruling` enum — `BuyerWins` or `SellerWins` — and derives the beneficiary from
that escrow's own stored parties. There is no parameter, and no branch, that
lets funds reach the arbiter or a third address. `createEscrow` additionally
rejects an arbiter equal to either party. Invariant (b) is fuzzed against this
by all three engines.

**The agent's key is gas-dust-only and testnet-only.** It signs one kind of
transaction on Base Sepolia. Its worst case, fully compromised, is: rule wrongly
on disputes it is the named arbiter for, sending the escrowed amount to *the
other party in that trade*. It cannot drain the contract, cannot touch escrows
where it is not the arbiter, cannot upgrade anything (that is `owner`, a
separate role — `test_ResolveDispute_RevertsForOwnerWhoIsNotArbiter` pins the
separation), and cannot pay itself. Fund it with dust; treat the key as public.

**The owner can rotate a disputed escrow's arbiter (V2).** `setArbiter`, added in
`EscrowUpgradeableV2`, lets `owner` reassign the arbiter of a `Disputed` escrow.
It is a governance power, and an honest one to name — but a strictly *smaller* one
than the owner already held: the owner has UUPS upgrade authority, so it could
swap the entire implementation to do anything regardless; a scoped `setArbiter` is
an auditable slice of that same power. It exists as a recovery tool, and was used
for exactly that (see [Recovery](#recovery-the-v2-arbiter-rotation)): the original
run assigned several disputes a keyless arbiter address that could never settle
them, and rotation to a keyed arbiter is the fix. The fund-safety invariant is
preserved — `setArbiter` rejects a new arbiter equal to the buyer or seller, so a
rotated arbiter still cannot be the beneficiary of its own ruling, exactly as
`createEscrow` guarantees. It is `Disputed`-only (never a mid-trade party swap),
touches no balance, and emits `ArbiterRotated`. Its full branch set is unit-tested
and two invariants are fuzzed: a rotation never moves funds, and only the owner can
ever rotate. What it does *not* defend against is a malicious owner rotating to an
arbiter it controls and then ruling — but that owner could already upgrade the
contract to drain everything, so `setArbiter` grants no power it lacked.

**What is genuinely trusted:** that Claude's ruling is a fair reading of the
evidence, and that the evidence on chain is the real evidence. Neither is
enforced by anything. The model sees only what the parties published in
`DisputeRaised` events, and a party can lie there as easily as anywhere else.

### Hardening paths (future work)

None of these are implemented — this is a demo, and saying so is more useful
than implying otherwise.

- **Multi-model quorum.** Route each dispute to several independent models and
  require agreement before executing. Turns a single hallucination from a wrong
  ruling into a no-op.
- **Challenge window.** Have `resolveDispute` stage a ruling rather than settle
  it, with a fixed delay in which the losing party can escalate to a human or a
  bonded challenger. Makes a wrong ruling recoverable rather than final.
- **TEE attestation.** Run the agent in an enclave and post an attestation
  alongside the ruling, so observers can verify *which* model saw *which*
  evidence. Closes the gap where the operator, not the model, chooses the
  outcome.
- **Evidence commitments.** Require parties to commit to evidence before the
  dispute opens, so neither side can tailor its story to the other's.
- **Bonded disputes.** Make raising a dispute cost something refundable on a
  win, to price out frivolous escalation.

---

## Deployment reference

**Everything in this section is the live deployment.** The retired v1 estate has
its own addresses, its own verification recipe and its own deploy transactions,
all of them under [v1 deployment (retired)](#v1-deployment-retired-2026-07-26) —
nothing here links to it.

The three live addresses are at the [top of this README](#live-on-base-sepolia).
Deployed 2026-07-26 to chain id 84532; the upgrade authority is
[`0xb6c3a56C…`](https://sepolia.basescan.org/address/0xb6c3a56CA2f99e3F5d7d16ad968df9f71cCC184D).

```bash
export DEMO_ESCROW_ADDRESS=0x4421E53D0dd051159d1a0F03d45554313e3e9774
```

All three are verified on BaseScan against solc `v0.8.28+commit.7893614a` with
the optimizer on at 200 runs — the same settings `foundry.toml` pins, so the
published source matches what the tests and fuzzers ran against.

<details>
<summary>Reproducing the verification — live addresses</summary>

**`--verifier etherscan` is not optional.** This repo's `.env` does not define
`ETHERSCAN_API_KEY`, and without one `forge verify-contract` does not fail — it
silently falls back to **Sourcify** and reports `Contract successfully verified`.
Sourcify is not Basescan, and a contract verified only there still shows as
unverified on the explorer every link in this README points at. That happened in
PF-S124 and was caught only by reading the output. Pass the flag, and pass a key
from a repo that has one until this repo's `.env` gains its own.

```bash
set -a; source ../.env; set +a

forge verify-contract 0x20B98B460c1252974177215EaDa7A61259Ad5825 \
    src/Verifier.sol:Groth16Verifier \
    --chain-id 84532 --etherscan-api-key "$ETHERSCAN_API_KEY" --verifier etherscan --watch

# The LIVE implementation. Superseded implementations stay verified on their own
# addresses; re-verifying one is never necessary.
forge verify-contract 0x22c90633D3537B3F4555541F23b4A243F6a91b8A \
    src/EscrowUpgradeable.sol:EscrowUpgradeable \
    --chain-id 84532 --etherscan-api-key "$ETHERSCAN_API_KEY" --verifier etherscan --watch

# The proxy's constructor arguments are a HISTORICAL FACT, fixed when it was
# deployed, so the implementation named here is the ORIGINAL one and must stay
# that way even after an upgrade. Substituting the current implementation would
# make verification fail, because it would no longer match the deploy calldata.
forge verify-contract 0x4421E53D0dd051159d1a0F03d45554313e3e9774 \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --chain-id 84532 --etherscan-api-key "$ETHERSCAN_API_KEY" --verifier etherscan --watch \
    --constructor-args "$(cast abi-encode 'constructor(address,bytes)' \
        0x36dDB82CCE0AE251d68369C794070a09021D6825 \
        "$(cast calldata 'initialize(address,address)' \
            0x20B98B460c1252974177215EaDa7A61259Ad5825 \
            0xb6c3a56CA2f99e3F5d7d16ad968df9f71cCC184D)")"
```

The proxy's constructor args encode the implementation address plus the
`initialize(verifier, owner)` calldata; they match the arguments recorded in
`broadcast/Deploy.s.sol/84532/run-latest.json` byte for byte.

</details>

> **One manual step remains on the live proxy.** BaseScan holds its source
> (verified as `ERC1967Proxy`) but has not been told it *is* a proxy, so it does
> not expose Read/Write-as-Proxy or link through to the implementation's ABI.
> That detection is a UI action and cannot be scripted: open the
> [live proxy](https://sepolia.basescan.org/address/0x4421E53D0dd051159d1a0F03d45554313e3e9774#code)
> → **Contract** → **More Options** → **Is this a proxy?** → **Verify**. Until
> then, interact via `cast` (every one-liner above works regardless) or through
> the implementation's ABI.

### Deployment transactions — live

| Contract | Tx |
| --- | --- |
| `Groth16Verifier` | [`0x6fa38df4…`](https://sepolia.basescan.org/tx/0x6fa38df477974570ecc788175a03b998db47ced4cba371e92dfdbbf383105657) |
| `EscrowUpgradeable` | [`0x1e69bc3f…`](https://sepolia.basescan.org/tx/0x1e69bc3f5cd58b14936198ff913c7a362b08c9b417ef7acbeec415665c8ca379) |
| `ERC1967Proxy` | [`0xab7806cc…`](https://sepolia.basescan.org/tx/0xab7806cc9833cb1bdab8f3de0ae75b0feaa6897738ace43552887c04f9f62eea) |

All three landed in block 44641562 and succeeded (receipt status `0x1`), for a
total of 0.000013600968 ETH in gas. Post-deploy state was checked on chain, and
re-checked when this section was written: `verifier()` returns
`0x20B98B46…`, `owner()` returns `0xb6c3a56C…`, and the ERC-1967 implementation
slot holds `0x36dDB82C…`. `initialize()` reverts on a second call.

---

## Setup

Secrets live in `../.env` — **one directory above this repository**, so they
cannot be committed. Nothing in the build, test or CI path reads them; they are
needed only to deploy and to run the agent.

```bash
cp .env.example ../.env
$EDITOR ../.env          # the DEMO_* role keys, ANTHROPIC_API_KEY or OPENAI_API_KEY
set -a; source ../.env; set +a
```

| Variable | Needed for |
| --- | --- |
| `DEMO_DEPLOYER_PK` / `_ADDR` | deploy |
| `DEMO_OPERATOR_PK` | demos — the treasury that tops the other roles up |
| `DEMO_INVESTOR_A_PK` | demos — the escrow's buyer |
| `DEMO_INVESTOR_B_PK` | demos — the escrow's seller |
| `DEMO_ARBITER_PK` / `_ADDR` | the agent — the only key that may settle a dispute |
| `ANTHROPIC_API_KEY` | agent only, when `AI_PROVIDER` is `anthropic` (the default) |
| `OPENAI_API_KEY` | agent only, when `AI_PROVIDER=openai` |
| `AI_PROVIDER` | optional — `anthropic` (default) or `openai` |
| `START_BLOCK_LOOKBACK` | optional — cold-start scan depth in blocks (default 5000, ~3h) |
| `DEMO_ESCROW_ADDRESS` | demos, agent (after deploy) |
| `DEMO_RPC_URL` | optional — where our clients talk, if not `sepolia.base.org` |
| `ETHERSCAN_API_KEY` | optional — BaseScan verification |

Then:

```bash
forge build
npm install && ./scripts/build-circuit.sh
./scripts/deploy.sh      # Base Sepolia only; chain id 84532 is asserted twice
```

`deploy.sh` exits cleanly with instructions if the credentials are not populated
yet — missing operator credentials are not a build failure.

---

## Layout

```
src/EscrowUpgradeable.sol   UUPS escrow: state machine, pull payments, ZK release
src/Verifier.sol            generated Groth16 verifier (do not edit by hand)
src/IVerifier.sol           the interface the escrow depends on
circuits/delivery.circom    the delivery-secret circuit
scripts/                    build-circuit, prove, deploy, coverage, the two demos
script/Deploy.s.sol         forge deployment script (asserts chain 84532)
test/Properties.sol         shared invariants: Foundry + Echidna + Medusa
test/fixtures/              real Groth16 proofs, generated once and checked in
agent/                      the Go AI arbiter (100% covered)
docs/slither-exclusions.md  every suppressed detector, with rationale
```

## Licence

MIT, except `src/Verifier.sol`, which snarkjs emits under GPL-3.0.

## v1 deployment (retired 2026-07-26)

> **Retired. Do not interact with anything in this section.** These contracts are
> still on chain and still hold their history, which is why they are documented
> here, but nothing reads them any more and no demo points at them. The live
> addresses are at the [top of this file](#live-on-base-sepolia).

The contracts below were the demo's first life — including the nine disputed
escrows recovered in the UUPS upgrade described above, whose settlements and
rationales remain readable there.

| Contract | v1 address (retired) |
| --- | --- |
| Escrow proxy | [`0x8bB2ae77AcE1424a9418f32bb2b2077563eE8A84` (retired)](https://sepolia.basescan.org/address/0x8bB2ae77AcE1424a9418f32bb2b2077563eE8A84) |
| V1 implementation | [`0x5c3F41Dce28aFA54F9656377aFbF360Cc9310Fb4` (retired)](https://sepolia.basescan.org/address/0x5c3F41Dce28aFA54F9656377aFbF360Cc9310Fb4) |
| V2 implementation | [`0x1cB2207f11baE16d194a9C187a9bE1F0b38a1637` (retired)](https://sepolia.basescan.org/address/0x1cB2207f11baE16d194a9C187a9bE1F0b38a1637) |
| Verifier | [`0xE6372Ff3083B9fea441204BF5617a5afF02e2D56` (retired)](https://sepolia.basescan.org/address/0xE6372Ff3083B9fea441204BF5617a5afF02e2D56) |
| Owner (current, read from chain) | `0x957a8D5FaEbb5D2179ff2Bc79d114AAFBe714931` — **still owns this proxy and retains UUPS upgrade authority over it** |
| Owner at `initialize` | `0x49FE3B2731090b93d297D259BD1eFFC5DB015edF` — later transferred; it is the value in the v1 constructor args below, and it holds **no privilege anywhere today** |
| Arbiter on the nine rotated escrows | `0x6BBc782624B3c604e32Ed8b8C00d273970F67d0C` — a per-escrow field, never a global role; keyless |

Read back from chain: the proxy's ERC-1967 implementation slot holds the V2
implementation `0x1cB2207f…`, and `owner()` returns `0x957a8D5F…`.

### v1 deployment transactions (retired)

| Contract | Tx |
| --- | --- |
| `Groth16Verifier` | [`0x1381d46a…` (retired)](https://sepolia.basescan.org/tx/0x1381d46ab23cab5d5bd45d89189987bd9c3194630bc983d91486e6c3f55ad015) |
| `EscrowUpgradeable` | [`0xbc5456e6…` (retired)](https://sepolia.basescan.org/tx/0xbc5456e64bc7a6780b0abc57f185105a9c0a760a6b8ea4f6498b1880e684bc03) |
| `ERC1967Proxy` | [`0xb4d8bcb6…` (retired)](https://sepolia.basescan.org/tx/0xb4d8bcb62bc1a6998d274a3816b28985ef75b6cb0d27fc9678635c02346169cd) — block 44339701, whose `OwnershipTransferred(0x0 → …)` log is the chain source for "Owner at `initialize`" above |

All three succeeded (receipt status `0x1`), for a total of 0.0000139929 ETH in gas.

<details>
<summary>How the v1 contracts were verified (retired — kept as the record)</summary>

The v1 deploy ran without an `ETHERSCAN_API_KEY`, so verification was done after
the fact:

```bash
set -a; source ../.env; set +a

forge verify-contract 0xE6372Ff3083B9fea441204BF5617a5afF02e2D56 \
    src/Verifier.sol:Groth16Verifier \
    --chain-id 84532 --etherscan-api-key "$ETHERSCAN_API_KEY" --watch

forge verify-contract 0x5c3F41Dce28aFA54F9656377aFbF360Cc9310Fb4 \
    src/EscrowUpgradeable.sol:EscrowUpgradeable \
    --chain-id 84532 --etherscan-api-key "$ETHERSCAN_API_KEY" --watch

forge verify-contract 0x8bB2ae77AcE1424a9418f32bb2b2077563eE8A84 \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --chain-id 84532 --etherscan-api-key "$ETHERSCAN_API_KEY" --watch \
    --constructor-args "$(cast abi-encode 'constructor(address,bytes)' \
        0x5c3F41Dce28aFA54F9656377aFbF360Cc9310Fb4 \
        "$(cast calldata 'initialize(address,address)' \
            0xE6372Ff3083B9fea441204BF5617a5afF02e2D56 \
            0x49FE3B2731090b93d297D259BD1eFFC5DB015edF)")"
```

</details>

The rebirth replaced every key and redeployed from scratch; see
`pigfox2-repos/KEYS.md` for the role table and the full retired list.

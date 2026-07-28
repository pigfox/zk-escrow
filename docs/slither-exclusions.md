# Slither detector exclusions

**The rationale is no longer kept here.** Since this repo adopted the
[PIGFOX SOLIDITY PIPELINE v1](https://github.com/pigfox/solidity-pipeline) there
is exactly one Slither configuration in the estate, and every detector it
excludes is justified in one place:

→ **[lib/solidity-pipeline/docs/slither-exclusions.md](../lib/solidity-pipeline/docs/slither-exclusions.md)**

CI still fails on **any** remaining finding of low severity or above
(`"fail_on": "low"`), and a full run over `src/` still reports **zero results**.

## What the shared list means here

Seven of the excluded detectors were already excluded by this repo, and six of
those fire only on `src/Verifier.sol`, which `snarkjs` generates verbatim from
the proving key — editing it would be undone by the next
`./scripts/build-circuit.sh` run. This table records **where** each one fires in
this repo; the shared document records **why** each is off.

| Detector | Where it fires here |
| --- | --- |
| `naming-convention` | `src/Verifier.sol` (`alphax`, `IC0y`, `pVk`, `_pA`, …) and `EscrowUpgradeable.__gap` |
| `too-many-digits` | `src/Verifier.sol` — the 76-digit literals *are* the verification key |
| `solc-version` | all files; the pragma is pinned to exactly `0.8.28` |
| `assembly` | `src/Verifier.sol` — the pairing check is inline assembly by construction |
| `incorrect-return-in-assembly` | `src/Verifier.sol` — the `return(0, 0x20)` early-exit path for an invalid proof |
| `missing-inheritance` | `Groth16Verifier` vs `IVerifier`; an `is IVerifier` clause cannot be added to generated output, and `EscrowUpgradeable` holds the verifier as an `IVerifier` regardless |
| `low-level-calls` | `EscrowUpgradeable.withdraw()` — `call{value:}` is the correct way to pay an unknown recipient; `transfer`'s 2300-gas stipend breaks contract payees |

## The three the shared list adds

Adopting the estate-wide config switched off three detectors this repo had left
on: `reentrancy-events`, `timestamp` and `incorrect-equality`. They were needed
by the gas and RWA repos, and their reasoning is in the shared document —
`incorrect-equality` is Medium, and that entry states plainly what is given up.

**They mask nothing here, and that was checked rather than assumed.** A full
Slither run over this tree reports `0 result(s) found` under both configurations
— 93 detectors with the old local config, 90 with the shared one. Adopting the
shared list did not turn a finding off in this repo; it turned three detectors
off that had nothing to say about it.

## Findings that were fixed rather than excluded

`withdraw()` is CEI-ordered and `nonReentrant`, the `call` result is checked, and
a `false` reverts with `TransferFailed`.
`test_Withdraw_RevertsWhenRecipientRejectsEth` and
`test_Withdraw_ReentrancyIsBlocked` cover both failure modes, and
`echidna_balance_equals_obligations` is the standing invariant over the payout
path: the contract's ETH balance always equals what it still owes, with both
halves recomputed independently of the contract's own bookkeeping.

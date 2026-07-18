# Slither detector exclusions

`slither.config.json` cannot carry comments, so the rationale for every excluded
detector lives here. CI fails on **any** remaining finding of low severity or
above (`"fail_on": "low"`), so this list is the complete set of things we have
decided not to act on — nothing else is being suppressed.

Seven detectors are excluded. Six of them fire only on `src/Verifier.sol`, which
`snarkjs` generates verbatim from the proving key; editing it would be undone by
the next `./scripts/build-circuit.sh` run.

| Detector | Where it fires | Why it is excluded |
| --- | --- | --- |
| `naming-convention` | `src/Verifier.sol` (`alphax`, `IC0y`, `pVk`, `_pA`, …) and `EscrowUpgradeable.__gap` | The verifier's constant names are fixed by the Groth16 verifier format. `__gap` is the OpenZeppelin convention for storage reservation. Style, not security. |
| `too-many-digits` | `src/Verifier.sol` | The 76-digit literals *are* the verification key — BN254 field elements. There is no shorter correct spelling. |
| `solc-version` | all | The pragma is pinned to exactly `0.8.28` in `foundry.toml` and in the generated file's rewritten header. The detector's concern is floating pragmas, which we do not have. |
| `assembly` | `src/Verifier.sol` | The pairing check is inline assembly by construction; that is how every snarkjs verifier is emitted. |
| `incorrect-return-in-assembly` | `src/Verifier.sol` | A false positive on generated code. The `return(0, 0x20)` calls are the verifier's deliberate early-exit path for an invalid proof — returning `false` to the caller, not corrupting a Solidity return. |
| `missing-inheritance` | `Groth16Verifier` vs `IVerifier` | Slither notices the shapes match and suggests inheritance. We cannot add an `is IVerifier` clause to generated output, and we do not need to: `EscrowUpgradeable` holds the verifier as an `IVerifier` and the ABI is identical. `test/ZkRelease.t.sol` pins this by calling the real verifier through the escrow. |
| `low-level-calls` | `EscrowUpgradeable.withdraw()` | `(bool ok,) = payable(msg.sender).call{value: amount}("")` is the correct way to pay out an unknown recipient — `transfer`'s 2300-gas stipend breaks smart-contract payees. The call is the last step of a CEI-ordered, `nonReentrant` function, its result is checked, and a `false` reverts with `TransferFailed`. `test_Withdraw_RevertsWhenRecipientRejectsEth` and `test_Withdraw_ReentrancyIsBlocked` cover both failure modes. |

Everything else — reentrancy, arbitrary-send, uninitialized state, unchecked
transfers, shadowing, and the rest of Slither's medium and high severity
detectors — remains enabled.

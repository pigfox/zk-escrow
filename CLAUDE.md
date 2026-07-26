# zk-escrow — agent instructions

An upgradeable (UUPS) escrow on Base Sepolia where funds are released against a
Groth16 zero-knowledge proof of a delivery secret, with an AI arbiter for
disputes. Solidity + circom + a Go agent. The public demo that reads this
contract lives in the `pigfox2` repo at `/demos/zk-escrow`.

## Session tag (BINDING)
- First line of every response: the bare current tag from `.session-tag` (or UNTAGGED).
- Tag format `^(PF|MV|ZK)-S[0-9]+[a-z]?$`; this repo uses the `ZK` prefix. Rotate ONLY at
  session open: bump N (or same-day sub-letter), write `.session-tag`, INSERT a ledger
  session-open row with the tag in the payload. Never reuse/decrement. Never rotate mid-session.
- Every ledger INSERT includes the tag in its payload. Session-open: reconcile the ledger's
  latest tag against `.session-tag`; a mismatch is a stop.
- Work that spans this repo and `pigfox2` carries BOTH tags in the ledger row.
- Web-Claude directive blocks open with a tag guard line; if a pasted directive's tag
  mismatches `.session-tag` it exits 1 — re-request, don't force.
- `.session-tag` is gitignored: it is working-copy state, never committed.

## DIRECT-CHAIN DOCTRINE (absolute)
- Every test, script and CI job either runs in a pure in-process EVM it builds itself,
  or talks to Base Sepolia (84532) directly. Nothing may point the EVM at a copy,
  snapshot or mirror of a remote chain's state: not the `vm.create*` / `vm.select*` /
  `vm.roll*` chain-copy cheatcode family, not forge's chain-copy URL flag, not `anvil`,
  not an `[rpc_endpoints]` block in `foundry.toml`, not a local node.
- Enforced MECHANICALLY, not by good intentions: `scripts/no-chain-copy-gate.sh` runs in
  CI, greps every tracked file for the banned tokens, and self-tests by planting one and
  refusing to pass unless it is caught. Doctrine that only lives in prose is not enforced.
- The recovery rehearsal is `RecoveryDrill`, gated on `RECOVERY_DRILL=true`. It deploys its
  OWN throwaway proxy and escrow on Base Sepolia and drills upgrade → arbiter rotation →
  dispute resolution against that. It must NEVER touch the live demo proxy.
- The token `rehears*` is unrelated (it names a Stripe money-path spec in `pigfox2`, and
  the drill above is a rehearsal that copies nothing). Never key a change on it.

## Secrets
- Private keys are write-only at the terminal: never in command output, ledger rows, git,
  `KEYS.md`, or any file that is not a gitignored `.env`.
- `.env` and `.demo-keys.env` are gitignored and stay that way. Presence-check by NAME
  (`[ -n "$VAR" ] && echo present`), never echo a value.
- Role keys are the unified `DEMO_*` set documented in `../KEYS.md` (addresses only there).

## Chain writes
- Never-assume-verify: a read-only check confirming the assumed state runs immediately
  before any state-changing transaction, in the same session. After a write, read the
  state back to confirm it.
- Confirm reachability with a read-only `eth_blockNumber` before any chain write.
- Testnet only. No mainnet key is involved anywhere in this repo.

## Gate
- `forge build` + `forge test` + `forge fmt --check`, plus Slither and Echidna as the
  repo already configures them. Solidity ships 100% covered — new code carries its tests
  in the same patch.

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EscrowUpgradeable} from "./EscrowUpgradeable.sol";

/// @title EscrowUpgradeableV2
/// @notice Recovery upgrade for {EscrowUpgradeable}. It adds a single owner-only
///         function, {setArbiter}, so a stuck escrow — one left in `Disputed`
///         whose arbiter address holds no key and can therefore never settle it —
///         can have its arbiter rotated to a keyed address that can.
/// @dev V2 DELTA (append-only; NO storage-layout change of any kind):
///        + event  ArbiterRotated(uint256,address,address)
///        + function setArbiter(uint256,address) external onlyOwner
///      No new storage variables and no reordering: V2 inherits V1's layout
///      verbatim, and V1's reserved `__gap` is untouched. Every V1 function,
///      storage slot, event, and invariant is preserved. The only change to V1's
///      source is widening `_escrows` from `private` to `internal` (visibility
///      only — identical slot, identical behaviour) so this contract can reach it
///      by inheritance rather than by duplicating the whole storage block.
///
///      `_authorizeUpgrade` (onlyOwner) is inherited unchanged, so V2 is itself
///      upgradeable by the same owner authority.
contract EscrowUpgradeableV2 is EscrowUpgradeable {
    /// @notice Emitted when the owner rotates a disputed escrow's arbiter.
    event ArbiterRotated(uint256 indexed escrowId, address indexed oldArbiter, address indexed newArbiter);

    /// @notice Rotates the arbiter of a `Disputed` escrow. Owner-only recovery.
    /// @dev The narrowest surface that fixes the stranded-dispute problem:
    ///        - onlyOwner (the UUPS upgrade authority; the same governance that
    ///          could swap the whole implementation anyway),
    ///        - the escrow must exist and be `Disputed` (a rotation is only ever a
    ///          recovery tool for a stuck dispute, never a mid-flight party swap),
    ///        - the new arbiter must be a real address distinct from the buyer and
    ///          the seller.
    ///      The distinctness guard preserves V1's core invariant: `resolveDispute`
    ///      routes funds only to the buyer or the seller, so a rotated arbiter
    ///      still can never be the beneficiary. This function touches no balance
    ///      and no field other than `arbiter`.
    /// @param escrowId The disputed escrow to rotate.
    /// @param newArbiter The replacement arbiter (non-zero, not the buyer/seller).
    function setArbiter(uint256 escrowId, address newArbiter) external onlyOwner {
        Escrow storage e = _escrows[escrowId];
        if (e.state == State.None) revert EscrowDoesNotExist(escrowId);
        if (newArbiter == address(0)) revert ZeroAddress();
        if (newArbiter == e.buyer || newArbiter == e.seller) revert DuplicateParty();
        if (e.state != State.Disputed) revert InvalidState(escrowId, State.Disputed, e.state);

        address oldArbiter = e.arbiter;
        e.arbiter = newArbiter;

        emit ArbiterRotated(escrowId, oldArbiter, newArbiter);
    }
}

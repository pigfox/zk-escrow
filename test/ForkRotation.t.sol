// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";

import {EscrowUpgradeable} from "../src/EscrowUpgradeable.sol";
import {EscrowUpgradeableV2} from "../src/EscrowUpgradeableV2.sol";

/// @title ForkRotationTest
/// @notice The BLOCKING rehearsal: forks LIVE Base Sepolia state and drives the
///         whole recovery — deploy V2 → upgradeToAndCall as owner → setArbiter to
///         the fresh keyed arbiter → resolveDispute as that arbiter — proving on a
///         local fork (mutating nothing on chain) that funds route to the ruled
///         side, the state reaches Resolved, and DisputeResolved fires.
/// @dev Gated on FORK_REHEARSAL=true so the default suite and the coverage gate
///      (which have no RPC) skip it. Run it deliberately:
///        FORK_REHEARSAL=true forge test --match-contract ForkRotationTest -vv
contract ForkRotationTest is Test {
    // Live deployment (from README + on-chain reads).
    address internal constant PROXY = 0x8bB2ae77AcE1424a9418f32bb2b2077563eE8A84;
    address internal constant OWNER = 0x49FE3B2731090b93d297D259BD1eFFC5DB015edF;
    // The fresh keyed arbiter generated in Phase 0 (address is public).
    address internal constant FRESH_ARBITER = 0x6BBc782624B3c604e32Ed8b8C00d273970F67d0C;

    // keccak256 of the DisputeResolved event signature (Ruling is uint8 in the ABI).
    bytes32 internal constant DISPUTE_RESOLVED_SIG =
        keccak256("DisputeResolved(uint256,address,uint8,address,uint256,string)");

    EscrowUpgradeableV2 internal escrow;
    bool internal enabled;

    function setUp() public {
        enabled = vm.envOr("FORK_REHEARSAL", false);
        if (!enabled) return;
        vm.createSelectFork("base_sepolia");
        escrow = EscrowUpgradeableV2(PROXY);
    }

    /// @dev The full rehearsal for one disputed escrow.
    function _rehearse(uint256 id) internal {
        EscrowUpgradeable.Escrow memory pre = escrow.getEscrow(id);
        assertTrue(pre.state == EscrowUpgradeable.State.Disputed, "precondition: escrow is Disputed");
        assertTrue(pre.arbiter != FRESH_ARBITER, "precondition: not already the fresh arbiter");

        // 1. Deploy V2 and upgrade the live proxy — as the owner.
        EscrowUpgradeableV2 v2 = new EscrowUpgradeableV2();
        vm.prank(OWNER);
        escrow.upgradeToAndCall(address(v2), "");

        // 2. Rotate the keyless arbiter to the fresh keyed one — as the owner.
        vm.prank(OWNER);
        escrow.setArbiter(id, FRESH_ARBITER);
        assertEq(escrow.getEscrow(id).arbiter, FRESH_ARBITER, "arbiter rotated");

        // 3. Settle as the fresh arbiter. SellerWins -> the SELLER is credited.
        uint256 sellerBefore = escrow.pendingWithdrawals(pre.seller);
        uint256 buyerBefore = escrow.pendingWithdrawals(pre.buyer);

        vm.recordLogs();
        vm.prank(FRESH_ARBITER);
        escrow.resolveDispute(id, EscrowUpgradeable.Ruling.SellerWins, "fork rehearsal: seller prevails");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // State reached Resolved; funds routed to the seller, never the arbiter.
        assertTrue(escrow.getState(id) == EscrowUpgradeable.State.Resolved, "state Resolved");
        assertEq(
            escrow.pendingWithdrawals(pre.seller) - sellerBefore, pre.amount, "seller credited the amount"
        );
        assertEq(escrow.pendingWithdrawals(pre.buyer), buyerBefore, "buyer unchanged");
        assertEq(escrow.pendingWithdrawals(FRESH_ARBITER), 0, "arbiter NEVER credited");

        // DisputeResolved fired for this escrow, with the fresh arbiter and seller.
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics.length == 4 && logs[i].topics[0] == DISPUTE_RESOLVED_SIG
                    && uint256(logs[i].topics[1]) == id
                    && address(uint160(uint256(logs[i].topics[2]))) == FRESH_ARBITER
                    && address(uint160(uint256(logs[i].topics[3]))) == pre.seller
            ) {
                found = true;
                break;
            }
        }
        assertTrue(found, "DisputeResolved emitted for this escrow by the fresh arbiter");
    }

    /// @notice Rehearse the named target, escrow #22.
    function test_Fork_RehearseEscrow22() public {
        if (!enabled) {
            vm.skip(true);
            return;
        }
        _rehearse(22);
    }

    /// @notice Rehearse a second escrow (#5) to prove the rotation generalizes.
    function test_Fork_RehearseEscrow5() public {
        if (!enabled) {
            vm.skip(true);
            return;
        }
        _rehearse(5);
    }
}

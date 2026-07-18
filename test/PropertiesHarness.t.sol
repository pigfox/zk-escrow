// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Properties} from "./Properties.sol";
import {EscrowUpgradeable} from "../src/EscrowUpgradeable.sol";

/// @title PropertiesHarnessTest
/// @notice Proves the shared fuzz harness is not vacuous.
/// @dev A property suite that silently never reaches an interesting state is
///      worse than no suite at all: it reports green forever. These tests drive
///      `Properties`' entry points deterministically and assert each terminal
///      state is actually reachable through them, so a green Echidna/Medusa run
///      means something.
contract PropertiesHarnessTest is Test {
    Properties internal p;

    function setUp() public {
        p = new Properties{value: 1000 ether}();
    }

    function test_Harness_ReachesReleased() public {
        p.createEscrow(1 ether, uint256(keccak256("c")));
        p.fund(0);
        assertTrue(_state(0) == EscrowUpgradeable.State.Funded, "funded");

        p.release(0, uint256(keccak256("n")));
        assertTrue(_state(0) == EscrowUpgradeable.State.Released, "released");
        _assertAllProperties();
    }

    function test_Harness_ReachesRefunded() public {
        p.createEscrow(1 ether, uint256(keccak256("c")));
        p.fund(0);
        p.refund(0);
        assertTrue(_state(0) == EscrowUpgradeable.State.Refunded, "refunded");
        _assertAllProperties();
    }

    function test_Harness_ReachesResolvedForBuyer() public {
        p.createEscrow(1 ether, uint256(keccak256("c")));
        p.fund(0);
        p.raiseDispute(0, false);
        assertTrue(_state(0) == EscrowUpgradeable.State.Disputed, "disputed");

        p.submitEvidence(0, true);
        p.resolveDispute(0, false);
        assertTrue(_state(0) == EscrowUpgradeable.State.Resolved, "resolved");

        assertEq(
            p.escrow().pendingWithdrawals(address(p.buyer())), _amount(0), "buyer won the dispute"
        );
        _assertAllProperties();
    }

    function test_Harness_ReachesResolvedForSeller() public {
        p.createEscrow(1 ether, uint256(keccak256("c")));
        p.fund(0);
        p.raiseDispute(0, true);
        p.resolveDispute(0, true);
        assertTrue(_state(0) == EscrowUpgradeable.State.Resolved, "resolved");
        assertEq(
            p.escrow().pendingWithdrawals(address(p.seller())), _amount(0), "seller won the dispute"
        );
        _assertAllProperties();
    }

    function test_Harness_UnauthorizedResolveIsRejected() public {
        p.createEscrow(1 ether, uint256(keccak256("c")));
        p.fund(0);
        p.raiseDispute(0, false);

        p.resolveDisputeUnauthorized(0, true);

        // Still disputed, and the harness did not flag a leak — because the
        // call was correctly rejected rather than quietly succeeding.
        assertTrue(_state(0) == EscrowUpgradeable.State.Disputed, "still disputed");
        assertFalse(p.fundsLeftTheParties(), "guard held");
        _assertAllProperties();
    }

    function test_Harness_WithdrawDrainsCredits() public {
        p.createEscrow(1 ether, uint256(keccak256("c")));
        p.fund(0);
        p.release(0, uint256(keccak256("n")));

        assertEq(p.escrow().pendingWithdrawals(address(p.seller())), _amount(0), "credited");

        uint256 owed = _amount(0);
        p.withdraw(1); // seed % 3 == 1 -> seller
        assertEq(p.escrow().pendingWithdrawals(address(p.seller())), 0, "drained");
        assertEq(address(p.seller()).balance, owed, "seller holds the ETH");
        _assertAllProperties();
    }

    function test_Harness_FailedProofLeavesEscrowFunded() public {
        p.createEscrow(1 ether, uint256(keccak256("c")));
        p.fund(0);
        p.setVerifierVerdict(false);
        p.release(0, uint256(keccak256("n")));

        assertTrue(_state(0) == EscrowUpgradeable.State.Funded, "unchanged on bad proof");
        _assertAllProperties();
    }

    /// @dev Entry points must be safe to call before any escrow exists.
    function test_Harness_NoOpsWhenNoEscrows() public {
        p.fund(0);
        p.release(0, 1);
        p.refund(0);
        p.raiseDispute(0, false);
        p.submitEvidence(0, false);
        p.resolveDispute(0, false);
        p.resolveDisputeUnauthorized(0, false);
        p.withdraw(0);
        p.withdraw(1);
        p.withdraw(2);
        _assertAllProperties();
    }

    /// @dev The harness bounds the requested amount, so tests read back what
    ///      the escrow actually recorded rather than assuming.
    function _amount(uint256 id) internal view returns (uint256) {
        return p.escrow().getEscrow(p.createdEscrows(id)).amount;
    }

    function _state(uint256 id) internal view returns (EscrowUpgradeable.State) {
        return p.escrow().getState(p.createdEscrows(id));
    }

    function _assertAllProperties() internal view {
        assertTrue(p.echidna_balance_equals_obligations(), "balance == obligations");
        assertTrue(p.echidna_arbiter_never_credited(), "arbiter never credited");
        assertTrue(p.echidna_state_machine_valid(), "state machine valid");
        assertTrue(p.echidna_obligations_never_exceed_funded(), "obligations <= funded");
    }
}

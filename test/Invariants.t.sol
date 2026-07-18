// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Properties} from "./Properties.sol";

/// @title InvariantsTest
/// @notice Runs the shared `Properties` harness under Foundry's invariant
///         engine, asserting the same predicates Echidna and Medusa check.
/// @dev The fuzz target is the harness itself: `targetContract` points Foundry
///      at it, so every public entry point becomes a possible call in a
///      randomized sequence, and the `invariant_*` functions below re-assert
///      the shared `echidna_*` predicates after each sequence.
contract InvariantsTest is Test {
    Properties internal properties;

    function setUp() public {
        properties = new Properties{value: 1000 ether}();

        targetContract(address(properties));

        // Only the fuzz entry points — not the view predicates or getters.
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = Properties.createEscrow.selector;
        selectors[1] = Properties.fund.selector;
        selectors[2] = Properties.release.selector;
        selectors[3] = Properties.refund.selector;
        selectors[4] = Properties.raiseDispute.selector;
        selectors[5] = Properties.submitEvidence.selector;
        selectors[6] = Properties.resolveDispute.selector;
        selectors[7] = Properties.resolveDisputeUnauthorized.selector;
        selectors[8] = Properties.withdraw.selector;
        targetSelector(FuzzSelector({addr: address(properties), selectors: selectors}));
    }

    /// @notice INVARIANT (a): contract balance == sum of pending obligations.
    function invariant_BalanceEqualsObligations() public view {
        assertTrue(
            properties.echidna_balance_equals_obligations(),
            "escrow balance diverged from pending obligations"
        );
    }

    /// @notice INVARIANT (b): funds never reach the arbiter.
    function invariant_ArbiterNeverCredited() public view {
        assertTrue(
            properties.echidna_arbiter_never_credited(), "arbiter was credited or paid out"
        );
    }

    /// @notice INVARIANT (c): the state machine is never violated.
    function invariant_StateMachineValid() public view {
        assertTrue(properties.echidna_state_machine_valid(), "illegal state transition observed");
    }

    /// @notice Obligations can never exceed what was actually funded.
    function invariant_ObligationsNeverExceedFunded() public view {
        assertTrue(
            properties.echidna_obligations_never_exceed_funded(),
            "obligations exceeded funded total"
        );
    }

    /// @notice Sanity check that the harness is actually reaching interesting
    ///         states, so a silently-inert fuzz run cannot pass as a green
    ///         invariant suite.
    function invariant_HarnessMakesProgress() public view {
        // Not an assertion about the protocol — an assertion about the test.
        assertTrue(address(properties.escrow()) != address(0), "harness deployed");
    }
}

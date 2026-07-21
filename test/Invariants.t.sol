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
        //
        // Foundry weights the selector distribution by REPETITION, so entries
        // are duplicated to shape the walk. The bias is toward getting escrows
        // created and funded, because everything interesting is downstream of
        // a live escrow: a sequence that never funds anything can only ever
        // bounce off state guards. `setVerifierVerdict` is in the set because
        // verdict flips now gate whether `release` is reachable at all.
        bytes4[] memory selectors = new bytes4[](18);
        selectors[0] = Properties.createEscrow.selector;
        selectors[1] = Properties.createEscrow.selector;
        selectors[2] = Properties.createEscrow.selector;
        selectors[3] = Properties.fund.selector;
        selectors[4] = Properties.fund.selector;
        selectors[5] = Properties.fund.selector;
        selectors[6] = Properties.release.selector;
        selectors[7] = Properties.release.selector;
        selectors[8] = Properties.refund.selector;
        selectors[9] = Properties.refund.selector;
        selectors[10] = Properties.resolveDispute.selector;
        selectors[11] = Properties.resolveDispute.selector;
        selectors[12] = Properties.raiseDispute.selector;
        selectors[13] = Properties.raiseDispute.selector;
        selectors[14] = Properties.submitEvidence.selector;
        selectors[15] = Properties.resolveDisputeUnauthorized.selector;
        selectors[16] = Properties.withdraw.selector;
        selectors[17] = Properties.setVerifierVerdict.selector;
        targetSelector(FuzzSelector({addr: address(properties), selectors: selectors}));
    }

    /// @notice INVARIANT (a): contract balance == sum of pending obligations.
    function invariant_BalanceEqualsObligations() public view {
        assertTrue(
            properties.echidna_balance_equals_obligations(),
            "escrow balance diverged from pending obligations"
        );
    }

    /// @notice INVARIANT (b): no settlement ever credits its escrow's arbiter.
    function invariant_ArbiterNeverCredited() public view {
        assertTrue(
            properties.echidna_arbiter_never_credited(), "a settlement credited its own arbiter"
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

    /// @notice INVARIANT (d): a nullifier can settle at most one escrow.
    function invariant_NullifierNeverReused() public view {
        assertTrue(
            properties.echidna_nullifier_never_reused(),
            "a nullifier settled more than one escrow"
        );
    }

    /// @notice The progress ledger's success counts never outrun their
    ///         opportunity counts.
    /// @dev Guards the canary itself: `afterInvariant` below only means
    ///      anything while every success is dominated by a registered
    ///      opportunity in the same call frame.
    function invariant_LedgerConsistent() public view {
        assertTrue(
            properties.echidna_ledger_consistent(),
            "a success counter advanced without registering an opportunity"
        );
    }

    /// @notice Proves the run was not inert.
    /// @dev Not an assertion about the protocol — an assertion about the test.
    ///      A property suite that never reaches an interesting state reports
    ///      green forever, which is indistinguishable from a correct protocol
    ///      unless something checks that the walk actually went somewhere.
    ///      These counters only advance on successful calls, so they cannot be
    ///      satisfied by a sequence that merely bounced off guards.
    ///
    ///      Each check is an IMPLICATION, not a bare count. Foundry runs
    ///      `afterInvariant` after EVERY run, so anything asserted here has to
    ///      hold across all 256 runs of each of the six invariants — roughly
    ///      1500 samples per `forge test`. A bare `ghost_funds > 0` does not:
    ///      a walk that happens to draw zero `fund` selectors in 64 picks has
    ///      probability ~6e-6, which over 1280 samples surfaces about once
    ///      every ten invocations. That is an unlucky sequence, not a broken
    ///      harness, and failing on it would just make the suite flaky.
    ///
    ///      So each opportunity counter tallies only calls whose preconditions
    ///      were ALL satisfied — calls that could not legitimately have been
    ///      rejected. Asserting success-given-opportunity asks the question
    ///      that actually matters, "did anything that should have worked fail
    ///      to?", and is immune to how the selector dice landed.
    function afterInvariant() public view {
        if (properties.ghost_createAttempts() > 0) {
            assertGt(properties.ghost_creates(), 0, "every createEscrow attempt was rejected");
        }
        if (properties.ghost_fundOpportunities() > 0) {
            assertGt(properties.ghost_funds(), 0, "every fundable escrow failed to fund");
        }
        if (properties.ghost_settleOpportunities() > 0) {
            assertGt(
                properties.ghost_releases() + properties.ghost_refunds()
                    + properties.ghost_resolutions(),
                0,
                "every settleable escrow failed to settle"
            );
        }
    }
}

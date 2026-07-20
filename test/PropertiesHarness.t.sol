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
///
///      Since the harness rotates a pool of actors, no test may assume a fixed
///      party triple. Each reads the real parties back off the escrow and
///      resolves them through the harness' pool lookup.
contract PropertiesHarnessTest is Test {
    Properties internal p;

    /// @dev A commitment value; the specific number is irrelevant except where
    ///      a test deliberately searches for one that produces a role overlap.
    uint256 internal constant C = uint256(keccak256("c"));

    function setUp() public {
        p = new Properties{value: 1000 ether}();
    }

    function test_Harness_ReachesReleased() public {
        p.createEscrow(1 ether, C);
        p.fund(0);
        assertTrue(_state(0) == EscrowUpgradeable.State.Funded, "funded");

        p.release(0, uint256(keccak256("n")));
        assertTrue(_state(0) == EscrowUpgradeable.State.Released, "released");
        _assertAllProperties();
    }

    function test_Harness_ReachesRefunded() public {
        p.createEscrow(1 ether, C);
        p.fund(0);
        p.refund(0);
        assertTrue(_state(0) == EscrowUpgradeable.State.Refunded, "refunded");
        _assertAllProperties();
    }

    function test_Harness_ReachesResolvedForBuyer() public {
        p.createEscrow(1 ether, C);
        p.fund(0);
        p.raiseDispute(0, false);
        assertTrue(_state(0) == EscrowUpgradeable.State.Disputed, "disputed");

        p.submitEvidence(0, true);
        p.resolveDispute(0, false);
        assertTrue(_state(0) == EscrowUpgradeable.State.Resolved, "resolved");

        (address buyer,,) = _parties(0);
        assertEq(p.escrow().pendingWithdrawals(buyer), _amount(0), "buyer won the dispute");
        _assertAllProperties();
    }

    function test_Harness_ReachesResolvedForSeller() public {
        p.createEscrow(1 ether, C);
        p.fund(0);
        p.raiseDispute(0, true);
        p.resolveDispute(0, true);
        assertTrue(_state(0) == EscrowUpgradeable.State.Resolved, "resolved");

        (, address seller,) = _parties(0);
        assertEq(p.escrow().pendingWithdrawals(seller), _amount(0), "seller won the dispute");
        _assertAllProperties();
    }

    function test_Harness_UnauthorizedResolveIsRejected() public {
        p.createEscrow(1 ether, C);
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
        p.createEscrow(1 ether, C);
        p.fund(0);
        p.release(0, uint256(keccak256("n")));

        (, address seller,) = _parties(0);
        assertEq(p.escrow().pendingWithdrawals(seller), _amount(0), "credited");

        uint256 owed = _amount(0);
        uint256 before = seller.balance;

        p.withdraw(p.poolIndexOf(seller));

        assertEq(p.escrow().pendingWithdrawals(seller), 0, "drained");
        assertEq(seller.balance - before, owed, "seller holds the ETH");
        _assertAllProperties();
    }

    function test_Harness_FailedProofLeavesEscrowFunded() public {
        p.createEscrow(1 ether, C);
        p.fund(0);
        p.setVerifierVerdict(false);
        p.release(0, uint256(keccak256("n")));

        assertTrue(_state(0) == EscrowUpgradeable.State.Funded, "unchanged on bad proof");
        _assertAllProperties();
    }

    /// @notice A nullifier spent releasing one escrow cannot release another.
    /// @dev This is the path the raw-uint256 nullifier made unreachable: with
    ///      2^256 possible values the fuzzer never collided, so the replay
    ///      guard was never exercised and `echidna_nullifier_never_reused`
    ///      passed vacuously. The harness now bounds nullifiers into a pool of
    ///      eight; this test pins the behaviour that bound is meant to reach.
    function test_Harness_SpentNullifierCannotReleaseSecondEscrow() public {
        // `release` bounds its nullifier to 1..8, so raw 0 becomes nullifier 1.
        uint256 raw = 0;
        uint256 n = 1;

        p.createEscrow(1 ether, C);
        p.fund(0);
        p.release(0, raw);
        assertTrue(_state(0) == EscrowUpgradeable.State.Released, "A released");
        assertEq(p.nullifierReleaseCount(n), 1, "nullifier spent once");

        p.createEscrow(2 ether, uint256(keccak256("c2")));
        p.fund(1);
        assertTrue(_state(1) == EscrowUpgradeable.State.Funded, "B funded");

        p.release(1, raw);

        assertTrue(_state(1) == EscrowUpgradeable.State.Funded, "B still funded, replay rejected");
        assertEq(p.nullifierReleaseCount(n), 1, "nullifier still spent exactly once");
        assertFalse(p.nullifierReuseSeen(), "no reuse observed");
        _assertAllProperties();
    }

    /// @notice One address may hold different roles across different escrows.
    /// @dev The blind spot a fixed buyer/seller/arbiter triple leaves open: it
    ///      can never produce a state where an address is owed money from two
    ///      escrows in two different capacities. Invariant (a) has to keep
    ///      balancing there, and each address's credit has to be exactly the
    ///      sum of what it actually won.
    function test_Harness_SameAddressBuyerAndSellerAcrossEscrows() public {
        uint256 amtA = 1 ether;
        uint256 amtB = 2 ether;

        // Search for commitments making A's seller also B's buyer.
        uint256 cA;
        uint256 cB;
        bool found;
        for (uint256 i = 1; i < 64 && !found; i++) {
            (, uint256 sellerA,) = p.rolesFor(amtA, i);
            for (uint256 j = 1; j < 64; j++) {
                (uint256 buyerB,,) = p.rolesFor(amtB, j);
                if (buyerB == sellerA) {
                    cA = i;
                    cB = j;
                    found = true;
                    break;
                }
            }
        }
        assertTrue(found, "found seeds producing a role overlap");

        p.createEscrow(amtA, cA);
        p.createEscrow(amtB, cB);

        (, address sellerOfA,) = _parties(0);
        (address buyerOfB,,) = _parties(1);
        assertEq(sellerOfA, buyerOfB, "same address holds both roles");

        p.fund(0);
        p.fund(1);

        // A releases to its seller; B is refunded to its buyer. Both credits
        // land on the same address, from opposite sides of the protocol.
        p.release(0, 0);
        assertTrue(_state(0) == EscrowUpgradeable.State.Released, "A released");

        p.refund(1);
        assertTrue(_state(1) == EscrowUpgradeable.State.Refunded, "B refunded");

        assertEq(
            p.escrow().pendingWithdrawals(sellerOfA),
            _amount(0) + _amount(1),
            "credit is the sum of both wins"
        );

        // Everyone else is owed exactly nothing.
        for (uint256 i = 0; i < p.poolSize(); i++) {
            address a = address(p.poolActorAt(i));
            if (a == sellerOfA) continue;
            assertEq(p.escrow().pendingWithdrawals(a), 0, "non-winner owed nothing");
        }

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
        for (uint256 i = 0; i < p.poolSize(); i++) {
            p.withdraw(i);
        }
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

    /// @dev Reads an escrow's real parties; the actor pool rotates, so no test
    ///      may hardcode who is who.
    function _parties(uint256 id)
        internal
        view
        returns (address buyer, address seller, address arbiter)
    {
        EscrowUpgradeable.Escrow memory e = p.escrow().getEscrow(p.createdEscrows(id));
        return (e.buyer, e.seller, e.arbiter);
    }

    function _assertAllProperties() internal view {
        assertTrue(p.echidna_balance_equals_obligations(), "balance == obligations");
        assertTrue(p.echidna_arbiter_never_credited(), "arbiter never credited");
        assertTrue(p.echidna_state_machine_valid(), "state machine valid");
        assertTrue(p.echidna_obligations_never_exceed_funded(), "obligations <= funded");
        assertTrue(p.echidna_nullifier_never_reused(), "nullifier never reused");
    }
}

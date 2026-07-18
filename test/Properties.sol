// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EscrowUpgradeable} from "../src/EscrowUpgradeable.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";
import {Actor} from "./Actor.sol";

/// @title Properties
/// @notice The single source of truth for the protocol's invariants, shared by
///         Foundry, Echidna and Medusa.
/// @dev The harness deploys its own escrow plus three `Actor` forwarders — one
///      each for the buyer, seller and arbiter — so every party has a real,
///      distinct `msg.sender` without needing cheatcodes. That matters: it
///      means the fuzzers actually reach `Resolved` through a genuine arbiter
///      call, rather than bouncing off the access-control guard forever.
///
///      Keeping one property contract means a property can never drift between
///      the three engines. Foundry's `Invariants.t.sol` calls the same
///      `echidna_*` predicates that Echidna and Medusa evaluate.
contract Properties {
    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The escrow under test, behind its proxy.
    EscrowUpgradeable public escrow;

    /// @notice The mock verifier, so `release` is reachable by the fuzzer.
    MockVerifier public verifier;

    /// @notice The three parties, as callable contracts.
    Actor public buyer;
    Actor public seller;
    Actor public arbiter;

    /// @notice Ids of escrows this harness has created.
    uint256[] public createdEscrows;

    /// @notice Sticky flag: set if the arbiter is ever credited anything.
    bool public arbiterWasCredited;

    /// @notice Sticky flag: set if an escrow is ever seen making a transition
    ///         outside the declared state machine.
    bool public invalidTransitionSeen;

    /// @notice Sticky flag: set if a settlement ever credits an address that is
    ///         neither the buyer nor the seller of that escrow.
    bool public fundsLeftTheParties;

    /// @notice Last observed state per escrow, for transition checking.
    mapping(uint256 => EscrowUpgradeable.State) public lastState;

    /// @notice Total ETH the harness has put into escrows.
    uint256 public totalFunded;

    /// @dev Starting balance handed to the buyer actor.
    uint256 internal constant BUYER_ENDOWMENT = 1000 ether;

    constructor() payable {
        verifier = new MockVerifier();

        EscrowUpgradeable impl = new EscrowUpgradeable();
        bytes memory initData =
            abi.encodeCall(EscrowUpgradeable.initialize, (address(verifier), address(this)));
        escrow = EscrowUpgradeable(address(new ERC1967Proxy(address(impl), initData)));

        buyer = new Actor();
        seller = new Actor();
        arbiter = new Actor();

        // Echidna/Medusa endow this contract at deploy time; Foundry's setUp
        // deals it explicitly. Either way, stake the buyer.
        uint256 stake = address(this).balance < BUYER_ENDOWMENT
            ? address(this).balance
            : BUYER_ENDOWMENT;
        if (stake > 0) {
            (bool ok,) = payable(address(buyer)).call{value: stake}("");
            require(ok, "endow buyer");
        }
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                            FUZZER ENTRY POINTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates an escrow with the buyer actor as buyer.
    function createEscrow(uint256 amount, uint256 commitment) public {
        amount = _bound(amount, 1, 10 ether);

        uint256 expectedId = escrow.nextEscrowId();
        (bool ok,) = buyer.exec(
            address(escrow),
            0,
            abi.encodeCall(
                EscrowUpgradeable.createEscrow,
                (address(seller), address(arbiter), amount, commitment)
            )
        );

        if (ok) {
            createdEscrows.push(expectedId);
            _observe(expectedId);
        }
    }

    /// @notice Funds a previously created escrow from the buyer actor.
    function fund(uint256 seed) public {
        (bool exists, uint256 id) = _pick(seed);
        if (!exists) return;

        uint256 amount = _amountOf(id);
        if (amount == 0 || address(buyer).balance < amount) return;

        (bool ok,) =
            buyer.exec(address(escrow), amount, abi.encodeCall(EscrowUpgradeable.fund, (id)));
        if (ok) {
            totalFunded += amount;
            _observe(id);
        }
    }

    /// @notice Releases an escrow against the mock verifier's verdict.
    /// @dev Callable by anyone in the real contract, so the harness calls it
    ///      directly rather than through an actor.
    function release(uint256 seed, uint256 nullifier) public {
        (bool exists, uint256 id) = _pick(seed);
        if (!exists) return;

        uint256[2] memory a;
        uint256[2][2] memory b;
        uint256[2] memory c;

        try escrow.release(id, nullifier, a, b, c) {
            _observe(id);
        } catch {}
    }

    /// @notice Flips the verifier verdict so both proof branches are explored.
    function setVerifierVerdict(bool value) public {
        verifier.setShouldVerify(value);
    }

    /// @notice Refunds an escrow from the seller actor.
    function refund(uint256 seed) public {
        (bool exists, uint256 id) = _pick(seed);
        if (!exists) return;

        (bool ok,) =
            seller.exec(address(escrow), 0, abi.encodeCall(EscrowUpgradeable.refund, (id)));
        if (ok) _observe(id);
    }

    /// @notice Raises a dispute from either the buyer or the seller.
    function raiseDispute(uint256 seed, bool asSeller) public {
        (bool exists, uint256 id) = _pick(seed);
        if (!exists) return;

        Actor who = asSeller ? seller : buyer;
        (bool ok,) = who.exec(
            address(escrow),
            0,
            abi.encodeCall(EscrowUpgradeable.raiseDispute, (id, "fuzz evidence"))
        );
        if (ok) _observe(id);
    }

    /// @notice Submits further evidence from either party.
    function submitEvidence(uint256 seed, bool asSeller) public {
        (bool exists, uint256 id) = _pick(seed);
        if (!exists) return;

        Actor who = asSeller ? seller : buyer;
        (bool ok,) = who.exec(
            address(escrow),
            0,
            abi.encodeCall(EscrowUpgradeable.submitEvidence, (id, "fuzz evidence"))
        );
        if (ok) _observe(id);
    }

    /// @notice Resolves a dispute from the genuine arbiter actor.
    /// @dev This is the call that could conceivably misroute funds, so it runs
    ///      with real authority rather than being blocked by access control.
    function resolveDispute(uint256 seed, bool sellerWins) public {
        (bool exists, uint256 id) = _pick(seed);
        if (!exists) return;

        EscrowUpgradeable.Ruling ruling =
            sellerWins ? EscrowUpgradeable.Ruling.SellerWins : EscrowUpgradeable.Ruling.BuyerWins;

        uint256 arbiterBefore = escrow.pendingWithdrawals(address(arbiter));

        (bool ok,) = arbiter.exec(
            address(escrow),
            0,
            abi.encodeCall(EscrowUpgradeable.resolveDispute, (id, ruling, "fuzz rationale"))
        );

        if (ok) {
            if (escrow.pendingWithdrawals(address(arbiter)) != arbiterBefore) {
                fundsLeftTheParties = true;
            }
            _observe(id);
        }
    }

    /// @notice Attempts a dispute resolution from an address that is not the
    ///         arbiter, which must always fail.
    function resolveDisputeUnauthorized(uint256 seed, bool sellerWins) public {
        (bool exists, uint256 id) = _pick(seed);
        if (!exists) return;

        EscrowUpgradeable.Ruling ruling =
            sellerWins ? EscrowUpgradeable.Ruling.SellerWins : EscrowUpgradeable.Ruling.BuyerWins;

        (bool ok,) = buyer.exec(
            address(escrow),
            0,
            abi.encodeCall(EscrowUpgradeable.resolveDispute, (id, ruling, "unauthorized"))
        );

        // The buyer is never the arbiter, so success here is a broken guard.
        if (ok) fundsLeftTheParties = true;
    }

    /// @notice Withdraws for one of the three actors.
    function withdraw(uint256 seed) public {
        Actor who = seed % 3 == 0 ? buyer : (seed % 3 == 1 ? seller : arbiter);
        who.exec(address(escrow), 0, abi.encodeCall(EscrowUpgradeable.withdraw, ()));
    }

    /*//////////////////////////////////////////////////////////////
                               PROPERTIES
    //////////////////////////////////////////////////////////////*/

    /// @notice INVARIANT (a): the contract's ETH balance always equals the sum
    ///         of everything it still owes.
    /// @dev An obligation is either already credited to a payee
    ///      (`pendingWithdrawals`) or still locked against a live escrow — an
    ///      escrow that has been funded but not yet settled, i.e. one in
    ///      `Funded` or `Disputed`. Money moves between those two buckets at
    ///      settlement and leaves the contract only via `withdraw()`.
    ///
    ///      Both halves are recomputed independently of the contract's own
    ///      bookkeeping: the credited half is summed over every address that
    ///      could hold a credit, and the locked half by walking every escrow
    ///      this harness created. A bug in `totalPendingWithdrawals` therefore
    ///      cannot hide behind itself.
    function echidna_balance_equals_obligations() public view returns (bool) {
        uint256 credited = escrow.pendingWithdrawals(address(buyer))
            + escrow.pendingWithdrawals(address(seller))
            + escrow.pendingWithdrawals(address(arbiter))
            + escrow.pendingWithdrawals(address(this));

        if (credited != escrow.totalPendingWithdrawals()) return false;

        uint256 locked;
        for (uint256 i = 0; i < createdEscrows.length; i++) {
            uint256 id = createdEscrows[i];
            EscrowUpgradeable.State s = escrow.getState(id);
            if (s == EscrowUpgradeable.State.Funded || s == EscrowUpgradeable.State.Disputed) {
                locked += _amountOf(id);
            }
        }

        return address(escrow).balance == credited + locked;
    }

    /// @notice INVARIANT (b): no transition ever credits or pays the arbiter.
    function echidna_arbiter_never_credited() public view returns (bool) {
        return !arbiterWasCredited && !fundsLeftTheParties
            && escrow.pendingWithdrawals(address(arbiter)) == 0 && address(arbiter).balance == 0;
    }

    /// @notice INVARIANT (c): every escrow only ever moves along an edge of the
    ///         declared state machine.
    function echidna_state_machine_valid() public view returns (bool) {
        return !invalidTransitionSeen;
    }

    /// @notice Nothing can be owed that was never funded.
    function echidna_obligations_never_exceed_funded() public view returns (bool) {
        return escrow.totalPendingWithdrawals() <= totalFunded;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Records a state observation and flags illegal transitions.
    function _observe(uint256 id) internal {
        EscrowUpgradeable.State prev = lastState[id];
        EscrowUpgradeable.State next = escrow.getState(id);

        if (!_isLegalTransition(prev, next)) invalidTransitionSeen = true;
        if (escrow.pendingWithdrawals(address(arbiter)) != 0) arbiterWasCredited = true;

        lastState[id] = next;
    }

    /// @dev The complete transition table. Anything outside it is a bug.
    function _isLegalTransition(EscrowUpgradeable.State from, EscrowUpgradeable.State to)
        internal
        pure
        returns (bool)
    {
        if (from == to) return true;

        if (from == EscrowUpgradeable.State.None) {
            return to == EscrowUpgradeable.State.Created;
        }
        if (from == EscrowUpgradeable.State.Created) {
            return to == EscrowUpgradeable.State.Funded;
        }
        if (from == EscrowUpgradeable.State.Funded) {
            return to == EscrowUpgradeable.State.Released || to == EscrowUpgradeable.State.Refunded
                || to == EscrowUpgradeable.State.Disputed;
        }
        if (from == EscrowUpgradeable.State.Disputed) {
            return to == EscrowUpgradeable.State.Resolved;
        }
        // Released, Refunded and Resolved are terminal.
        return false;
    }

    /// @dev Picks one of the created escrows, if any exist.
    function _pick(uint256 seed) internal view returns (bool exists, uint256 id) {
        uint256 count = createdEscrows.length;
        if (count == 0) return (false, 0);
        return (true, createdEscrows[seed % count]);
    }

    function _amountOf(uint256 id) internal view returns (uint256) {
        try escrow.getEscrow(id) returns (EscrowUpgradeable.Escrow memory e) {
            return e.amount;
        } catch {
            return 0;
        }
    }

    function _bound(uint256 value, uint256 min, uint256 max) internal pure returns (uint256) {
        if (min >= max) return min;
        return min + (value % (max - min + 1));
    }
}

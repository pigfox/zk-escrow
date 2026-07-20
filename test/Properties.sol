// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EscrowUpgradeable} from "../src/EscrowUpgradeable.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";
import {Actor} from "./Actor.sol";

/// @title Properties
/// @notice The single source of truth for the protocol's invariants, shared by
///         Foundry, Echidna and Medusa.
/// @dev The harness deploys its own escrow plus a pool of six `Actor`
///      forwarders, so every party has a real, distinct `msg.sender` without
///      needing cheatcodes. That matters: it means the fuzzers actually reach
///      `Resolved` through a genuine arbiter call, rather than bouncing off the
///      access-control guard forever.
///
///      The pool is rotated per escrow: buyer, seller and arbiter are three
///      distinct indices derived from the fuzz input, so the SAME address can
///      be the seller of one escrow and the buyer or arbiter of another. That
///      is deliberate — a fixed party triple can never catch a bug that only
///      shows up when roles overlap across escrows.
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

    /// @dev How many interchangeable actors the harness rotates through.
    uint256 internal constant POOL_SIZE = 6;

    /// @notice The interchangeable parties, as callable contracts.
    Actor[] internal actorPool;

    /// @notice Whether an address is one of the pool actors.
    mapping(address => bool) public isPoolActor;

    /// @dev Pool index of an actor, offset by one so zero means "not a member".
    mapping(address => uint256) internal _poolIndexPlus1;

    /// @notice Ids of escrows this harness has created.
    uint256[] public createdEscrows;

    /// @notice Sticky flag: set if an escrow is ever seen making a transition
    ///         outside the declared state machine.
    bool public invalidTransitionSeen;

    /// @notice Sticky flag: set if a settlement ever credits the arbiter of the
    ///         escrow being settled, or if an unauthorized resolve succeeds.
    /// @dev This is a FLOW-level check, not an address-level one. Once actors
    ///      rotate, the arbiter of escrow A may legitimately hold credits it
    ///      earned as the buyer or seller of escrow B, so "this address holds
    ///      zero" is no longer the right question. The right question is
    ///      whether any single settlement moved money to the arbiter of the
    ///      escrow it settled — which the wrappers check before/after each call.
    bool public fundsLeftTheParties;

    /// @notice Last observed state per escrow, for transition checking.
    mapping(uint256 => EscrowUpgradeable.State) public lastState;

    /// @notice How many successful releases each nullifier has been used for.
    /// @dev Must never exceed one: the escrow stores spent nullifiers, so a
    ///      second release against the same nullifier has to revert.
    mapping(uint256 => uint256) public nullifierReleaseCount;

    /// @notice Sticky flag: set if any nullifier ever settles twice.
    bool public nullifierReuseSeen;

    /// @notice Total ETH the harness has put into escrows.
    uint256 public totalFunded;

    /*//////////////////////////////////////////////////////////////
                            PROGRESS GHOSTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Incremented only on SUCCESS, so a run that bounces off every guard
    ///      leaves them at zero. `Invariants.t.sol` asserts on them in
    ///      `afterInvariant`, which turns "the fuzzer did nothing" — the
    ///      failure mode a green property suite cannot otherwise distinguish
    ///      from "the protocol held" — into a test failure.
    uint256 public ghost_creates;
    uint256 public ghost_funds;
    uint256 public ghost_releases;
    uint256 public ghost_refunds;
    uint256 public ghost_resolutions;

    /// @dev Opportunity counters, the denominator for the ones above.
    ///
    ///      A run is only required to make progress if the random walk actually
    ///      handed it the chance. Drawing zero `fund` calls in 64 selections has
    ///      probability (15/18)^64, about 6e-6 — negligible per run, but
    ///      `afterInvariant` fires after all 256 runs of each of the five
    ///      invariants, so across ~1280 samples it shows up roughly once every
    ///      ten `forge test` invocations. Asserting bare success counts
    ///      therefore fails on unlucky-but-correct sequences.
    ///
    ///      These count only calls that had every precondition satisfied and so
    ///      MUST have succeeded. Comparing them against the success counts asks
    ///      the question actually worth asking — "did anything that should have
    ///      worked fail to?" — instead of betting on the selector distribution.
    uint256 public ghost_createAttempts;
    uint256 public ghost_fundOpportunities;
    uint256 public ghost_settleOpportunities;

    /// @dev Starting balance split across the actor pool.
    uint256 internal constant POOL_ENDOWMENT = 1000 ether;

    constructor() payable {
        verifier = new MockVerifier();

        EscrowUpgradeable impl = new EscrowUpgradeable();
        bytes memory initData =
            abi.encodeCall(EscrowUpgradeable.initialize, (address(verifier), address(this)));
        escrow = EscrowUpgradeable(address(new ERC1967Proxy(address(impl), initData)));

        // Echidna/Medusa endow this contract at deploy time; Foundry's setUp
        // deals it explicitly. Either way, split the stake across the pool so
        // every actor can afford to be a buyer.
        uint256 stake = address(this).balance < POOL_ENDOWMENT
            ? address(this).balance
            : POOL_ENDOWMENT;
        uint256 share = stake / POOL_SIZE;

        for (uint256 i = 0; i < POOL_SIZE; i++) {
            Actor a = new Actor();
            actorPool.push(a);
            isPoolActor[address(a)] = true;
            _poolIndexPlus1[address(a)] = i + 1;

            if (share > 0) {
                (bool ok,) = payable(address(a)).call{value: share}("");
                require(ok, "endow actor");
            }
        }
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                              ACTOR POOL
    //////////////////////////////////////////////////////////////*/

    /// @notice How many actors the harness rotates through.
    function poolSize() public pure returns (uint256) {
        return POOL_SIZE;
    }

    /// @notice The actor at a pool index.
    function poolActorAt(uint256 index) public view returns (Actor) {
        return actorPool[index % POOL_SIZE];
    }

    /// @notice Resolves an address back to its pool actor.
    /// @dev Returns the zero actor for non-members; callers pre-guard on
    ///      `isPoolActor` so a non-member never reaches an `exec`.
    function actorOf(address who) public view returns (Actor) {
        uint256 idxPlus1 = _poolIndexPlus1[who];
        if (idxPlus1 == 0) return Actor(payable(address(0)));
        return actorPool[idxPlus1 - 1];
    }

    /// @notice Pool index of an address, or `type(uint256).max` if not a member.
    function poolIndexOf(address who) public view returns (uint256) {
        uint256 idxPlus1 = _poolIndexPlus1[who];
        if (idxPlus1 == 0) return type(uint256).max;
        return idxPlus1 - 1;
    }

    /// @notice The three distinct pool indices a `createEscrow` call would use.
    /// @dev Exposed as `pure` so deterministic tests can search for the seeds
    ///      that produce a specific role overlap, rather than guessing.
    /// @param amount The raw amount argument to `createEscrow`, unbounded.
    /// @param commitment The commitment argument to `createEscrow`.
    /// @return buyerIdx Pool index that would be the buyer.
    /// @return sellerIdx Pool index that would be the seller.
    /// @return arbiterIdx Pool index that would be the arbiter.
    function rolesFor(uint256 amount, uint256 commitment)
        public
        pure
        returns (uint256 buyerIdx, uint256 sellerIdx, uint256 arbiterIdx)
    {
        uint256 s = uint256(keccak256(abi.encode(amount, commitment)));

        buyerIdx = s % POOL_SIZE;
        // Offset of 1..POOL_SIZE-1 can never land back on the buyer.
        sellerIdx = (buyerIdx + 1 + ((s >> 8) % (POOL_SIZE - 1))) % POOL_SIZE;

        // The k-th index that is neither buyer nor seller.
        uint256 k = (s >> 16) % (POOL_SIZE - 2);
        uint256 seen;
        for (uint256 i = 0; i < POOL_SIZE; i++) {
            if (i == buyerIdx || i == sellerIdx) continue;
            if (seen == k) {
                arbiterIdx = i;
                break;
            }
            seen++;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZER ENTRY POINTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates an escrow, rotating which pool actors take which role.
    function createEscrow(uint256 amount, uint256 commitment) public {
        // Roles are derived from the RAW arguments, before bounding, so
        // `rolesFor` stays a pure function of what the caller passed in and a
        // deterministic test can predict the assignment without reimplementing
        // `_bound`.
        (uint256 b, uint256 s, uint256 a) = rolesFor(amount, commitment);

        amount = _bound(amount, 1, 10 ether);

        // Three distinct pool actors and a non-zero amount: nothing here can
        // legitimately be rejected, so this attempt must turn into a create.
        ghost_createAttempts += 1;

        uint256 expectedId = escrow.nextEscrowId();
        (bool ok,) = actorPool[b].exec(
            address(escrow),
            0,
            abi.encodeCall(
                EscrowUpgradeable.createEscrow,
                (address(actorPool[s]), address(actorPool[a]), amount, commitment)
            )
        );

        if (ok) {
            createdEscrows.push(expectedId);
            ghost_creates += 1;
            _observe(expectedId);
        }
    }

    /// @notice Funds a previously created escrow from that escrow's buyer.
    function fund(uint256 seed) public {
        (bool exists, uint256 id) = _pickInState(seed, EscrowUpgradeable.State.Created);
        if (!exists) return;

        (bool known, address b,,) = _partiesOf(id);
        if (!known || !isPoolActor[b]) return;

        uint256 amount = _amountOf(id);
        if (amount == 0 || b.balance < amount) return;

        // A `Created` escrow, funded by its own buyer, for exactly the recorded
        // amount, with the balance to cover it. This one has to go through.
        ghost_fundOpportunities += 1;

        (bool ok,) =
            actorOf(b).exec(address(escrow), amount, abi.encodeCall(EscrowUpgradeable.fund, (id)));
        if (ok) {
            totalFunded += amount;
            ghost_funds += 1;
            _observe(id);
        }
    }

    /// @notice Releases an escrow against the mock verifier's verdict.
    /// @dev Callable by anyone in the real contract, so the harness calls it
    ///      directly rather than through an actor. The nullifier is bounded
    ///      into a small pool so that collisions actually happen inside a
    ///      single fuzz sequence — with a raw uint256 the replay guard was
    ///      unreachable, and an always-passing property proves nothing.
    function release(uint256 seed, uint256 nullifier) public {
        (bool exists, uint256 id) = _pick(seed);
        if (!exists) return;

        nullifier = _bound(nullifier, 1, 8);

        (bool known,,, address arb) = _partiesOf(id);
        if (!known) return;

        uint256 arbiterBefore = escrow.pendingWithdrawals(arb);

        uint256[2] memory a;
        uint256[2][2] memory b;
        uint256[2] memory c;

        try escrow.release(id, nullifier, a, b, c) {
            nullifierReleaseCount[nullifier] += 1;
            if (nullifierReleaseCount[nullifier] > 1) nullifierReuseSeen = true;
            if (escrow.pendingWithdrawals(arb) > arbiterBefore) fundsLeftTheParties = true;
            ghost_releases += 1;
            _observe(id);
        } catch {}
    }

    /// @notice Flips the verifier verdict so both proof branches are explored.
    function setVerifierVerdict(bool value) public {
        verifier.setShouldVerify(value);
    }

    /// @notice Refunds an escrow from that escrow's seller.
    function refund(uint256 seed) public {
        (bool exists, uint256 id) = _pick(seed);
        if (!exists) return;

        (bool known,, address s, address arb) = _partiesOf(id);
        if (!known || !isPoolActor[s]) return;

        // `Funded` plus the real seller is all `refund` asks for.
        if (escrow.getState(id) == EscrowUpgradeable.State.Funded) {
            ghost_settleOpportunities += 1;
        }

        uint256 arbiterBefore = escrow.pendingWithdrawals(arb);

        (bool ok,) =
            actorOf(s).exec(address(escrow), 0, abi.encodeCall(EscrowUpgradeable.refund, (id)));

        if (ok) {
            if (escrow.pendingWithdrawals(arb) > arbiterBefore) fundsLeftTheParties = true;
            ghost_refunds += 1;
            _observe(id);
        }
    }

    /// @notice Raises a dispute from that escrow's buyer or seller.
    function raiseDispute(uint256 seed, bool asSeller) public {
        (bool exists, uint256 id) = _pick(seed);
        if (!exists) return;

        (bool known, address b, address s,) = _partiesOf(id);
        if (!known) return;

        address who = asSeller ? s : b;
        if (!isPoolActor[who]) return;

        (bool ok,) = actorOf(who).exec(
            address(escrow),
            0,
            abi.encodeCall(EscrowUpgradeable.raiseDispute, (id, "fuzz evidence"))
        );
        if (ok) _observe(id);
    }

    /// @notice Submits further evidence from that escrow's buyer or seller.
    function submitEvidence(uint256 seed, bool asSeller) public {
        (bool exists, uint256 id) = _pick(seed);
        if (!exists) return;

        (bool known, address b, address s,) = _partiesOf(id);
        if (!known) return;

        address who = asSeller ? s : b;
        if (!isPoolActor[who]) return;

        (bool ok,) = actorOf(who).exec(
            address(escrow),
            0,
            abi.encodeCall(EscrowUpgradeable.submitEvidence, (id, "fuzz evidence"))
        );
        if (ok) _observe(id);
    }

    /// @notice Resolves a dispute from that escrow's genuine arbiter.
    /// @dev This is the call that could conceivably misroute funds, so it runs
    ///      with real authority rather than being blocked by access control.
    function resolveDispute(uint256 seed, bool sellerWins) public {
        (bool exists, uint256 id) = _pick(seed);
        if (!exists) return;

        (bool known,,, address arb) = _partiesOf(id);
        if (!known || !isPoolActor[arb]) return;

        EscrowUpgradeable.Ruling ruling =
            sellerWins ? EscrowUpgradeable.Ruling.SellerWins : EscrowUpgradeable.Ruling.BuyerWins;

        // `Disputed` plus the real arbiter plus a non-empty rationale, which
        // the harness always supplies.
        if (escrow.getState(id) == EscrowUpgradeable.State.Disputed) {
            ghost_settleOpportunities += 1;
        }

        uint256 arbiterBefore = escrow.pendingWithdrawals(arb);

        (bool ok,) = actorOf(arb).exec(
            address(escrow),
            0,
            abi.encodeCall(EscrowUpgradeable.resolveDispute, (id, ruling, "fuzz rationale"))
        );

        if (ok) {
            if (escrow.pendingWithdrawals(arb) > arbiterBefore) fundsLeftTheParties = true;
            ghost_resolutions += 1;
            _observe(id);
        }
    }

    /// @notice Attempts a dispute resolution from that escrow's buyer, who is
    ///         never its arbiter, so this must always fail.
    function resolveDisputeUnauthorized(uint256 seed, bool sellerWins) public {
        (bool exists, uint256 id) = _pick(seed);
        if (!exists) return;

        (bool known, address b,,) = _partiesOf(id);
        if (!known || !isPoolActor[b]) return;

        EscrowUpgradeable.Ruling ruling =
            sellerWins ? EscrowUpgradeable.Ruling.SellerWins : EscrowUpgradeable.Ruling.BuyerWins;

        (bool ok,) = actorOf(b).exec(
            address(escrow),
            0,
            abi.encodeCall(EscrowUpgradeable.resolveDispute, (id, ruling, "unauthorized"))
        );

        // The buyer is never its own escrow's arbiter, so success here is a
        // broken guard.
        if (ok) fundsLeftTheParties = true;
    }

    /// @notice Withdraws for one of the pool actors.
    function withdraw(uint256 seed) public {
        Actor who = actorPool[seed % POOL_SIZE];
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
    ///      could hold a credit — the whole actor pool plus this harness — and
    ///      the locked half by walking every escrow this harness created. A bug
    ///      in `totalPendingWithdrawals` therefore cannot hide behind itself.
    function echidna_balance_equals_obligations() public view returns (bool) {
        uint256 credited = escrow.pendingWithdrawals(address(this));
        for (uint256 i = 0; i < actorPool.length; i++) {
            credited += escrow.pendingWithdrawals(address(actorPool[i]));
        }

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

    /// @notice INVARIANT (b): no settlement ever credits the arbiter of the
    ///         escrow it settles, and no non-arbiter can ever settle one.
    function echidna_arbiter_never_credited() public view returns (bool) {
        return !fundsLeftTheParties;
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

    /// @notice INVARIANT (d): a nullifier can settle at most one escrow, ever.
    function echidna_nullifier_never_reused() public view returns (bool) {
        return !nullifierReuseSeen;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Records a state observation and flags illegal transitions.
    function _observe(uint256 id) internal {
        EscrowUpgradeable.State prev = lastState[id];
        EscrowUpgradeable.State next = escrow.getState(id);

        if (!_isLegalTransition(prev, next)) invalidTransitionSeen = true;

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

    /// @dev Picks an escrow currently in `want`, scanning forward from the seed
    ///      so the choice is still seed-driven but cannot miss.
    /// @dev Used by `fund` alone. Funding is the single gateway to every
    ///      interesting state, and a uniform pick over every escrow ever
    ///      created gets steadily worse at finding the `Created` ones as a
    ///      sequence goes on — which starved whole runs of any funded escrow at
    ///      all. Every other entry point deliberately keeps the uniform pick,
    ///      because landing on an escrow in the wrong state is exactly how the
    ///      state guards get exercised.
    function _pickInState(uint256 seed, EscrowUpgradeable.State want)
        internal
        view
        returns (bool exists, uint256 id)
    {
        uint256 count = createdEscrows.length;
        if (count == 0) return (false, 0);

        uint256 start = seed % count;
        for (uint256 i = 0; i < count; i++) {
            uint256 candidate = createdEscrows[(start + i) % count];
            if (escrow.getState(candidate) == want) return (true, candidate);
        }
        return (false, 0);
    }

    /// @dev Reads an escrow's parties. `getEscrow` reverts for unknown ids, so
    ///      this swallows that rather than letting it surface to the engine.
    function _partiesOf(uint256 id)
        internal
        view
        returns (bool known, address buyer_, address seller_, address arbiter_)
    {
        try escrow.getEscrow(id) returns (EscrowUpgradeable.Escrow memory e) {
            return (true, e.buyer, e.seller, e.arbiter);
        } catch {
            return (false, address(0), address(0), address(0));
        }
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

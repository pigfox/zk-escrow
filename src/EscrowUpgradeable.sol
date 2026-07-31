// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IVerifier} from "./IVerifier.sol";

/// @title EscrowUpgradeable
/// @notice A UUPS-upgradeable buyer/seller/arbiter escrow whose happy-path
///         release is gated by a Groth16 proof of knowledge of a delivery
///         secret, and whose unhappy path is settled by a per-escrow arbiter.
/// @dev Design constraints that the test suite and fuzzers enforce:
///      - Funds are never pushed. Every settlement credits `pendingWithdrawals`
///        and the payee pulls via `withdraw()` (CEI + ReentrancyGuard).
///      - `resolveDispute` can only ever route an escrow's funds to that
///        escrow's buyer or seller. There is no code path that credits the
///        arbiter or any third address.
///      - Proofs are bound to a single escrow: the circuit derives the
///        nullifier from (secret, escrowId), and spent nullifiers are stored,
///        so a proof cannot be replayed across escrows or within one.
contract EscrowUpgradeable is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Lifecycle of a single escrow.
    /// @dev None is the zero value and means "does not exist".
    enum State {
        None,
        Created,
        Funded,
        Released,
        Refunded,
        Disputed,
        Resolved
    }

    /// @notice The only two outcomes an arbiter may hand down.
    /// @dev Deliberately not an address: the arbiter picks a side, never a
    ///      destination, so funds structurally cannot leave the buyer/seller
    ///      pair.
    enum Ruling {
        BuyerWins,
        SellerWins
    }

    /// @notice A single escrow agreement.
    struct Escrow {
        address buyer;
        address seller;
        address arbiter;
        uint256 amount;
        uint256 commitment;
        State state;
    }

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice A zero address was supplied where a real party is required.
    error ZeroAddress();
    /// @notice Buyer, seller and arbiter must be three distinct addresses.
    error DuplicateParty();
    /// @notice An escrow must be created for a non-zero amount.
    error ZeroAmount();
    /// @notice The referenced escrow has never been created.
    error EscrowDoesNotExist(uint256 escrowId);
    /// @notice The escrow is not in the state this action requires.
    error InvalidState(uint256 escrowId, State expected, State actual);
    /// @notice The caller is not permitted to take this action.
    error NotAuthorized(address caller);
    /// @notice `msg.value` did not exactly match the escrow amount.
    error IncorrectAmount(uint256 expected, uint256 actual);
    /// @notice The submitted Groth16 proof did not verify.
    error InvalidProof();
    /// @notice This nullifier has already been spent.
    error NullifierAlreadyUsed(uint256 nullifier);
    /// @notice Dispute evidence must not be empty.
    error EmptyEvidence();
    /// @notice A dispute ruling must carry a rationale.
    error EmptyRationale();
    /// @notice The caller has no balance to withdraw.
    error NothingToWithdraw(address caller);
    /// @notice The ETH transfer to the withdrawing party failed.
    error TransferFailed(address to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new escrow is created in state `Created`.
    /// @param escrowId The id assigned to this escrow; ids are sequential and never reused.
    /// @param buyer The account that created the escrow and is expected to fund it.
    /// @param seller The account that will be paid if a valid delivery proof is presented.
    /// @param arbiter The only account permitted to settle a dispute over THIS escrow.
    ///        It is a per-escrow party, not a role over the contract.
    /// @param amount The exact wei the buyer must send to `fund`; no other value is accepted.
    /// @param commitment The Poseidon commitment to the delivery secret. The secret itself
    ///        never appears on chain; `release` proves knowledge of it against this value.
    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        address arbiter,
        uint256 amount,
        uint256 commitment
    );

    /// @notice Emitted when the buyer funds the escrow, moving it to `Funded`.
    /// @param escrowId The escrow that was funded.
    /// @param buyer The account that sent the funds; always the escrow's recorded buyer.
    /// @param amount The wei received, always equal to the escrow's agreed amount.
    event EscrowFunded(uint256 indexed escrowId, address indexed buyer, uint256 amount);

    /// @notice Emitted when a valid delivery proof releases funds to the seller.
    /// @param escrowId The escrow that was released.
    /// @param seller The account credited; taken from the escrow, never from the caller,
    ///        which is why anyone may submit the proof without being able to redirect payment.
    /// @param amount The wei credited to the seller's pull-payment balance.
    /// @param nullifier The proof's nullifier, recorded so the same proof can never be
    ///        replayed against this or any other escrow.
    event EscrowReleased(uint256 indexed escrowId, address indexed seller, uint256 amount, uint256 nullifier);

    /// @notice Emitted when the seller refunds the buyer without a dispute.
    /// @param escrowId The escrow that was refunded.
    /// @param buyer The account credited with the returned funds.
    /// @param amount The wei returned, always the full escrowed amount.
    event EscrowRefunded(uint256 indexed escrowId, address indexed buyer, uint256 amount);

    /// @notice Emitted when either party escalates to the arbiter.
    /// @param escrowId The escrow moved into `Disputed`.
    /// @param raisedBy The party that escalated; either the buyer or the seller.
    /// @param evidence Free-form text emitted verbatim for the arbiter and any observer to read.
    event DisputeRaised(uint256 indexed escrowId, address indexed raisedBy, string evidence);

    /// @notice Emitted when the arbiter settles a dispute.
    /// @param escrowId The escrow that was settled.
    /// @param arbiter The account that ruled; always the escrow's named arbiter.
    /// @param ruling Which side won — `BuyerWins` or `SellerWins`. The arbiter picks a
    ///        side and never an address, so it cannot direct funds to itself.
    /// @param beneficiary The account credited as a result of the ruling.
    /// @param amount The wei credited to the beneficiary.
    /// @param rationale The arbiter's full reasoning, emitted verbatim so the
    ///        decision is auditable off-chain.
    event DisputeResolved(
        uint256 indexed escrowId,
        address indexed arbiter,
        Ruling ruling,
        address indexed beneficiary,
        uint256 amount,
        string rationale
    );

    /// @notice Emitted whenever an address's pull-payment balance increases.
    /// @param payee The account whose withdrawable balance grew.
    /// @param amount The wei added by this credit.
    /// @param newBalance The payee's total withdrawable balance after the credit, emitted
    ///        so an observer can reconcile without replaying every prior event.
    event WithdrawalCredited(address indexed payee, uint256 amount, uint256 newBalance);

    /// @notice Emitted when an address pulls its balance out.
    /// @param payee The account that withdrew.
    /// @param amount The wei actually transferred, always the payee's entire balance.
    event Withdrawn(address indexed payee, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Groth16 verifier for the delivery circuit.
    /// @dev    THERE IS DELIBERATELY NO `setVerifier`, AND ITS ABSENCE IS THE
    ///         TRUST MODEL — not an omission to be tidied up later.
    ///
    ///         This address is written once, by `initialize`, and no function in
    ///         this contract or in any upgrade may change it. A
    ///         `setVerifier(address) onlyOwner` would let the owner substitute a
    ///         verifier that returns true for any input, which converts the
    ///         demo's central claim — *release requires a valid zero-knowledge
    ///         proof of the delivery secret* — into *release requires the
    ///         owner's consent*. That is the exact property this contract exists
    ///         to demonstrate, so the setter is not a missing feature; adding it
    ///         would delete the feature.
    ///
    ///         The consequence is accepted knowingly: because the proxy cannot be
    ///         repointed, the verifier is effectively frozen for the life of this
    ///         deployment, and `src/Verifier.sol` is therefore kept exactly as
    ///         snarkjs generated it — unmodified, so its source keeps matching the
    ///         bytecode verified on Basescan. Ruled in PF-S123.
    IVerifier public verifier;

    /// @notice Monotonically increasing id of the next escrow to be created.
    uint256 public nextEscrowId;

    /// @notice All escrows by id.
    /// @dev `internal` (not `private`) so the V2 recovery implementation can add
    ///      an owner-only `setArbiter` by inheritance without duplicating or
    ///      reordering storage. Visibility only — same slot, same behaviour, and
    ///      the external API is unchanged (reads still go through getEscrow /
    ///      getState). See EscrowUpgradeableV2.
    mapping(uint256 escrowId => Escrow escrow) internal _escrows;

    /// @notice Pull-payment balances. The sum of these always equals the
    ///         contract's ETH balance.
    mapping(address payee => uint256 amount) public pendingWithdrawals;

    /// @notice Nullifiers already spent by a successful `release`.
    mapping(uint256 nullifier => bool spent) public nullifierUsed;

    /// @notice Total of all `pendingWithdrawals`, tracked for cheap invariant
    ///         checking against `address(this).balance`.
    uint256 public totalPendingWithdrawals;

    /// @dev Reserved storage so future versions can add state without shifting
    ///      the layout of this one.
    uint256[45] private __gap;

    /*//////////////////////////////////////////////////////////////
                              INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy.
    /// @param verifier_ The deployed Groth16 verifier.
    /// @param owner_ The address permitted to authorize UUPS upgrades.
    function initialize(address verifier_, address owner_) external initializer {
        if (verifier_ == address(0) || owner_ == address(0)) revert ZeroAddress();

        __UUPSUpgradeable_init();
        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        verifier = IVerifier(verifier_);
    }

    /*//////////////////////////////////////////////////////////////
                              STATE MACHINE
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates an escrow in state `Created`. Caller becomes the buyer.
    /// @param seller The party to be paid on a proven delivery.
    /// @param arbiter The party who may settle a dispute over this escrow.
    /// @param amount The exact amount the buyer must later fund.
    /// @param commitment Poseidon(secret) — the delivery secret's hash.
    /// @return escrowId The id of the newly created escrow.
    function createEscrow(address seller, address arbiter, uint256 amount, uint256 commitment)
        external
        returns (uint256 escrowId)
    {
        if (seller == address(0) || arbiter == address(0)) revert ZeroAddress();
        if (seller == msg.sender || arbiter == msg.sender || arbiter == seller) {
            revert DuplicateParty();
        }
        if (amount == 0) revert ZeroAmount();

        escrowId = nextEscrowId;
        nextEscrowId = escrowId + 1;

        _escrows[escrowId] = Escrow({
            buyer: msg.sender,
            seller: seller,
            arbiter: arbiter,
            amount: amount,
            commitment: commitment,
            state: State.Created
        });

        emit EscrowCreated(escrowId, msg.sender, seller, arbiter, amount, commitment);
    }

    /// @notice Funds a created escrow, moving it to `Funded`.
    /// @dev Only the buyer may fund, and `msg.value` must match exactly.
    /// @param escrowId The escrow to fund.
    function fund(uint256 escrowId) external payable {
        Escrow storage e = _requireEscrow(escrowId);
        _requireState(escrowId, e.state, State.Created);
        if (msg.sender != e.buyer) revert NotAuthorized(msg.sender);
        if (msg.value != e.amount) revert IncorrectAmount(e.amount, msg.value);

        e.state = State.Funded;

        emit EscrowFunded(escrowId, msg.sender, msg.value);
    }

    /// @notice Releases a funded escrow to the seller against a delivery proof.
    /// @dev Callable by anyone holding a valid proof — the proof, not the
    ///      caller, is the authorization. The nullifier is a circuit output
    ///      derived from (secret, escrowId), so a proof is usable exactly once
    ///      and only against the escrow it was generated for.
    /// @param escrowId The escrow to release.
    /// @param nullifier The circuit's nullifier output.
    /// @param pA Groth16 proof element A.
    /// @param pB Groth16 proof element B.
    /// @param pC Groth16 proof element C.
    function release(
        uint256 escrowId,
        uint256 nullifier,
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC
    ) external {
        Escrow storage e = _requireEscrow(escrowId);
        _requireState(escrowId, e.state, State.Funded);
        if (nullifierUsed[nullifier]) revert NullifierAlreadyUsed(nullifier);

        uint256[3] memory pubSignals = [nullifier, e.commitment, escrowId];
        if (!verifier.verifyProof(pA, pB, pC, pubSignals)) revert InvalidProof();

        nullifierUsed[nullifier] = true;
        e.state = State.Released;

        address seller = e.seller;
        uint256 amount = e.amount;
        _credit(seller, amount);

        emit EscrowReleased(escrowId, seller, amount, nullifier);
    }

    /// @notice Lets the seller hand the money back without a dispute.
    /// @param escrowId The escrow to refund.
    function refund(uint256 escrowId) external {
        Escrow storage e = _requireEscrow(escrowId);
        _requireState(escrowId, e.state, State.Funded);
        if (msg.sender != e.seller) revert NotAuthorized(msg.sender);

        e.state = State.Refunded;

        address buyer = e.buyer;
        uint256 amount = e.amount;
        _credit(buyer, amount);

        emit EscrowRefunded(escrowId, buyer, amount);
    }

    /// @notice Escalates a funded escrow to its arbiter.
    /// @dev Either party may raise. The evidence string is emitted (and so
    ///      lives in calldata + logs) rather than stored, which is what the
    ///      off-chain agent reads.
    /// @param escrowId The escrow to dispute.
    /// @param evidence The raising party's account of the dispute.
    function raiseDispute(uint256 escrowId, string calldata evidence) external {
        Escrow storage e = _requireEscrow(escrowId);
        _requireState(escrowId, e.state, State.Funded);
        if (msg.sender != e.buyer && msg.sender != e.seller) revert NotAuthorized(msg.sender);
        if (bytes(evidence).length == 0) revert EmptyEvidence();

        e.state = State.Disputed;

        emit DisputeRaised(escrowId, msg.sender, evidence);
    }

    /// @notice Lets either party add further evidence to an open dispute.
    /// @param escrowId The disputed escrow.
    /// @param evidence Additional evidence, emitted for the arbiter to read.
    function submitEvidence(uint256 escrowId, string calldata evidence) external {
        Escrow storage e = _requireEscrow(escrowId);
        _requireState(escrowId, e.state, State.Disputed);
        if (msg.sender != e.buyer && msg.sender != e.seller) revert NotAuthorized(msg.sender);
        if (bytes(evidence).length == 0) revert EmptyEvidence();

        emit DisputeRaised(escrowId, msg.sender, evidence);
    }

    /// @notice Settles a dispute. Arbiter-only, `Disputed`-only.
    /// @dev The beneficiary is derived from the ruling and can only be this
    ///      escrow's buyer or seller — there is no parameter, and no branch,
    ///      that lets funds reach the arbiter or a third party.
    /// @param escrowId The disputed escrow.
    /// @param ruling Which side wins.
    /// @param rationale The arbiter's reasoning, emitted in full.
    function resolveDispute(uint256 escrowId, Ruling ruling, string calldata rationale) external {
        Escrow storage e = _requireEscrow(escrowId);
        _requireState(escrowId, e.state, State.Disputed);
        if (msg.sender != e.arbiter) revert NotAuthorized(msg.sender);
        if (bytes(rationale).length == 0) revert EmptyRationale();

        e.state = State.Resolved;

        address beneficiary = ruling == Ruling.BuyerWins ? e.buyer : e.seller;
        uint256 amount = e.amount;
        _credit(beneficiary, amount);

        emit DisputeResolved(escrowId, msg.sender, ruling, beneficiary, amount, rationale);
    }

    /*//////////////////////////////////////////////////////////////
                              PULL PAYMENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraws the caller's accumulated balance.
    /// @dev CEI: the balance is zeroed before the external call, and the whole
    ///      function is additionally guarded against reentrancy.
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw(msg.sender);

        pendingWithdrawals[msg.sender] = 0;
        totalPendingWithdrawals -= amount;

        emit Withdrawn(msg.sender, amount);

        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns a full escrow record.
    /// @param escrowId The escrow to read.
    /// @return The escrow struct.
    function getEscrow(uint256 escrowId) external view returns (Escrow memory) {
        return _requireEscrow(escrowId);
    }

    /// @notice Returns the lifecycle state of an escrow.
    /// @dev Unlike `getEscrow`, this does not revert for unknown ids; it
    ///      returns `State.None`.
    /// @param escrowId The escrow to read.
    /// @return The escrow's state.
    function getState(uint256 escrowId) external view returns (State) {
        return _escrows[escrowId].state;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Credits a payee's pull-payment balance and keeps the running total
    ///      in step, so `totalPendingWithdrawals == address(this).balance`.
    function _credit(address payee, uint256 amount) private {
        uint256 newBalance = pendingWithdrawals[payee] + amount;
        pendingWithdrawals[payee] = newBalance;
        totalPendingWithdrawals += amount;

        emit WithdrawalCredited(payee, amount, newBalance);
    }

    /// @dev Loads an escrow, reverting if it was never created.
    function _requireEscrow(uint256 escrowId) private view returns (Escrow storage e) {
        e = _escrows[escrowId];
        if (e.state == State.None) revert EscrowDoesNotExist(escrowId);
    }

    /// @dev Asserts an escrow is in the expected state.
    function _requireState(uint256 escrowId, State actual, State expected) private pure {
        if (actual != expected) revert InvalidState(escrowId, expected, actual);
    }

    /// @notice Authorises a UUPS implementation upgrade. Owner-only.
    /// @dev The proxy's entire upgrade authority is this one modifier. It gates the
    ///      implementation address, never the escrow rules: an upgrade cannot repoint
    ///      the verifier (there is no setter — see the `verifier` field) and cannot
    ///      redirect an existing escrow's funds, because payouts read parties from
    ///      storage rather than from the caller.
    /// @param newImplementation The implementation the proxy will delegate to. Rejected if
    ///        zero, which would otherwise brick the proxy irrecoverably.
    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        if (newImplementation == address(0)) revert ZeroAddress();
    }
}

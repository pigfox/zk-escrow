// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EscrowUpgradeable} from "../src/EscrowUpgradeable.sol";
import {Groth16Verifier} from "../src/Verifier.sol";

/// @title ZkReleaseTest
/// @notice Exercises `release()` against the REAL generated Groth16 verifier,
///         using proofs produced once by `scripts/prove.sh` and checked in
///         under `test/fixtures/`.
/// @dev Both fixtures use the same secret (12345) but different escrow ids, so
///      they share a commitment and differ in nullifier. That is exactly the
///      property the replay tests need.
contract ZkReleaseTest is Test {
    struct ProofFixture {
        uint256 escrowId;
        uint256 commitment;
        uint256 nullifier;
        uint256[2] pA;
        uint256[2][2] pB;
        uint256[2] pC;
    }

    EscrowUpgradeable internal escrow;
    Groth16Verifier internal verifier;

    address internal owner = makeAddr("owner");
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal arbiter = makeAddr("arbiter");

    uint256 internal constant AMOUNT = 1 ether;

    ProofFixture internal fixture0;
    ProofFixture internal fixture1;

    function setUp() public {
        verifier = new Groth16Verifier();

        EscrowUpgradeable impl = new EscrowUpgradeable();
        bytes memory initData = abi.encodeCall(EscrowUpgradeable.initialize, (address(verifier), owner));
        escrow = EscrowUpgradeable(address(new ERC1967Proxy(address(impl), initData)));

        vm.deal(buyer, 100 ether);

        fixture0 = _loadFixture("test/fixtures/delivery-proof-escrow0.json");
        fixture1 = _loadFixture("test/fixtures/delivery-proof-escrow1.json");
    }

    /*//////////////////////////////////////////////////////////////
                            FIXTURE INTEGRITY
    //////////////////////////////////////////////////////////////*/

    function test_Fixtures_ShareCommitmentButNotNullifier() public view {
        assertEq(fixture0.commitment, fixture1.commitment, "same secret, same commitment");
        assertTrue(fixture0.nullifier != fixture1.nullifier, "nullifier is escrow-bound");
        assertEq(fixture0.escrowId, 0, "fixture 0 escrowId");
        assertEq(fixture1.escrowId, 1, "fixture 1 escrowId");
    }

    function test_Verifier_AcceptsFixtureProof() public view {
        uint256[3] memory pubSignals = [fixture0.nullifier, fixture0.commitment, fixture0.escrowId];
        assertTrue(verifier.verifyProof(fixture0.pA, fixture0.pB, fixture0.pC, pubSignals), "valid");
    }

    function test_Verifier_RejectsTamperedPublicSignals() public view {
        uint256[3] memory tampered = [fixture0.nullifier, fixture0.commitment + 1, fixture0.escrowId];
        assertFalse(verifier.verifyProof(fixture0.pA, fixture0.pB, fixture0.pC, tampered), "invalid");
    }

    /*//////////////////////////////////////////////////////////////
                            REAL RELEASE PATH
    //////////////////////////////////////////////////////////////*/

    function test_Release_WithRealProof() public {
        uint256 escrowId = _createAndFund(fixture0.commitment);
        assertEq(escrowId, fixture0.escrowId, "fixture targets escrow 0");

        escrow.release(escrowId, fixture0.nullifier, fixture0.pA, fixture0.pB, fixture0.pC);

        assertTrue(escrow.getState(escrowId) == EscrowUpgradeable.State.Released, "released");
        assertEq(escrow.pendingWithdrawals(seller), AMOUNT, "seller credited");
        assertTrue(escrow.nullifierUsed(fixture0.nullifier), "nullifier spent");

        vm.prank(seller);
        escrow.withdraw();
        assertEq(seller.balance, AMOUNT, "seller paid out");
    }

    function test_Release_RejectsProofFromAnotherEscrow() public {
        // Escrow 0 exists with the shared commitment; try to settle it with the
        // proof generated for escrow 1. The nullifier and escrowId no longer
        // agree with what the circuit committed to, so verification fails.
        uint256 escrowId = _createAndFund(fixture0.commitment);

        vm.expectRevert(EscrowUpgradeable.InvalidProof.selector);
        escrow.release(escrowId, fixture1.nullifier, fixture1.pA, fixture1.pB, fixture1.pC);
    }

    function test_Release_RejectsProofAgainstWrongCommitment() public {
        uint256 escrowId = _createAndFund(fixture0.commitment + 1);

        vm.expectRevert(EscrowUpgradeable.InvalidProof.selector);
        escrow.release(escrowId, fixture0.nullifier, fixture0.pA, fixture0.pB, fixture0.pC);
    }

    function test_Release_RejectsMismatchedNullifier() public {
        uint256 escrowId = _createAndFund(fixture0.commitment);

        vm.expectRevert(EscrowUpgradeable.InvalidProof.selector);
        escrow.release(escrowId, fixture0.nullifier + 1, fixture0.pA, fixture0.pB, fixture0.pC);
    }

    function test_Release_RejectsGarbageProof() public {
        uint256 escrowId = _createAndFund(fixture0.commitment);

        uint256[2] memory badA = [uint256(1), uint256(2)];
        uint256[2][2] memory badB = [[uint256(3), uint256(4)], [uint256(5), uint256(6)]];
        uint256[2] memory badC = [uint256(7), uint256(8)];

        vm.expectRevert(EscrowUpgradeable.InvalidProof.selector);
        escrow.release(escrowId, fixture0.nullifier, badA, badB, badC);
    }

    /// @dev Both fixtures are valid for their own escrow, and each is spendable
    ///      exactly once. This is the end-to-end anti-replay statement.
    function test_Release_EachProofSettlesExactlyItsOwnEscrow() public {
        uint256 escrow0 = _createAndFund(fixture0.commitment);
        uint256 escrow1 = _createAndFund(fixture1.commitment);
        assertEq(escrow1, fixture1.escrowId, "fixture targets escrow 1");

        escrow.release(escrow0, fixture0.nullifier, fixture0.pA, fixture0.pB, fixture0.pC);
        escrow.release(escrow1, fixture1.nullifier, fixture1.pA, fixture1.pB, fixture1.pC);

        assertEq(escrow.pendingWithdrawals(seller), 2 * AMOUNT, "both settled");
    }

    /*//////////////////////////////////////////////////////////////
                         VERIFIER EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /// @dev The BN254 scalar field modulus. Public signals must be reduced mod
    ///      r; the verifier's `checkField` rejects anything at or above it.
    uint256 internal constant SCALAR_FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    function test_Verifier_RejectsOutOfRangeNullifier() public view {
        uint256[3] memory bad = [SCALAR_FIELD, fixture0.commitment, fixture0.escrowId];
        assertFalse(verifier.verifyProof(fixture0.pA, fixture0.pB, fixture0.pC, bad), "rejected");
    }

    function test_Verifier_RejectsOutOfRangeCommitment() public view {
        uint256[3] memory bad = [fixture0.nullifier, SCALAR_FIELD + 1, fixture0.escrowId];
        assertFalse(verifier.verifyProof(fixture0.pA, fixture0.pB, fixture0.pC, bad), "rejected");
    }

    function test_Verifier_RejectsOutOfRangeEscrowId() public view {
        uint256[3] memory bad = [fixture0.nullifier, fixture0.commitment, type(uint256).max];
        assertFalse(verifier.verifyProof(fixture0.pA, fixture0.pB, fixture0.pC, bad), "rejected");
    }

    /// @dev A point that is not on the curve makes the ecAdd/ecMul precompile
    ///      fail, which is a different rejection path from a well-formed but
    ///      wrong proof.
    function test_Verifier_RejectsOffCurvePoint() public view {
        uint256[2] memory offCurveA = [uint256(1), uint256(3)];
        uint256[3] memory pubSignals = [fixture0.nullifier, fixture0.commitment, fixture0.escrowId];
        assertFalse(verifier.verifyProof(offCurveA, fixture0.pB, fixture0.pC, pubSignals), "rejected");
    }

    function test_Verifier_RejectsZeroProof() public view {
        uint256[2] memory zeroA;
        uint256[2][2] memory zeroB;
        uint256[2] memory zeroC;
        uint256[3] memory pubSignals = [fixture0.nullifier, fixture0.commitment, fixture0.escrowId];
        assertFalse(verifier.verifyProof(zeroA, zeroB, zeroC, pubSignals), "rejected");
    }

    /// @dev The escrow surfaces every verifier rejection as `InvalidProof`,
    ///      whatever the underlying reason.
    function test_Release_RevertsOnOutOfRangeNullifier() public {
        uint256 escrowId = _createAndFund(fixture0.commitment);
        vm.expectRevert(EscrowUpgradeable.InvalidProof.selector);
        escrow.release(escrowId, SCALAR_FIELD, fixture0.pA, fixture0.pB, fixture0.pC);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _createAndFund(uint256 commitment) internal returns (uint256 escrowId) {
        vm.prank(buyer);
        escrowId = escrow.createEscrow(seller, arbiter, AMOUNT, commitment);
        vm.prank(buyer);
        escrow.fund{value: AMOUNT}(escrowId);
    }

    /// @dev Fixture JSON stores every field element as a 0x-prefixed 32-byte
    ///      hex string. Decimal is not usable here: forge's JSON reader coerces
    ///      long numeric strings and mangles values above 2^64.
    function _loadFixture(string memory path) internal view returns (ProofFixture memory f) {
        string memory json = vm.readFile(path);

        f.escrowId = _word(json, ".escrowId");
        f.commitment = _word(json, ".commitment");
        f.nullifier = _word(json, ".nullifier");

        uint256[] memory a = _words(json, ".pA");
        f.pA = [a[0], a[1]];

        uint256[] memory b0 = _words(json, ".pB[0]");
        uint256[] memory b1 = _words(json, ".pB[1]");
        f.pB = [[b0[0], b0[1]], [b1[0], b1[1]]];

        uint256[] memory c = _words(json, ".pC");
        f.pC = [c[0], c[1]];
    }

    /// @dev Reads one 0x-prefixed 32-byte field element. forge's JSON reader
    ///      types full-width hex strings as bytes32, not string.
    function _word(string memory json, string memory path) internal pure returns (uint256) {
        return uint256(abi.decode(vm.parseJson(json, path), (bytes32)));
    }

    /// @dev Reads an array of 32-byte field elements.
    function _words(string memory json, string memory path) internal pure returns (uint256[] memory out) {
        bytes32[] memory raw = abi.decode(vm.parseJson(json, path), (bytes32[]));
        out = new uint256[](raw.length);
        for (uint256 i = 0; i < raw.length; i++) {
            out[i] = uint256(raw[i]);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EscrowUpgradeable} from "../src/EscrowUpgradeable.sol";
import {EscrowUpgradeableV2} from "../src/EscrowUpgradeableV2.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";

/// @title SetArbiterTest
/// @notice Full-branch coverage for the V2 recovery function `setArbiter`, plus
///         two fuzzed properties: a rotation never moves funds, and only the
///         owner can ever rotate.
contract SetArbiterTest is Test {
    EscrowUpgradeableV2 internal escrow;
    MockVerifier internal verifier;

    address internal owner = makeAddr("owner");
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal arbiter = makeAddr("arbiter");
    address internal newArbiter = makeAddr("newArbiter");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant AMOUNT = 1 ether;
    uint256 internal constant COMMITMENT = uint256(keccak256("delivery-secret"));

    event ArbiterRotated(uint256 indexed escrowId, address indexed oldArbiter, address indexed newArbiter);

    function setUp() public {
        verifier = new MockVerifier();
        EscrowUpgradeableV2 impl = new EscrowUpgradeableV2();
        bytes memory initData = abi.encodeCall(EscrowUpgradeable.initialize, (address(verifier), owner));
        escrow = EscrowUpgradeableV2(address(new ERC1967Proxy(address(impl), initData)));
        vm.deal(buyer, 100 ether);
    }

    // --- helpers ---------------------------------------------------------------

    function _create() internal returns (uint256 id) {
        vm.prank(buyer);
        id = escrow.createEscrow(seller, arbiter, AMOUNT, COMMITMENT);
    }

    function _createAndFund() internal returns (uint256 id) {
        id = _create();
        vm.prank(buyer);
        escrow.fund{value: AMOUNT}(id);
    }

    function _createFundAndDispute() internal returns (uint256 id) {
        id = _createAndFund();
        vm.prank(buyer);
        escrow.raiseDispute(id, "goods never arrived");
    }

    // --- happy path ------------------------------------------------------------

    function test_SetArbiter_RotatesDisputedEscrow() public {
        uint256 id = _createFundAndDispute();
        assertEq(escrow.getEscrow(id).arbiter, arbiter, "arbiter before");

        vm.expectEmit(true, true, true, false);
        emit ArbiterRotated(id, arbiter, newArbiter);
        vm.prank(owner);
        escrow.setArbiter(id, newArbiter);

        assertEq(escrow.getEscrow(id).arbiter, newArbiter, "arbiter rotated");
        // Everything else on the escrow is untouched.
        EscrowUpgradeable.Escrow memory e = escrow.getEscrow(id);
        assertEq(e.buyer, buyer);
        assertEq(e.seller, seller);
        assertEq(e.amount, AMOUNT);
        assertTrue(e.state == EscrowUpgradeable.State.Disputed, "still disputed");
    }

    /// @notice After rotation the NEW arbiter can settle, and funds route to the
    ///         ruled side — never the arbiter (the invariant the guard preserves).
    function test_SetArbiter_RotatedArbiterCanSettle() public {
        uint256 id = _createFundAndDispute();
        vm.prank(owner);
        escrow.setArbiter(id, newArbiter);

        // Old arbiter can no longer settle.
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.NotAuthorized.selector, arbiter));
        escrow.resolveDispute(id, EscrowUpgradeable.Ruling.SellerWins, "old arbiter is out");

        // New arbiter settles; the seller (not the arbiter) is credited.
        vm.prank(newArbiter);
        escrow.resolveDispute(id, EscrowUpgradeable.Ruling.SellerWins, "delivery proven off-chain");
        assertTrue(escrow.getState(id) == EscrowUpgradeable.State.Resolved, "resolved");
        assertEq(escrow.pendingWithdrawals(seller), AMOUNT, "seller credited");
        assertEq(escrow.pendingWithdrawals(newArbiter), 0, "arbiter never credited");
    }

    // --- revert branches -------------------------------------------------------

    function test_SetArbiter_RevertsForNonOwner() public {
        uint256 id = _createFundAndDispute();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        escrow.setArbiter(id, newArbiter);
    }

    function test_SetArbiter_RevertsForNonexistentEscrow() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.EscrowDoesNotExist.selector, 42));
        escrow.setArbiter(42, newArbiter);
    }

    function test_SetArbiter_RevertsOnZeroArbiter() public {
        uint256 id = _createFundAndDispute();
        vm.prank(owner);
        vm.expectRevert(EscrowUpgradeable.ZeroAddress.selector);
        escrow.setArbiter(id, address(0));
    }

    function test_SetArbiter_RevertsWhenNewArbiterIsBuyer() public {
        uint256 id = _createFundAndDispute();
        vm.prank(owner);
        vm.expectRevert(EscrowUpgradeable.DuplicateParty.selector);
        escrow.setArbiter(id, buyer);
    }

    function test_SetArbiter_RevertsWhenNewArbiterIsSeller() public {
        uint256 id = _createFundAndDispute();
        vm.prank(owner);
        vm.expectRevert(EscrowUpgradeable.DuplicateParty.selector);
        escrow.setArbiter(id, seller);
    }

    function test_SetArbiter_RevertsWhenNotDisputed() public {
        // Funded (exists, not Disputed) -> InvalidState.
        uint256 id = _createAndFund();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowUpgradeable.InvalidState.selector,
                id,
                EscrowUpgradeable.State.Disputed,
                EscrowUpgradeable.State.Funded
            )
        );
        escrow.setArbiter(id, newArbiter);
    }

    // --- fuzzed properties -----------------------------------------------------

    /// @notice Only the owner can ever rotate — grief with arbitrary callers.
    function testFuzz_SetArbiter_OnlyOwnerCanRotate(address caller) public {
        vm.assume(caller != owner);
        uint256 id = _createFundAndDispute();
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", caller));
        escrow.setArbiter(id, newArbiter);
        // The arbiter is unchanged after any non-owner attempt.
        assertEq(escrow.getEscrow(id).arbiter, arbiter, "arbiter unchanged by non-owner");
    }

    /// @notice A rotation never moves funds: the contract balance and every
    ///         pull-payment total are identical before and after.
    function testFuzz_SetArbiter_NeverMovesFunds(address rotateTo) public {
        vm.assume(rotateTo != address(0) && rotateTo != buyer && rotateTo != seller);
        uint256 id = _createFundAndDispute();

        uint256 balBefore = address(escrow).balance;
        uint256 totalBefore = escrow.totalPendingWithdrawals();
        uint256 buyerBefore = escrow.pendingWithdrawals(buyer);
        uint256 sellerBefore = escrow.pendingWithdrawals(seller);

        vm.prank(owner);
        escrow.setArbiter(id, rotateTo);

        assertEq(address(escrow).balance, balBefore, "contract balance unchanged");
        assertEq(escrow.totalPendingWithdrawals(), totalBefore, "total unchanged");
        assertEq(escrow.pendingWithdrawals(buyer), buyerBefore, "buyer credit unchanged");
        assertEq(escrow.pendingWithdrawals(seller), sellerBefore, "seller credit unchanged");
        assertEq(escrow.pendingWithdrawals(rotateTo), 0, "rotated-to never credited");
    }
}

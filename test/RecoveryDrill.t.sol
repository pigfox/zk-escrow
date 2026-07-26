// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EscrowUpgradeable} from "../src/EscrowUpgradeable.sol";
import {EscrowUpgradeableV2} from "../src/EscrowUpgradeableV2.sol";
import {Groth16Verifier} from "../src/Verifier.sol";

/// @title RecoveryDrillTest
/// @notice The recovery rehearsal as a PURE-EVM regression test: deploy V1, take an
///         escrow to Disputed under an arbiter whose key is lost, then upgrade to V2,
///         rotate the arbiter, and settle.
/// @dev This replaces the old ForkRotationTest, which forked live Base Sepolia state.
///      Nothing here forks (see the NO-FORK DOCTRINE in CLAUDE.md): the drill builds
///      its own world from scratch, which makes it deterministic, free, and runnable
///      in CI with no RPC access at all.
///
///      Its on-chain twin is script/RecoveryDrill.s.sol, which performs the identical
///      sequence against Base Sepolia using throwaway contracts. This test is what
///      guarantees the sequence stays correct; the script is what proves it against a
///      real chain on demand.
contract RecoveryDrillTest is Test {
    EscrowUpgradeableV2 internal escrow;

    address internal owner = makeAddr("owner");
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    /// @dev The arbiter whose key was lost — assigned at creation, never able to sign.
    address internal staleArbiter = makeAddr("staleArbiter");
    address internal freshArbiter = makeAddr("freshArbiter");

    uint256 internal constant AMOUNT = 0.01 ether;
    uint256 internal constant COMMITMENT = 1234567890;

    bytes32 internal constant DISPUTE_RESOLVED_SIG =
        keccak256("DisputeResolved(uint256,address,uint8,address,uint256,string)");

    function setUp() public {
        Groth16Verifier verifier = new Groth16Verifier();
        EscrowUpgradeable implementation = new EscrowUpgradeable();
        bytes memory initData = abi.encodeCall(EscrowUpgradeable.initialize, (address(verifier), owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        escrow = EscrowUpgradeableV2(address(proxy));

        vm.deal(buyer, 10 ether);
    }

    /// @dev Takes a fresh escrow all the way to Disputed under the stale arbiter.
    function _disputedEscrow() internal returns (uint256 id) {
        vm.prank(buyer);
        id = EscrowUpgradeable(address(escrow)).createEscrow(seller, staleArbiter, AMOUNT, COMMITMENT);

        vm.prank(buyer);
        EscrowUpgradeable(address(escrow)).fund{value: AMOUNT}(id);

        vm.prank(buyer);
        EscrowUpgradeable(address(escrow)).raiseDispute(id, "goods never arrived");

        EscrowUpgradeable.Escrow memory e = EscrowUpgradeable(address(escrow)).getEscrow(id);
        assertTrue(e.state == EscrowUpgradeable.State.Disputed, "precondition: escrow is Disputed");
        assertEq(e.arbiter, staleArbiter, "precondition: still the stale arbiter");
    }

    /// @dev Upgrades the live proxy to V2 as the owner. The whole point of the drill:
    ///      V1 has no setArbiter, so recovery is impossible without this step.
    function _upgradeToV2() internal {
        EscrowUpgradeableV2 v2 = new EscrowUpgradeableV2();
        vm.prank(owner);
        escrow.upgradeToAndCall(address(v2), "");
    }

    function test_drill_sellerWins() public {
        uint256 id = _disputedEscrow();
        _upgradeToV2();

        vm.prank(owner);
        escrow.setArbiter(id, freshArbiter);
        assertEq(
            EscrowUpgradeable(address(escrow)).getEscrow(id).arbiter, freshArbiter, "arbiter rotated"
        );

        uint256 sellerBefore = EscrowUpgradeable(address(escrow)).pendingWithdrawals(seller);
        uint256 buyerBefore = EscrowUpgradeable(address(escrow)).pendingWithdrawals(buyer);

        vm.recordLogs();
        vm.prank(freshArbiter);
        EscrowUpgradeable(address(escrow)).resolveDispute(
            id, EscrowUpgradeable.Ruling.SellerWins, "delivery evidence accepted"
        );

        // The ruled side is credited, the other side untouched.
        assertEq(
            EscrowUpgradeable(address(escrow)).pendingWithdrawals(seller) - sellerBefore,
            AMOUNT,
            "seller credited the full amount"
        );
        assertEq(
            EscrowUpgradeable(address(escrow)).pendingWithdrawals(buyer), buyerBefore, "buyer untouched"
        );
        assertTrue(
            EscrowUpgradeable(address(escrow)).getEscrow(id).state == EscrowUpgradeable.State.Resolved,
            "escrow reached Resolved"
        );

        _assertDisputeResolved(freshArbiter, seller);
    }

    function test_drill_buyerWins() public {
        uint256 id = _disputedEscrow();
        _upgradeToV2();

        vm.prank(owner);
        escrow.setArbiter(id, freshArbiter);

        uint256 buyerBefore = EscrowUpgradeable(address(escrow)).pendingWithdrawals(buyer);
        uint256 sellerBefore = EscrowUpgradeable(address(escrow)).pendingWithdrawals(seller);

        vm.recordLogs();
        vm.prank(freshArbiter);
        EscrowUpgradeable(address(escrow)).resolveDispute(
            id, EscrowUpgradeable.Ruling.BuyerWins, "no delivery evidence supplied"
        );

        assertEq(
            EscrowUpgradeable(address(escrow)).pendingWithdrawals(buyer) - buyerBefore,
            AMOUNT,
            "buyer credited the full amount"
        );
        assertEq(
            EscrowUpgradeable(address(escrow)).pendingWithdrawals(seller), sellerBefore, "seller untouched"
        );
        assertTrue(
            EscrowUpgradeable(address(escrow)).getEscrow(id).state == EscrowUpgradeable.State.Resolved,
            "escrow reached Resolved"
        );

        _assertDisputeResolved(freshArbiter, buyer);
    }

    /// @notice Rotation is owner-only — a stranger cannot hand themselves the gavel.
    function test_setArbiter_onlyOwner() public {
        uint256 id = _disputedEscrow();
        _upgradeToV2();

        vm.prank(buyer);
        vm.expectRevert();
        escrow.setArbiter(id, buyer);
    }

    /// @notice After rotation the OLD arbiter is powerless. If this ever passed, the
    ///         recovery would not actually be a recovery.
    function test_staleArbiterCannotResolveAfterRotation() public {
        uint256 id = _disputedEscrow();
        _upgradeToV2();

        vm.prank(owner);
        escrow.setArbiter(id, freshArbiter);

        vm.prank(staleArbiter);
        vm.expectRevert();
        EscrowUpgradeable(address(escrow)).resolveDispute(
            id, EscrowUpgradeable.Ruling.SellerWins, "should not be allowed"
        );
    }

    /// @notice V1 has no setArbiter at all — the reason the upgrade is load-bearing.
    function test_v1HasNoSetArbiter() public {
        uint256 id = _disputedEscrow();
        (bool ok,) = address(escrow).call(abi.encodeWithSignature("setArbiter(uint256,address)", id, freshArbiter));
        assertFalse(ok, "V1 must not expose setArbiter");
    }

    /// @dev Asserts exactly one DisputeResolved fired, naming the arbiter and beneficiary.
    function _assertDisputeResolved(address expectedArbiter, address expectedBeneficiary) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != DISPUTE_RESOLVED_SIG) continue;
            found++;
            assertEq(address(uint160(uint256(logs[i].topics[2]))), expectedArbiter, "event names the arbiter");
            assertEq(
                address(uint160(uint256(logs[i].topics[3]))), expectedBeneficiary, "event names the beneficiary"
            );
        }
        assertEq(found, 1, "exactly one DisputeResolved");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {BaseTest} from "./Base.t.sol";
import {EscrowUpgradeable} from "../src/EscrowUpgradeable.sol";
import {EscrowV2} from "./mocks/EscrowV2.sol";

/// @title UpgradeTest
/// @notice Exercises `_authorizeUpgrade` and proves state survives the swap.
contract UpgradeTest is BaseTest {
    /// @dev ERC-1967 implementation slot.
    bytes32 internal constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function test_Upgrade_ByOwnerSucceeds() public {
        EscrowV2 v2 = new EscrowV2();

        vm.prank(owner);
        escrow.upgradeToAndCall(address(v2), "");

        assertEq(_implementation(), address(v2), "implementation swapped");
        assertEq(EscrowV2(address(escrow)).version(), 2, "V2 code live");
    }

    function test_Upgrade_PreservesState() public {
        // Write state through V1: one live escrow and one pending credit.
        uint256 funded = _createAndFund();
        uint256 released = _createAndFund();
        _release(released, NULLIFIER);

        assertEq(escrow.pendingWithdrawals(seller), AMOUNT, "credited pre-upgrade");

        EscrowV2 v2 = new EscrowV2();
        vm.prank(owner);
        escrow.upgradeToAndCall(address(v2), abi.encodeCall(EscrowV2.initializeV2, ("v2")));

        EscrowV2 upgraded = EscrowV2(address(escrow));

        // Old state reads back identically through the new layout.
        assertEq(upgraded.versionTag(), "v2", "new state written");
        assertEq(upgraded.pendingWithdrawals(seller), AMOUNT, "credit survived");
        assertEq(upgraded.totalPendingWithdrawals(), AMOUNT, "total survived");
        assertEq(upgraded.nextEscrowId(), 2, "counter survived");
        assertTrue(upgraded.nullifierUsed(NULLIFIER), "nullifier survived");
        assertTrue(upgraded.getState(funded) == EscrowUpgradeable.State.Funded, "state survived");
        assertTrue(upgraded.getState(released) == EscrowUpgradeable.State.Released, "state survived");

        EscrowUpgradeable.Escrow memory e = upgraded.getEscrow(funded);
        assertEq(e.buyer, buyer, "buyer survived");
        assertEq(e.seller, seller, "seller survived");
        assertEq(e.arbiter, arbiter, "arbiter survived");
        assertEq(e.amount, AMOUNT, "amount survived");

        // And the escrow still works after the upgrade.
        vm.prank(seller);
        upgraded.withdraw();
        assertEq(seller.balance, AMOUNT, "withdraw works post-upgrade");
    }

    function test_Upgrade_RevertsForNonOwner() public {
        EscrowV2 v2 = new EscrowV2();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger)
        );
        escrow.upgradeToAndCall(address(v2), "");
    }

    function test_Upgrade_RevertsForBuyerAndArbiter() public {
        EscrowV2 v2 = new EscrowV2();

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, buyer)
        );
        escrow.upgradeToAndCall(address(v2), "");

        vm.prank(arbiter);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, arbiter)
        );
        escrow.upgradeToAndCall(address(v2), "");
    }

    /// @dev `_authorizeUpgrade` rejects the zero implementation before OZ gets
    ///      a chance to, which is the branch this covers.
    function test_Upgrade_RevertsOnZeroImplementation() public {
        vm.prank(owner);
        vm.expectRevert(EscrowUpgradeable.ZeroAddress.selector);
        escrow.upgradeToAndCall(address(0), "");
    }

    /// @dev An EOA passes the zero-address guard but fails the UUPS
    ///      `proxiableUUID()` probe, which reverts without return data because
    ///      the call to a codeless address yields nothing to decode.
    function test_Upgrade_RevertsOnNonContractImplementation() public {
        address notAContract = makeAddr("notAContract");
        vm.prank(owner);
        vm.expectRevert();
        escrow.upgradeToAndCall(notAContract, "");
    }

    /// @dev UUPS forbids calling the entry point on the implementation itself.
    function test_Upgrade_RevertsWhenCalledOnImplementation() public {
        EscrowUpgradeable impl = new EscrowUpgradeable();
        EscrowV2 v2 = new EscrowV2();

        vm.expectRevert();
        impl.upgradeToAndCall(address(v2), "");
    }

    function test_Upgrade_OwnershipTransferGatesFutureUpgrades() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        escrow.transferOwnership(newOwner);

        EscrowV2 v2 = new EscrowV2();

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner)
        );
        escrow.upgradeToAndCall(address(v2), "");

        vm.prank(newOwner);
        escrow.upgradeToAndCall(address(v2), "");
        assertEq(_implementation(), address(v2), "new owner could upgrade");
    }

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(escrow), IMPL_SLOT))));
    }
}

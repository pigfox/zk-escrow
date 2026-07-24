// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EscrowUpgradeable} from "../src/EscrowUpgradeable.sol";
import {EscrowUpgradeableV2} from "../src/EscrowUpgradeableV2.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";

/// @title SetArbiterHandler
/// @notice Drives `setArbiter` under the invariant engine from BOTH the owner and
///         arbitrary non-owner callers over a pool of pre-seeded disputed escrows.
///         It never resolves anything, so all funded ETH stays locked and any
///         change to the contract balance could only come from a rotation — which
///         must never move funds.
contract SetArbiterHandler is Test {
    EscrowUpgradeableV2 public escrow;
    address public owner;
    uint256[] public ids;
    bool public nonOwnerRotated;
    uint256 public ownerRotations;

    constructor(EscrowUpgradeableV2 e, address o) {
        escrow = e;
        owner = o;
    }

    /// @dev Seeds one funded+disputed escrow with three distinct derived parties.
    function seedDisputed(uint256 s) external {
        address b = address(uint160(uint256(keccak256(abi.encode(s, "buyer")))));
        address sell = address(uint160(uint256(keccak256(abi.encode(s, "seller")))));
        address arb = address(uint160(uint256(keccak256(abi.encode(s, "arbiter")))));
        vm.deal(b, 1 ether);
        vm.prank(b);
        uint256 id = escrow.createEscrow(sell, arb, 1 ether, s + 1);
        vm.prank(b);
        escrow.fund{value: 1 ether}(id);
        vm.prank(b);
        escrow.raiseDispute(id, "seed evidence");
        ids.push(id);
    }

    /// @notice Owner rotates a disputed escrow to a fresh distinct address.
    function rotateAsOwner(uint256 idxSeed, uint256 addrSeed) external {
        if (ids.length == 0) return;
        uint256 id = ids[idxSeed % ids.length];
        EscrowUpgradeable.Escrow memory e = escrow.getEscrow(id);
        address newArb = address(uint160(uint256(keccak256(abi.encode(addrSeed, "new")))));
        if (newArb == address(0) || newArb == e.buyer || newArb == e.seller) return;
        vm.prank(owner);
        escrow.setArbiter(id, newArb);
        ownerRotations++;
    }

    /// @notice Any non-owner attempts a rotation; a SUCCESS sets the sticky flag.
    function rotateAsNonOwner(uint256 idxSeed, address caller) external {
        if (ids.length == 0 || caller == owner) return;
        uint256 id = ids[idxSeed % ids.length];
        vm.prank(caller);
        try escrow.setArbiter(id, address(0xBEEF)) {
            nonOwnerRotated = true;
        } catch {}
    }
}

/// @title SetArbiterInvariantTest
/// @notice The two invariants the brief names, under the Foundry invariant engine:
///         a rotation never moves funds, and only the owner can ever rotate.
contract SetArbiterInvariantTest is Test {
    EscrowUpgradeableV2 internal escrow;
    SetArbiterHandler internal handler;
    address internal owner = makeAddr("owner");

    uint256 internal constant SEED_COUNT = 3;
    uint256 internal lockedBalance; // ETH locked in funded-but-unsettled escrows

    function setUp() public {
        MockVerifier verifier = new MockVerifier();
        EscrowUpgradeableV2 impl = new EscrowUpgradeableV2();
        escrow = EscrowUpgradeableV2(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(EscrowUpgradeable.initialize, (address(verifier), owner))
                )
            )
        );
        handler = new SetArbiterHandler(escrow, owner);
        for (uint256 i = 0; i < SEED_COUNT; i++) {
            handler.seedDisputed(i);
        }
        lockedBalance = address(escrow).balance; // SEED_COUNT ether, none resolved

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = SetArbiterHandler.rotateAsOwner.selector;
        selectors[1] = SetArbiterHandler.rotateAsNonOwner.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice A rotation never moves funds: the contract balance stays exactly the
    ///         seeded locked total, and nothing is ever credited to a payee.
    function invariant_RotationNeverMovesFunds() public view {
        assertEq(address(escrow).balance, lockedBalance, "rotation changed the contract balance");
        assertEq(escrow.totalPendingWithdrawals(), 0, "rotation credited a payee");
    }

    /// @notice No non-owner rotation ever succeeds.
    function invariant_OnlyOwnerCanRotate() public view {
        assertFalse(handler.nonOwnerRotated(), "a non-owner rotated an arbiter");
    }

    /// @notice Proves the run was not inert: at least one owner rotation landed.
    function afterInvariant() public view {
        assertGt(handler.ownerRotations(), 0, "no owner rotation ever executed");
    }
}

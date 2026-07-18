// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EscrowUpgradeable} from "../src/EscrowUpgradeable.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";

/// @title BaseTest
/// @notice Shared fixture: a proxied escrow wired to a mock verifier, plus the
///         three named parties every test needs.
abstract contract BaseTest is Test {
    EscrowUpgradeable internal escrow;
    MockVerifier internal verifier;

    address internal owner = makeAddr("owner");
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal arbiter = makeAddr("arbiter");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant AMOUNT = 1 ether;
    uint256 internal constant COMMITMENT = uint256(keccak256("delivery-secret"));
    uint256 internal constant NULLIFIER = uint256(keccak256("nullifier"));

    // Dummy proof elements. The MockVerifier ignores them; the real verifier is
    // exercised in ZkRelease.t.sol against checked-in fixtures.
    uint256[2] internal pA = [uint256(1), uint256(2)];
    uint256[2][2] internal pB = [[uint256(3), uint256(4)], [uint256(5), uint256(6)]];
    uint256[2] internal pC = [uint256(7), uint256(8)];

    function setUp() public virtual {
        verifier = new MockVerifier();

        EscrowUpgradeable impl = new EscrowUpgradeable();
        bytes memory initData =
            abi.encodeCall(EscrowUpgradeable.initialize, (address(verifier), owner));
        escrow = EscrowUpgradeable(address(new ERC1967Proxy(address(impl), initData)));

        vm.deal(buyer, 100 ether);
        vm.deal(stranger, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Creates an escrow as `buyer`, in state Created.
    function _create() internal returns (uint256 escrowId) {
        vm.prank(buyer);
        escrowId = escrow.createEscrow(seller, arbiter, AMOUNT, COMMITMENT);
    }

    /// @dev Creates and funds an escrow, leaving it in state Funded.
    function _createAndFund() internal returns (uint256 escrowId) {
        escrowId = _create();
        vm.prank(buyer);
        escrow.fund{value: AMOUNT}(escrowId);
    }

    /// @dev Creates, funds and disputes an escrow, leaving it in state Disputed.
    function _createFundAndDispute() internal returns (uint256 escrowId) {
        escrowId = _createAndFund();
        vm.prank(buyer);
        escrow.raiseDispute(escrowId, "goods never arrived");
    }

    /// @dev Calls release with the dummy proof.
    function _release(uint256 escrowId, uint256 nullifier) internal {
        escrow.release(escrowId, nullifier, pA, pB, pC);
    }
}

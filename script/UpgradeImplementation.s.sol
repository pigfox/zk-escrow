// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {EscrowUpgradeable} from "../src/EscrowUpgradeable.sol";

/// @title UpgradeImplementation
/// @notice Deploys a fresh `EscrowUpgradeable` implementation and points the LIVE
///         proxy at it, preserving the proxy address and every escrow it holds.
/// @dev THE PROXY IS NEVER REPLACED. That is the entire reason this contract is
///      upgradeable: the proxy holds the escrows, the settlement history and the
///      nullifier set, and replacing it would throw all of that away to fix a
///      source change that alters no behaviour.
///
///      Storage layout is unchanged by construction — this upgrade carries only
///      natspec — so `upgradeToAndCall` is called with EMPTY calldata. There is no
///      reinitializer to run, and passing one would be a state write dressed up as
///      an upgrade.
///
///      Guards, in order: right chain, a proxy that actually has code, an
///      implementation that differs from the one already installed (so a no-op
///      upgrade cannot be mistaken for a successful one), and a post-upgrade read
///      of the ERC-1967 slot to prove the swap landed.
///
///      DIRECT-CHAIN ONLY: chain 84532 required below, no alternate endpoint.
///
/// @dev Env:
///        DEMO_DEPLOYER_PK — must be the proxy's owner; `_authorizeUpgrade` is
///                           onlyOwner and will revert for anyone else.
///        ESCROW_PROXY     — the live proxy to upgrade.
contract UpgradeImplementation is Script {
    /// @dev ERC-1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1.
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        require(block.chainid == 84532, "Upgrade: not Base Sepolia (84532)");

        uint256 pk = vm.envUint("DEMO_DEPLOYER_PK");
        address proxy = vm.envAddress("ESCROW_PROXY");
        require(proxy.code.length > 0, "Upgrade: no code at ESCROW_PROXY");

        address before = address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
        uint256 escrowsBefore = EscrowUpgradeable(proxy).nextEscrowId();

        vm.startBroadcast(pk);
        EscrowUpgradeable implementation = new EscrowUpgradeable();
        require(address(implementation) != before, "Upgrade: implementation is already installed");
        EscrowUpgradeable(proxy).upgradeToAndCall(address(implementation), "");
        vm.stopBroadcast();

        address installed = address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
        require(installed == address(implementation), "Upgrade: implementation slot did not change");

        // The whole point of upgrading rather than redeploying: the escrows survive.
        require(EscrowUpgradeable(proxy).nextEscrowId() == escrowsBefore, "Upgrade: escrow count changed");

        console2.log("proxy              ", proxy);
        console2.log("implementation was ", before);
        console2.log("implementation now ", installed);
        console2.log("escrows preserved  ", escrowsBefore);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EscrowUpgradeable} from "../src/EscrowUpgradeable.sol";
import {Groth16Verifier} from "../src/Verifier.sol";

/// @title Deploy
/// @notice Deploys the verifier, the escrow implementation and an initialized
///         ERC-1967 proxy to Base Sepolia.
/// @dev The chain id is asserted, not assumed. This script refuses to run
///      anywhere except Base Sepolia, so a stray --rpc-url cannot put a
///      demo-grade trusted setup on a network that matters.
contract Deploy is Script {
    /// @notice Base Sepolia. The only network this script will deploy to.
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;

    /// @notice Thrown when run against any other chain.
    error WrongChain(uint256 expected, uint256 actual);

    function run() external {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) {
            revert WrongChain(BASE_SEPOLIA_CHAIN_ID, block.chainid);
        }

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        Groth16Verifier verifier = new Groth16Verifier();
        EscrowUpgradeable implementation = new EscrowUpgradeable();

        bytes memory initData = abi.encodeCall(
            EscrowUpgradeable.initialize, (address(verifier), deployer)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        vm.stopBroadcast();

        // Never log the key itself — only the address it derives to.
        console2.log("=== zk-escrow deployed to Base Sepolia ===");
        console2.log("chain id:       ", block.chainid);
        console2.log("deployer/owner: ", deployer);
        console2.log("Verifier:       ", address(verifier));
        console2.log("Implementation: ", address(implementation));
        console2.log("Proxy (USE THIS):", address(proxy));
        console2.log("");
        console2.log("Add to ../.env for the demo scripts and the agent:");
        console2.log("  ESCROW_ADDRESS=", address(proxy));
    }
}

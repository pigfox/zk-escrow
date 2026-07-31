// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EscrowUpgradeable} from "../src/EscrowUpgradeable.sol";
import {EscrowUpgradeableV2} from "../src/EscrowUpgradeableV2.sol";
import {Groth16Verifier} from "../src/Verifier.sol";

/// @title RecoveryDrill
/// @notice The arbiter-recovery rehearsal, run for real against Base Sepolia.
///
///         Deploys a THROWAWAY V1 proxy, takes an escrow to Disputed under an arbiter
///         it then abandons, and drives the recovery: upgrade to V2 → rotate the
///         arbiter → settle. Every assertion the retired rotation test made is made
///         here, on a real chain, with real gas.
///
/// @dev This replaces the retired rotation test, which pointed the EVM at a local
///      copy of live Base Sepolia state to rehearse an upgrade against the
///      PRODUCTION proxy. That is now banned outright (see the DIRECT-CHAIN
///      DOCTRINE in CLAUDE.md): rehearsing against production was only ever safe
///      because the copy discarded the writes.
///
///      This script is structurally safe instead of conditionally safe: it deploys
///      its own proxy in the first broadcast and never learns the address of the
///      live one, so it CANNOT touch the demo the site reads. Its deterministic
///      twin is test/RecoveryDrill.t.sol, which proves the same sequence in pure EVM
///      on every `forge test`.
///
///      Gated on RECOVERY_DRILL=true so a stray `forge script` cannot spend. Run it
///      deliberately:
///
///        RECOVERY_DRILL=true forge script script/RecoveryDrill.s.sol:RecoveryDrill \
///          --rpc-url "$DEMO_RPC_URL" --broadcast -vv
contract RecoveryDrill is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;

    /// @notice Dust: large enough to be a real value transfer the contract accounts
    ///         for, small enough that the drill costs almost nothing to repeat.
    uint256 internal constant AMOUNT = 0.00001 ether;
    uint256 internal constant COMMITMENT = 1234567890123456789012345678901234567890;

    error WrongChain(uint256 expected, uint256 actual);
    error DrillNotEnabled();

    function run() external {
        if (!vm.envOr("RECOVERY_DRILL", false)) revert DrillNotEnabled();
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) {
            revert WrongChain(BASE_SEPOLIA_CHAIN_ID, block.chainid);
        }

        uint256 deployerKey = vm.envUint("DEMO_DEPLOYER_PK");
        uint256 arbiterKey = vm.envUint("DEMO_ARBITER_PK");
        address deployer = vm.addr(deployerKey);
        address freshArbiter = vm.addr(arbiterKey);
        // The seller is a party, never a signer, in this drill.
        address seller = vm.envAddress("DEMO_INVESTOR_B_ADDR");
        // The arbiter we deliberately abandon — stands in for the lost key.
        address staleArbiter = vm.envAddress("DEMO_OPERATOR_ADDR");

        // === 1. throwaway world ============================================
        vm.startBroadcast(deployerKey);
        Groth16Verifier verifier = new Groth16Verifier();
        EscrowUpgradeable implementation = new EscrowUpgradeable();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(EscrowUpgradeable.initialize, (address(verifier), deployer))
        );
        EscrowUpgradeable escrow = EscrowUpgradeable(address(proxy));

        // === 2. an escrow stuck in Disputed under an arbiter nobody can sign as ===
        uint256 id = escrow.createEscrow(seller, staleArbiter, AMOUNT, COMMITMENT);
        escrow.fund{value: AMOUNT}(id);
        escrow.raiseDispute(id, "recovery drill: goods never arrived");
        vm.stopBroadcast();

        EscrowUpgradeable.Escrow memory pre = escrow.getEscrow(id);
        require(pre.state == EscrowUpgradeable.State.Disputed, "drill: escrow is not Disputed");
        require(pre.arbiter == staleArbiter, "drill: arbiter is not the stale one");

        // === 3. the recovery: upgrade, rotate, settle =======================
        vm.startBroadcast(deployerKey);
        EscrowUpgradeableV2 v2 = new EscrowUpgradeableV2();
        EscrowUpgradeableV2(address(proxy)).upgradeToAndCall(address(v2), "");
        EscrowUpgradeableV2(address(proxy)).setArbiter(id, freshArbiter);
        vm.stopBroadcast();

        require(escrow.getEscrow(id).arbiter == freshArbiter, "drill: arbiter did not rotate");

        uint256 sellerBefore = escrow.pendingWithdrawals(seller);

        vm.startBroadcast(arbiterKey);
        escrow.resolveDispute(
            id, EscrowUpgradeable.Ruling.SellerWins, "recovery drill: delivery evidence accepted"
        );
        vm.stopBroadcast();

        // === 4. the assertions the retired rotation test used to make =======
        require(
            escrow.pendingWithdrawals(seller) - sellerBefore == AMOUNT,
            "drill: seller was not credited the amount"
        );
        require(
            escrow.getEscrow(id).state == EscrowUpgradeable.State.Resolved, "drill: state is not Resolved"
        );

        console2.log("=== recovery drill PASSED on Base Sepolia ===");
        console2.log("throwaway proxy: ", address(proxy));
        console2.log("escrow id:       ", id);
        console2.log("stale arbiter:   ", staleArbiter);
        console2.log("fresh arbiter:   ", freshArbiter);
        console2.log("seller credited: ", AMOUNT);
    }
}

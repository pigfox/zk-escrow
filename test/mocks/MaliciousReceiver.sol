// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EscrowUpgradeable} from "../../src/EscrowUpgradeable.sol";

/// @title MaliciousReceiver
/// @notice A seller that tries to reenter `withdraw()` from its receive hook.
/// @dev Two independent defences should stop it: `withdraw()` zeroes the
///      balance before making the external call (CEI), and the function carries
///      `nonReentrant`. The reentrancy test asserts the guard fires, and that
///      the attacker still nets exactly one payout rather than draining the
///      other escrows' funds.
contract MaliciousReceiver {
    /// @notice The escrow under attack.
    EscrowUpgradeable public immutable ESCROW;

    /// @notice How many times the receive hook has fired.
    uint256 public reentryAttempts;

    /// @notice Whether the reentrant `withdraw()` call reverted, as expected.
    bool public reentryReverted;

    /// @notice Raw revert data from the reentrant call, for assertions.
    bytes public lastRevertData;

    /// @notice Set false to make the receiver reject ETH outright, which
    ///         exercises the `TransferFailed` path.
    bool public acceptEth = true;

    constructor(EscrowUpgradeable escrow_) {
        ESCROW = escrow_;
    }

    /// @notice Toggles whether this contract accepts ETH at all.
    function setAcceptEth(bool value) external {
        acceptEth = value;
    }

    /// @notice Creates an escrow with this contract as the buyer.
    function createEscrow(address seller, address arbiter, uint256 amount, uint256 commitment)
        external
        returns (uint256)
    {
        return ESCROW.createEscrow(seller, arbiter, amount, commitment);
    }

    /// @notice Funds an escrow from this contract.
    function fund(uint256 escrowId) external payable {
        ESCROW.fund{value: msg.value}(escrowId);
    }

    /// @notice Raises a dispute from this contract.
    function raiseDispute(uint256 escrowId, string calldata evidence) external {
        ESCROW.raiseDispute(escrowId, evidence);
    }

    /// @notice Kicks off the attack.
    function attack() external {
        ESCROW.withdraw();
    }

    /// @dev The hook the escrow's payout lands in. Reenters exactly once so the
    ///      test can observe a single, contained failure rather than an
    ///      unbounded loop.
    receive() external payable {
        if (!acceptEth) revert("receiver rejects ETH");

        if (reentryAttempts == 0) {
            reentryAttempts = 1;
            try ESCROW.withdraw() {
                // Reaching here would mean the guard failed.
                reentryReverted = false;
            } catch (bytes memory err) {
                reentryReverted = true;
                lastRevertData = err;
            }
        }
    }
}

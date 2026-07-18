// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EscrowUpgradeable} from "../../src/EscrowUpgradeable.sol";

/// @title EscrowV2
/// @notice A dummy next version used to exercise the UUPS upgrade path.
/// @dev It appends state after the inherited layout to prove the storage gap
///      does its job: everything written through V1 must still read back
///      correctly through V2.
contract EscrowV2 is EscrowUpgradeable {
    /// @notice New state introduced by V2.
    string public versionTag;

    /// @notice Reinitializes the proxy after the upgrade.
    function initializeV2(string calldata tag) external reinitializer(2) {
        versionTag = tag;
    }

    /// @notice Marker so tests can prove the implementation actually swapped.
    function version() external pure returns (uint256) {
        return 2;
    }
}

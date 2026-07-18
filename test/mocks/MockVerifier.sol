// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVerifier} from "../../src/IVerifier.sol";

/// @title MockVerifier
/// @notice A verifier stand-in for tests that need to drive the escrow state
///         machine without generating a real Groth16 proof.
/// @dev The real generated `Verifier.sol` is exercised separately in
///      `test/ZkRelease.t.sol` against a checked-in fixture proof. This mock
///      exists so the rest of the suite does not have to carry a valid proof
///      through every path.
contract MockVerifier is IVerifier {
    /// @notice What `verifyProof` should return.
    bool public shouldVerify = true;

    /// @notice Flips the verdict the mock hands back.
    function setShouldVerify(bool value) external {
        shouldVerify = value;
    }

    /// @inheritdoc IVerifier
    function verifyProof(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[3] calldata
    ) external view returns (bool) {
        return shouldVerify;
    }
}

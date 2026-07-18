// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Actor
/// @notice A minimal forwarder standing in for one party in the fuzz harness.
/// @dev Echidna and Medusa have no `prank` cheatcode, so the harness needs real
///      distinct `msg.sender`s. Each party is one of these, and the harness
///      drives them through `exec`. Reverts are surfaced as `ok == false`
///      rather than propagated, so a rejected call just ends that fuzz step
///      instead of unwinding the whole sequence.
contract Actor {
    /// @notice Forwards a call, reporting success instead of bubbling reverts.
    /// @param target The contract to call.
    /// @param value Wei to attach.
    /// @param data Calldata to send.
    /// @return ok Whether the call succeeded.
    /// @return ret The raw return data.
    function exec(address target, uint256 value, bytes calldata data)
        external
        returns (bool ok, bytes memory ret)
    {
        (ok, ret) = target.call{value: value}(data);
    }

    receive() external payable {}
}

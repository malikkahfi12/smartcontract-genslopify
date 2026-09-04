// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MockMultisig
/// @notice A minimal contract-with-code used as an `admin` stand-in for handover tests.
/// @dev Deliberately NOT a real multisig: it has no signers and no quorum. Its only relevant
///      property is that `code.length > 0`, which is what the router's one-way latch checks
///      (research R-003). This is exactly why that check proves "is a contract" and NOT
///      "is a multisig" — this mock would satisfy it while being controlled by anyone.
contract MockMultisig {
    /// @notice Forward an arbitrary call, simulating a multisig executing an approved action.
    function execute(address target, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        require(ok, "MockMultisig: call failed");
        return ret;
    }

    receive() external payable {}
}

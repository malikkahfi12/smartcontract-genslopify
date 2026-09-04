// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ForceSender
/// @notice Pushes native funds into a target that has no way to refuse them.
/// @dev `selfdestruct` transfers the remaining balance without invoking the target's code, so the
///      target cannot reject it. Used to prove INV-9 / 001 FR-008: forced funds must never affect
///      accounting, because the router never reads its own balance.
///
///      Under Cancun (EIP-6780, and Arc testnet is Cancun per the T082 probe) SELFDESTRUCT only
///      deletes the account when the contract was created in the same transaction; otherwise it
///      merely transfers the balance. Either way the *balance transfer* still happens and cannot
///      be refused, which is the property this mock exists to exercise.
///
///      Written in assembly because the high-level `selfdestruct` emits a deprecation warning and
///      the build runs with `deny = "warnings"`. The behaviour is identical.
contract ForceSender {
    constructor() payable {}

    /// @notice Destroy this contract and force its balance onto `target`.
    /// @param target The address that will receive this contract's entire balance.
    function forceSend(address payable target) external {
        assembly {
            selfdestruct(target)
        }
    }
}

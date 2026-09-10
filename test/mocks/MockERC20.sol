// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MockERC20
/// @notice The smallest token that can be mis-sent to the router.
/// @dev Exists only to prove 003 FR-017c: a token transferred to the router is stranded forever.
///      Deliberately minimal — the router has no token surface, so nothing here needs to be
///      realistic beyond `transfer` and `balanceOf`.
contract MockERC20 {
    string public constant name = "Mock";
    string public constant symbol = "MOCK";
    uint8 public constant decimals = 18;

    mapping(address account => uint256 amount) public balanceOf;

    constructor(address holder, uint256 supply) {
        balanceOf[holder] = supply;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

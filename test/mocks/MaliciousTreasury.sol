// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ITopUpRouterMinimal {
    function topUp(address beneficiary) external payable;
}

/// @title MaliciousTreasury
/// @notice A configurable hostile treasury used to attack the payout path.
/// @dev Covers the native-transfer threat classes from research R-001: a recipient that reverts,
///      one that burns all forwarded gas, and one that re-enters `topUp` on receipt. Used by
///      test/attack/Reentrancy.t.sol and test/attack/DoSGriefing.t.sol.
contract MaliciousTreasury {
    enum Mode {
        Accept, // behaves like a normal contract treasury
        Revert, // rejects the transfer outright
        BurnGas, // consumes all forwarded gas
        Reenter // calls back into topUp
    }

    Mode public mode;
    address public router;
    address public reenterBeneficiary;
    uint256 public receivedCount;
    uint256 public reenterAttempts;

    constructor(Mode initialMode) {
        mode = initialMode;
    }

    function setMode(Mode newMode) external {
        mode = newMode;
    }

    function setRouter(address newRouter, address beneficiary) external {
        router = newRouter;
        reenterBeneficiary = beneficiary;
    }

    receive() external payable {
        receivedCount += 1;

        if (mode == Mode.Revert) {
            revert("MaliciousTreasury: refusing funds");
        }

        if (mode == Mode.BurnGas) {
            // Spin until the forwarded gas is exhausted.
            uint256 i;
            while (true) {
                i += 1;
                assembly {
                    mstore(0x00, i)
                }
            }
        }

        if (mode == Mode.Reenter && router != address(0)) {
            reenterAttempts += 1;
            // Re-enter with a fraction of the received value. Expected to revert on the guard.
            ITopUpRouterMinimal(router).topUp{value: msg.value / 2}(reenterBeneficiary);
        }
    }
}

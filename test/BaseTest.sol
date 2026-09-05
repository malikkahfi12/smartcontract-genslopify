// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../src/TopUpRouter.sol";
import {ForceSender} from "./mocks/ForceSender.sol";
import {MaliciousTreasury} from "./mocks/MaliciousTreasury.sol";
import {Test} from "forge-std/Test.sol";

/// @title BaseTest
/// @notice Shared harness: named actors, a deployed router, and fund helpers.
/// @dev Every suite inherits this so actor identities and the deployment shape stay consistent.
///      There are no role actors here because the contract has no roles (003 FR-014). `stranger`
///      and `attacker` exist to prove that point: every suite that uses them asserts they can do
///      exactly what anyone else can, no more and no less.
abstract contract BaseTest is Test {
    TopUpRouter internal router;

    // Actors. `treasury` is an EOA, matching the testnet scope decision.
    address internal treasury = makeAddr("treasury");
    address internal payer = makeAddr("payer");
    address internal beneficiary = makeAddr("beneficiary");
    address internal attacker = makeAddr("attacker");
    address internal stranger = makeAddr("stranger");

    /// @dev Native USDC on Arc has 6 decimals: `1e6` base units is one whole USDC, NOT `1e18`
    ///      (research R-001). Every amount in the test suite is at this scale.
    uint256 internal constant MIN_TOPUP = 1e6;
    uint256 internal constant STARTING_BALANCE = 1000e6;

    function setUp() public virtual {
        router = new TopUpRouter(treasury);

        vm.deal(payer, STARTING_BALANCE);
        vm.deal(attacker, STARTING_BALANCE);
        vm.deal(stranger, STARTING_BALANCE);

        // Start at a realistic timestamp. Nothing in the contract depends on time any more, which
        // is itself worth holding steady across suites.
        vm.warp(1_800_000_000);
    }

    /// @notice Force native funds into `target` with no way for it to refuse (INV-9).
    function forceFundsInto(address target, uint256 amount) internal {
        ForceSender sender = new ForceSender{value: amount}();
        sender.forceSend(payable(target));
    }

    /// @notice Deploy a hostile treasury in the given mode.
    function deployMaliciousTreasury(MaliciousTreasury.Mode mode)
        internal
        returns (MaliciousTreasury)
    {
        return new MaliciousTreasury(mode);
    }
}

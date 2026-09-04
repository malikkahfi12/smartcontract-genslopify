// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../src/TopUpRouter.sol";
import {ForceSender} from "./mocks/ForceSender.sol";
import {MaliciousTreasury} from "./mocks/MaliciousTreasury.sol";
import {MockMultisig} from "./mocks/MockMultisig.sol";
import {Test} from "forge-std/Test.sol";

/// @title BaseTest
/// @notice Shared harness: named actors, a deployed router, and time helpers.
/// @dev Every suite inherits this so actor identities and the deployment shape stay consistent.
abstract contract BaseTest is Test {
    TopUpRouter internal router;

    // Actors. `treasury` is an EOA, matching the testnet scope decision (spec Q5 -> B).
    address internal treasury = makeAddr("treasury");
    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal payer = makeAddr("payer");
    address internal beneficiary = makeAddr("beneficiary");
    address internal attacker = makeAddr("attacker");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant MIN_TOPUP = 1e18;
    uint256 internal constant DELAY = 2 days;
    uint256 internal constant STARTING_BALANCE = 1000e18;

    function setUp() public virtual {
        router = new TopUpRouter(treasury, admin, pauser, MIN_TOPUP);

        vm.deal(payer, STARTING_BALANCE);
        vm.deal(attacker, STARTING_BALANCE);
        vm.deal(stranger, STARTING_BALANCE);

        // Start at a realistic timestamp so `block.timestamp - DELAY` never underflows.
        vm.warp(1_800_000_000);
    }

    /// @notice Advance exactly the governance delay, landing on the first applicable second.
    function warpPastDelay() internal {
        vm.warp(block.timestamp + DELAY);
    }

    /// @notice Advance to one second before a pending change becomes applicable.
    function warpToJustBeforeEta(uint256 eta) internal {
        vm.warp(eta - 1);
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

    /// @notice Deploy a contract-with-code to stand in as a multisig admin.
    function deployMockMultisig() internal returns (MockMultisig) {
        return new MockMultisig();
    }
}

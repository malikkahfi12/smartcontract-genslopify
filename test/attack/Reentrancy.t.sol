// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../src/TopUpRouter.sol";
import {BaseTest} from "../BaseTest.sol";
import {MaliciousTreasury} from "../mocks/MaliciousTreasury.sol";

/// @title ReentrancyAttackTest
/// @notice 001 FR-025: a hostile treasury must not be able to re-enter topUp.
/// @dev Each test ATTEMPTS an exploit and asserts it FAILS (constitution Principle II).
contract ReentrancyAttackTest is BaseTest {
    MaliciousTreasury internal evil;

    function setUp() public override {
        super.setUp();
        evil = deployMaliciousTreasury(MaliciousTreasury.Mode.Reenter);
        router = new TopUpRouter(address(evil));
        evil.setRouter(address(router), attacker);
    }

    /// @notice ATTACK: treasury re-enters topUp on receipt. Must fail, crediting nobody twice.
    function test_AttackFails_ReentrantTreasuryCannotDoubleCredit() public {
        vm.prank(payer);
        vm.expectRevert(TopUpRouter.TreasuryTransferFailed.selector);
        router.topUp{value: 10e6}(beneficiary);

        assertEq(router.totalRouted(), 0, "no funds routed");
        assertEq(router.contributions(beneficiary), 0, "beneficiary not credited");
        assertEq(router.contributions(attacker), 0, "attacker not credited");
        assertEq(address(router).balance, 0, "router holds nothing");
    }

    /// @notice The whole transaction is atomic: a blocked reentry leaves zero trace (001 FR-026).
    function test_AttackFails_StateIsUnchangedAfterBlockedReentry() public {
        uint256 payerBefore = payer.balance;

        vm.prank(payer);
        vm.expectRevert(TopUpRouter.TreasuryTransferFailed.selector);
        router.topUp{value: 10e6}(beneficiary);

        assertEq(payer.balance, payerBefore, "payer keeps their funds");
        assertEq(address(evil).balance, 0, "treasury received nothing");
    }

    /// @notice A well-behaved contract treasury must still work; the guard is not a blanket ban.
    function test_HonestContractTreasuryStillSucceeds() public {
        evil.setMode(MaliciousTreasury.Mode.Accept);

        vm.prank(payer);
        router.topUp{value: 10e6}(beneficiary);

        assertEq(address(evil).balance, 10e6, "honest contract treasury receives funds");
        assertEq(router.contributions(beneficiary), 10e6, "credited");
    }
}

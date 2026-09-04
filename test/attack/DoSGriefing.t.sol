// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../src/TopUpRouter.sol";
import {BaseTest} from "../BaseTest.sol";
import {MaliciousTreasury} from "../mocks/MaliciousTreasury.sol";

/// @title DoSGriefingAttackTest
/// @notice 001 edge cases: a treasury that refuses funds or burns gas must fail CLEANLY.
/// @dev The requirement is not that these succeed - a broken treasury genuinely cannot be paid.
///      The requirement is that the failure is atomic: no credit, no stranded funds, no
///      inconsistent state. The user loses gas, never principal.
contract DoSGriefingAttackTest is BaseTest {
    MaliciousTreasury internal evil;

    function setUp() public override {
        super.setUp();
        evil = deployMaliciousTreasury(MaliciousTreasury.Mode.Revert);
        router = new TopUpRouter(address(evil), admin, pauser, MIN_TOPUP);
    }

    /// @notice ATTACK: treasury reverts on receipt.
    function test_AttackFails_RevertingTreasuryFailsCleanly() public {
        uint256 payerBefore = payer.balance;

        vm.prank(payer);
        vm.expectRevert(TopUpRouter.TreasuryTransferFailed.selector);
        router.topUp{value: 10e18}(beneficiary);

        assertEq(router.contributions(beneficiary), 0, "no credit granted");
        assertEq(router.totalRouted(), 0, "nothing routed");
        assertEq(address(router).balance, 0, "no funds stranded in router");
        assertEq(payer.balance, payerBefore, "payer keeps principal");
    }

    /// @notice ATTACK: treasury burns every unit of forwarded gas.
    function test_AttackFails_GasBurningTreasuryFailsCleanly() public {
        evil.setMode(MaliciousTreasury.Mode.BurnGas);

        vm.prank(payer);
        vm.expectRevert(TopUpRouter.TreasuryTransferFailed.selector);
        router.topUp{value: 10e18}(beneficiary);

        assertEq(router.contributions(beneficiary), 0, "no credit granted");
        assertEq(address(router).balance, 0, "no funds stranded");
    }

    /// @notice Recovery: once the treasury behaves, top-ups work again with no residue.
    function test_RecoversOnceTreasuryBehaves() public {
        vm.prank(payer);
        vm.expectRevert(TopUpRouter.TreasuryTransferFailed.selector);
        router.topUp{value: 10e18}(beneficiary);

        evil.setMode(MaliciousTreasury.Mode.Accept);

        vm.prank(payer);
        router.topUp{value: 10e18}(beneficiary);

        assertEq(router.contributions(beneficiary), 10e18, "credited exactly once");
        assertEq(router.totalRouted(), 10e18, "routed exactly once");
    }
}

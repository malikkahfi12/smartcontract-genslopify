// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../src/TopUpRouter.sol";
import {BaseTest} from "../BaseTest.sol";

/// @title PauserRotationTest
/// @notice T054: the pauser address is itself changeable by admin under the same 2-day delay.
contract PauserRotationTest is BaseTest {
    address internal newPauser = makeAddr("newPauser");

    function test_ProposePauserSetsPendingWithTwoDayEta() public {
        vm.prank(admin);
        router.proposePauser(newPauser);

        (address target, uint64 eta) = router.pendingPauser();
        assertEq(target, newPauser, "pending pauser");
        assertEq(eta, block.timestamp + DELAY, "same 2-day delay");
    }

    function test_RevertWhen_ApplyPauserBeforeDelay() public {
        vm.prank(admin);
        router.proposePauser(newPauser);
        (, uint64 eta) = router.pendingPauser();

        warpToJustBeforeEta(eta);
        vm.expectRevert(
            abi.encodeWithSelector(TopUpRouter.TimelockNotElapsed.selector, block.timestamp, eta)
        );
        router.applyPauser();
        assertEq(router.pauser(), pauser, "pauser unchanged");
    }

    function test_ApplyPauserAfterDelay() public {
        vm.prank(admin);
        router.proposePauser(newPauser);
        warpPastDelay();
        router.applyPauser();

        assertEq(router.pauser(), newPauser, "pauser rotated");
    }

    function test_CancelPauserClearsPending() public {
        vm.startPrank(admin);
        router.proposePauser(newPauser);
        router.cancelPauser();
        vm.stopPrank();

        (address target,) = router.pendingPauser();
        assertEq(target, address(0), "cleared");
        assertEq(router.pauser(), pauser, "unchanged");
    }

    function test_RevertWhen_NonAdminProposesPauser() public {
        vm.prank(pauser);
        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.proposePauser(attacker);

        vm.prank(attacker);
        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.proposePauser(attacker);
    }

    function test_RevertWhen_ProposePauserZeroOrSelf() public {
        vm.prank(admin);
        vm.expectRevert(TopUpRouter.ZeroAddress.selector);
        router.proposePauser(address(0));

        vm.prank(admin);
        vm.expectRevert(TopUpRouter.SelfAddress.selector);
        router.proposePauser(address(router));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../src/TopUpRouter.sol";
import {BaseTest} from "../BaseTest.sol";

/// @title AccessControlAttackTest
/// @notice 002 FR-002/FR-026: every governance function rejects every unauthorized caller.
/// @dev Extended in Phase 7 (T071) with the authority-transfer and pause functions.
contract AccessControlAttackTest is BaseTest {
    address internal target = makeAddr("attackerTarget");

    /// @dev Every actor that must NOT be able to govern. `pauser` is included deliberately:
    ///      002 FR-026 requires pause authority to grant nothing else.
    function _unauthorizedActors() internal view returns (address[4] memory) {
        return [attacker, stranger, pauser, beneficiary];
    }

    function test_AttackFails_ProposeTreasuryRejectsAllUnauthorized() public {
        address[4] memory actors = _unauthorizedActors();
        for (uint256 i = 0; i < actors.length; i++) {
            vm.prank(actors[i]);
            vm.expectRevert(TopUpRouter.NotAdmin.selector);
            router.proposeTreasury(target);
        }
        (address pending,) = router.pendingTreasury();
        assertEq(pending, address(0), "no proposal was created by any unauthorized actor");
    }

    function test_AttackFails_CancelTreasuryRejectsAllUnauthorized() public {
        vm.prank(admin);
        router.proposeTreasury(target);

        address[4] memory actors = _unauthorizedActors();
        for (uint256 i = 0; i < actors.length; i++) {
            vm.prank(actors[i]);
            vm.expectRevert(TopUpRouter.NotAdmin.selector);
            router.cancelTreasury();
        }
        (address pending,) = router.pendingTreasury();
        assertEq(pending, target, "the pending change survived every cancel attempt");
    }

    /// @dev 002 FR-026: the pauser may not use its role to reach the treasury.
    function test_AttackFails_PauserCannotTouchTreasury() public {
        vm.prank(pauser);
        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.proposeTreasury(target);

        vm.prank(admin);
        router.proposeTreasury(target);

        vm.prank(pauser);
        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.cancelTreasury();
    }

    /// @dev The treasury itself has no special power.
    function test_AttackFails_TreasuryCannotGovern() public {
        vm.prank(treasury);
        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.proposeTreasury(target);
    }

    /// @notice No governance path leads to funds (002 FR-031 / INV-8).
    function test_AttackFails_NoGovernancePathExtractsFunds() public {
        forceFundsInto(address(router), 100e18);

        vm.startPrank(admin);
        router.proposeTreasury(attacker);
        vm.stopPrank();
        warpPastDelay();
        router.applyTreasury();

        // Admin rotated the treasury to themselves. Even so, funds already stranded in the
        // router stay stranded: rotation only affects FUTURE top-ups.
        assertEq(address(router).balance, 100e18, "stranded funds remain unreachable");
        assertEq(attacker.balance, STARTING_BALANCE, "no funds extracted by governance");
    }

    function testFuzz_AttackFails_AnyNonAdminIsRejected(address caller) public {
        vm.assume(caller != admin);
        vm.prank(caller);
        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.proposeTreasury(target);
    }

    /*//////////////////////////////////////////////////////////////
              T071: PAUSE / GOVERNANCE SEPARATION (002 FR-026)
    //////////////////////////////////////////////////////////////*/

    /// @notice ATTACK: the pauser tries to use its role to reach governance.
    /// @dev The pauser is deliberately the FASTEST authority (no delay), so it must also be the
    ///      NARROWEST. If pause authority leaked into treasury control, the fast path would
    ///      become the attack path.
    function test_AttackFails_PauserCannotUseRoleToGovern() public {
        vm.startPrank(pauser);

        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.proposeTreasury(target);

        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.proposeAdmin(target);

        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.proposePauser(target);

        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.cancelTreasury();

        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.cancelAdmin();

        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.cancelPauser();

        vm.stopPrank();

        assertEq(router.treasury(), treasury, "treasury untouched by the pauser");
        assertEq(router.admin(), admin, "authority untouched by the pauser");
    }

    /// @notice ATTACK: the admin tries to pause without holding the pauser role.
    /// @dev Separation cuts both ways. Admin is powerful but slow; it does not get the fast lever
    ///      for free.
    function test_AttackFails_AdminCannotPauseWithoutPauserRole() public {
        vm.prank(admin);
        vm.expectRevert(TopUpRouter.NotPauser.selector);
        router.pause();

        assertFalse(router.paused(), "not paused");
    }

    /// @notice ATTACK: pausing to grief, then trying to reach funds. Pausing moves no money.
    function test_AttackFails_PauserCanOnlyDenyServiceNeverSteal() public {
        forceFundsInto(address(router), 50e18);
        uint256 pauserBefore = pauser.balance;

        vm.prank(pauser);
        router.pause();

        // The worst a rogue pauser can do is stop top-ups. Nothing moves.
        assertEq(pauser.balance, pauserBefore, "pauser gained nothing");
        assertEq(address(router).balance, 50e18, "stranded funds untouched");
        assertEq(treasury.balance, 0, "no funds moved");

        // And admin can rotate the pauser out — slowly, but it is recoverable.
        vm.prank(admin);
        router.proposePauser(stranger);
        warpPastDelay();
        router.applyPauser();

        vm.prank(pauser);
        vm.expectRevert(TopUpRouter.NotPauser.selector);
        router.unpause();

        vm.prank(stranger);
        router.unpause();
        assertFalse(router.paused(), "service restored by the new pauser");
    }

    function testFuzz_AttackFails_AnyNonPauserCannotPause(address caller) public {
        vm.assume(caller != pauser);
        vm.prank(caller);
        vm.expectRevert(TopUpRouter.NotPauser.selector);
        router.pause();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../src/TopUpRouter.sol";
import {BaseTest} from "../BaseTest.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PauseControlTest
/// @notice US7: 002 FR-021, FR-025, FR-027 — an immediate halt on a separate, faster authority.
contract PauseControlTest is BaseTest {
    event Paused(address account);
    event Unpaused(address account);

    /*//////////////////////////////////////////////////////////////
                        IMMEDIATE EFFECT (FR-025)
    //////////////////////////////////////////////////////////////*/

    /// @dev No waiting period. Pausing is the only fast response the system has, because the
    ///      code is immutable and top-ups are irreversible.
    function test_PauseTakesEffectImmediately() public {
        uint256 t0 = block.timestamp;

        vm.expectEmit(true, true, true, true, address(router));
        emit Paused(pauser);
        vm.prank(pauser);
        router.pause();

        assertTrue(router.paused(), "paused in the same transaction");
        assertEq(block.timestamp, t0, "no time had to pass");

        vm.prank(payer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.topUp{value: 10e18}(beneficiary);
    }

    function test_PausedBlocksBothTopUpEntryPoints() public {
        vm.prank(pauser);
        router.pause();

        vm.prank(payer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.topUp{value: 10e18}(beneficiary);

        vm.prank(payer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.topUpSelf{value: 10e18}();
    }

    function test_PausedTopUpLeavesFundsWithPayer() public {
        vm.prank(pauser);
        router.pause();

        uint256 before = payer.balance;
        vm.prank(payer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.topUp{value: 10e18}(beneficiary);

        assertEq(payer.balance, before, "payer keeps their funds");
        assertEq(router.totalRouted(), 0, "nothing routed");
    }

    /// @dev 002 FR-021: totals carry over unchanged across a pause.
    function test_ResumeRestoresServiceAndPreservesTotals() public {
        vm.prank(payer);
        router.topUp{value: 6e18}(beneficiary);

        vm.prank(pauser);
        router.pause();

        vm.expectEmit(true, true, true, true, address(router));
        emit Unpaused(pauser);
        vm.prank(pauser);
        router.unpause();

        vm.prank(payer);
        router.topUp{value: 4e18}(beneficiary);

        assertEq(router.contributions(beneficiary), 10e18, "totals continue from prior values");
        assertEq(router.totalRouted(), 10e18, "system total continuous");
    }

    /*//////////////////////////////////////////////////////////////
                    READS AND GOVERNANCE KEEP WORKING
    //////////////////////////////////////////////////////////////*/

    /// @dev T069 / 002 US5 acceptance 4: pausing halts new top-ups only, never the record.
    function test_AllReadsStillWorkWhilePaused() public {
        vm.prank(payer);
        router.topUp{value: 8e18}(beneficiary);

        vm.prank(pauser);
        router.pause();

        assertEq(router.contributions(beneficiary), 8e18, "per-account total readable");
        assertEq(router.totalRouted(), 8e18, "system total readable");
        assertEq(router.treasury(), treasury, "treasury readable");
        assertEq(router.admin(), admin, "admin readable");
        assertEq(router.pauser(), pauser, "pauser readable");
        assertEq(router.DELAY(), 172_800, "delay readable");
        assertEq(router.MIN_TOPUP(), MIN_TOPUP, "minimum readable");
        assertFalse(router.multisigEstablished(), "posture readable");
        (address t,) = router.pendingTreasury();
        assertEq(t, address(0), "pending readable");
    }

    /// @dev T070 / 002 FR-027: governance must remain operable while top-ups are halted —
    ///      otherwise pausing during an incident would also freeze your ability to fix it.
    function test_GovernanceRemainsOperableWhilePaused() public {
        vm.prank(pauser);
        router.pause();

        address newTreasury = makeAddr("safeTreasury");

        vm.prank(admin);
        router.proposeTreasury(newTreasury);
        (address pending,) = router.pendingTreasury();
        assertEq(pending, newTreasury, "can propose while paused");

        warpPastDelay();
        router.applyTreasury();
        assertEq(router.treasury(), newTreasury, "can apply while paused");

        vm.prank(admin);
        router.proposeAdmin(makeAddr("newAdmin"));
        vm.prank(admin);
        router.cancelAdmin();

        vm.prank(admin);
        router.proposePauser(makeAddr("newPauser"));
        (address pp,) = router.pendingPauser();
        assertTrue(pp != address(0), "pauser rotation proposable while paused");
    }

    /// @dev The full incident sequence: pause, rotate to safety, resume.
    function test_IncidentResponse_PauseRotateResume() public {
        address safeTreasury = makeAddr("safeTreasury");

        vm.prank(pauser);
        router.pause();

        vm.prank(admin);
        router.proposeTreasury(safeTreasury);
        warpPastDelay();
        router.applyTreasury();

        vm.prank(pauser);
        router.unpause();

        vm.prank(payer);
        router.topUp{value: 5e18}(beneficiary);

        assertEq(safeTreasury.balance, 5e18, "funds now route to the safe treasury");
    }

    /*//////////////////////////////////////////////////////////////
                          AUTHORITY (FR-026)
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_NonPauserPauses() public {
        address[3] memory actors = [attacker, stranger, beneficiary];
        for (uint256 i = 0; i < actors.length; i++) {
            vm.prank(actors[i]);
            vm.expectRevert(TopUpRouter.NotPauser.selector);
            router.pause();
        }
        assertFalse(router.paused(), "never paused by an unauthorized caller");
    }

    /// @dev 002 FR-024: the authorities are separate. Admin does not implicitly hold pause.
    function test_RevertWhen_AdminPausesWithoutPauserRole() public {
        vm.prank(admin);
        vm.expectRevert(TopUpRouter.NotPauser.selector);
        router.pause();
    }

    function test_RevertWhen_NonPauserUnpauses() public {
        vm.prank(pauser);
        router.pause();

        vm.prank(admin);
        vm.expectRevert(TopUpRouter.NotPauser.selector);
        router.unpause();

        assertTrue(router.paused(), "still paused");
    }

    function test_RevertWhen_PausingWhileAlreadyPaused() public {
        vm.startPrank(pauser);
        router.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.pause();
        vm.stopPrank();
    }

    function test_RevertWhen_UnpausingWhileNotPaused() public {
        vm.prank(pauser);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        router.unpause();
    }

    /// @dev A rotated pauser takes over the role, and the old one loses it.
    function test_RotatedPauserTakesOverTheRole() public {
        address newPauser = makeAddr("rotatedPauser");

        vm.prank(admin);
        router.proposePauser(newPauser);
        warpPastDelay();
        router.applyPauser();

        vm.prank(pauser);
        vm.expectRevert(TopUpRouter.NotPauser.selector);
        router.pause();

        vm.prank(newPauser);
        router.pause();
        assertTrue(router.paused(), "new pauser holds the role");
    }
}

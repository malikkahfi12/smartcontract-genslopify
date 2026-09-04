// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../src/TopUpRouter.sol";
import {BaseTest} from "../BaseTest.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title TreasuryRotationTest
/// @notice US2 core behaviour: 002 FR-001..FR-012.
contract TreasuryRotationTest is BaseTest {
    address internal newTreasury = makeAddr("newTreasury");
    address internal otherTreasury = makeAddr("otherTreasury");

    event ChangeProposed(TopUpRouter.Subject indexed subject, address indexed target, uint64 eta);
    event ChangeApplied(
        TopUpRouter.Subject indexed subject, address indexed previous, address indexed target
    );
    event ChangeCancelled(TopUpRouter.Subject indexed subject, address indexed target);

    /*//////////////////////////////////////////////////////////////
                                 PROPOSE
    //////////////////////////////////////////////////////////////*/

    function test_ProposeSetsPendingWithTwoDayEta() public {
        vm.prank(admin);
        router.proposeTreasury(newTreasury);

        (address target, uint64 eta) = router.pendingTreasury();
        assertEq(target, newTreasury, "pending target");
        assertEq(eta, block.timestamp + DELAY, "eta is exactly now + 2 days");
    }

    function test_ProposeEmitsChangeProposed() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit ChangeProposed(
            TopUpRouter.Subject.Treasury, newTreasury, uint64(block.timestamp + DELAY)
        );
        vm.prank(admin);
        router.proposeTreasury(newTreasury);
    }

    /// @dev 002 FR-005: top-ups keep routing to the CURRENT treasury while a change is pending.
    function test_TopUpsStillRouteToOldTreasuryWhilePending() public {
        vm.prank(admin);
        router.proposeTreasury(newTreasury);

        uint256 before = treasury.balance;
        vm.prank(payer);
        router.topUp{value: 10e18}(beneficiary);

        assertEq(treasury.balance - before, 10e18, "old treasury still receives");
        assertEq(newTreasury.balance, 0, "new treasury receives nothing yet");
    }

    function test_RevertWhen_ProposeZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(TopUpRouter.ZeroAddress.selector);
        router.proposeTreasury(address(0));
    }

    function test_RevertWhen_ProposeSelfAddress() public {
        vm.prank(admin);
        vm.expectRevert(TopUpRouter.SelfAddress.selector);
        router.proposeTreasury(address(router));
    }

    /*//////////////////////////////////////////////////////////////
                                  APPLY
    //////////////////////////////////////////////////////////////*/

    function test_ApplyAfterDelaySwitchesTreasury() public {
        vm.prank(admin);
        router.proposeTreasury(newTreasury);
        warpPastDelay();

        router.applyTreasury();

        assertEq(router.treasury(), newTreasury, "treasury rotated");
        (address target, uint64 eta) = router.pendingTreasury();
        assertEq(target, address(0), "pending cleared");
        assertEq(eta, 0, "eta cleared");
    }

    function test_ApplyEmitsChangeApplied() public {
        vm.prank(admin);
        router.proposeTreasury(newTreasury);
        warpPastDelay();

        vm.expectEmit(true, true, true, true, address(router));
        emit ChangeApplied(TopUpRouter.Subject.Treasury, treasury, newTreasury);
        router.applyTreasury();
    }

    function test_TopUpsRouteToNewTreasuryAfterApply() public {
        vm.prank(admin);
        router.proposeTreasury(newTreasury);
        warpPastDelay();
        router.applyTreasury();

        vm.prank(payer);
        router.topUp{value: 10e18}(beneficiary);

        assertEq(newTreasury.balance, 10e18, "new treasury receives");
    }

    /// @dev 002 FR-009 / 001 edge case: the event must name the address that ACTUALLY received.
    function test_EventNamesActualReceivingTreasuryAfterRotation() public {
        vm.prank(admin);
        router.proposeTreasury(newTreasury);
        warpPastDelay();
        router.applyTreasury();

        vm.recordLogs();
        vm.prank(payer);
        router.topUp{value: 10e18}(beneficiary);

        // ToppedUp(payer, beneficiary, amount, treasury, newTotal): treasury is 1st non-indexed
        // word after amount.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, address recorded,) = abi.decode(logs[0].data, (uint256, address, uint256));
        assertEq(recorded, newTreasury, "record names the new treasury");
    }

    /// @dev Applying is permissionless by design once the delay has elapsed.
    function test_AnyoneCanApplyOnceElapsed() public {
        vm.prank(admin);
        router.proposeTreasury(newTreasury);
        warpPastDelay();

        vm.prank(stranger);
        router.applyTreasury();

        assertEq(router.treasury(), newTreasury, "stranger may execute an approved change");
    }

    function test_RevertWhen_ApplyWithNoPendingChange() public {
        vm.expectRevert(TopUpRouter.NoPendingChange.selector);
        router.applyTreasury();
    }

    /*//////////////////////////////////////////////////////////////
                                 CANCEL
    //////////////////////////////////////////////////////////////*/

    function test_CancelClearsPending() public {
        vm.startPrank(admin);
        router.proposeTreasury(newTreasury);

        vm.expectEmit(true, true, true, true, address(router));
        emit ChangeCancelled(TopUpRouter.Subject.Treasury, newTreasury);
        router.cancelTreasury();
        vm.stopPrank();

        (address target,) = router.pendingTreasury();
        assertEq(target, address(0), "pending cleared");
        assertEq(router.treasury(), treasury, "destination unchanged");
    }

    function test_RevertWhen_CancelWithNoPendingChange() public {
        vm.prank(admin);
        vm.expectRevert(TopUpRouter.NoPendingChange.selector);
        router.cancelTreasury();
    }

    /*//////////////////////////////////////////////////////////////
                          RE-PROPOSE / FR-012
    //////////////////////////////////////////////////////////////*/

    /// @dev 002 FR-012: a re-proposal REPLACES and restarts the full clock. It must never
    ///      inherit elapsed time, or the delay could be shortened by repeated proposing.
    function test_ReproposeReplacesTargetAndRestartsFullClock() public {
        vm.prank(admin);
        router.proposeTreasury(newTreasury);

        vm.warp(block.timestamp + 1 days); // half-way through

        vm.prank(admin);
        router.proposeTreasury(otherTreasury);

        (address target, uint64 eta) = router.pendingTreasury();
        assertEq(target, otherTreasury, "target replaced");
        assertEq(eta, block.timestamp + DELAY, "clock restarted at full 2 days");
    }

    function test_OnlyOneApplicablePendingChangeExists() public {
        vm.startPrank(admin);
        router.proposeTreasury(newTreasury);
        router.proposeTreasury(otherTreasury);
        vm.stopPrank();

        warpPastDelay();
        router.applyTreasury();

        assertEq(router.treasury(), otherTreasury, "only the latest proposal is applicable");

        // The replaced proposal is gone; nothing else can be applied.
        vm.expectRevert(TopUpRouter.NoPendingChange.selector);
        router.applyTreasury();
    }

    /*//////////////////////////////////////////////////////////////
                        FR-008 / FR-006 / FR-030
    //////////////////////////////////////////////////////////////*/

    /// @dev 002 FR-008: the delay is a constant with no setter, at any price.
    function test_DelayIsFixedAndHasNoSetter() public {
        assertEq(router.DELAY(), 172_800, "exactly 2 days in seconds");

        vm.prank(admin);
        (bool ok,) = address(router).call(abi.encodeWithSignature("setDelay(uint256)", 1));
        assertFalse(ok, "no setDelay function may exist");

        vm.prank(admin);
        (bool ok2,) = address(router).call(abi.encodeWithSignature("setDELAY(uint256)", 1));
        assertFalse(ok2, "no delay setter under any name");
    }

    /// @dev 002 FR-006/FR-030: a pending rotation is publicly monitorable for its whole window.
    function test_PendingRotationIsPubliclyReadable() public {
        vm.prank(admin);
        router.proposeTreasury(newTreasury);

        // Read as an unrelated observer, no privileged access.
        vm.prank(stranger);
        (address target, uint64 eta) = router.pendingTreasury();

        assertEq(target, newTreasury, "destination visible");
        assertGt(eta, block.timestamp, "effective time visible and in the future");
        assertEq(eta - block.timestamp, DELAY, "full window remaining");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../src/TopUpRouter.sol";
import {BaseTest} from "../BaseTest.sol";
import {MockMultisig} from "../mocks/MockMultisig.sol";

/// @title AuthorityTransferTest
/// @notice US5: 002 FR-013..FR-018 — administrative authority is transferable under the same
///         2-day delay that protects the treasury.
contract AuthorityTransferTest is BaseTest {
    address internal newAdmin = makeAddr("newAdmin");
    address internal otherAdmin = makeAddr("otherAdmin");

    event ChangeProposed(TopUpRouter.Subject indexed subject, address indexed target, uint64 eta);
    event ChangeApplied(
        TopUpRouter.Subject indexed subject, address indexed previous, address indexed target
    );
    event MultisigEstablished(address indexed admin);

    function test_ProposeAdminSetsPendingWithTwoDayEta() public {
        vm.prank(admin);
        router.proposeAdmin(newAdmin);

        (address target, uint64 eta) = router.pendingAdmin();
        assertEq(target, newAdmin, "pending admin");
        assertEq(eta, block.timestamp + DELAY, "same 2-day delay as treasury");
    }

    /// @dev 002 FR-017: authority transfer is delayed exactly like a treasury rotation.
    function test_RevertWhen_ApplyAdminBeforeDelayElapsed() public {
        vm.prank(admin);
        router.proposeAdmin(newAdmin);
        (, uint64 eta) = router.pendingAdmin();

        warpToJustBeforeEta(eta);
        vm.expectRevert(
            abi.encodeWithSelector(TopUpRouter.TimelockNotElapsed.selector, block.timestamp, eta)
        );
        router.applyAdmin();

        assertEq(router.admin(), admin, "authority unchanged one second early");
    }

    function test_ApplyAdminAfterDelayTransfersAuthority() public {
        vm.prank(admin);
        router.proposeAdmin(newAdmin);
        warpPastDelay();

        vm.expectEmit(true, true, true, true, address(router));
        emit ChangeApplied(TopUpRouter.Subject.Admin, admin, newAdmin);
        router.applyAdmin();

        assertEq(router.admin(), newAdmin, "authority transferred");
    }

    /// @dev 002 FR-014: the previous authority must be able to do nothing afterwards.
    function test_PreviousAdminLosesAllPowerAfterTransfer() public {
        vm.prank(admin);
        router.proposeAdmin(newAdmin);
        warpPastDelay();
        router.applyAdmin();

        vm.prank(admin);
        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.proposeTreasury(makeAddr("x"));

        vm.prank(admin);
        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.proposeAdmin(admin);

        vm.prank(admin);
        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.proposePauser(admin);
    }

    function test_NewAdminGainsFullAuthority() public {
        vm.prank(admin);
        router.proposeAdmin(newAdmin);
        warpPastDelay();
        router.applyAdmin();

        address target = makeAddr("freshTreasury");
        vm.prank(newAdmin);
        router.proposeTreasury(target);

        (address pending,) = router.pendingTreasury();
        assertEq(pending, target, "new admin can govern");
    }

    function test_CancelAdminClearsPending() public {
        vm.startPrank(admin);
        router.proposeAdmin(newAdmin);
        router.cancelAdmin();
        vm.stopPrank();

        (address target,) = router.pendingAdmin();
        assertEq(target, address(0), "pending cleared");

        warpPastDelay();
        vm.expectRevert(TopUpRouter.NoPendingChange.selector);
        router.applyAdmin();
        assertEq(router.admin(), admin, "authority unchanged");
    }

    /// @dev 002 FR-015: the system must never become ungovernable.
    function test_RevertWhen_ProposeAdminZeroOrSelf() public {
        vm.prank(admin);
        vm.expectRevert(TopUpRouter.ZeroAddress.selector);
        router.proposeAdmin(address(0));

        vm.prank(admin);
        vm.expectRevert(TopUpRouter.SelfAddress.selector);
        router.proposeAdmin(address(router));
    }

    function test_RevertWhen_NonAdminProposesAdmin() public {
        vm.prank(attacker);
        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.proposeAdmin(attacker);
    }

    function test_ReproposeAdminRestartsFullClock() public {
        vm.prank(admin);
        router.proposeAdmin(newAdmin);
        vm.warp(block.timestamp + 1 days);

        vm.prank(admin);
        router.proposeAdmin(otherAdmin);

        (address target, uint64 eta) = router.pendingAdmin();
        assertEq(target, otherAdmin, "target replaced");
        assertEq(eta, block.timestamp + DELAY, "full fresh 2 days");
    }

    /// @dev 002 US3 acceptance 5 / T053: a pending treasury rotation must neither gain nor lose
    ///      time when the authority changes underneath it.
    function test_PendingTreasuryUnaffectedByAuthorityChange() public {
        vm.prank(admin);
        router.proposeTreasury(makeAddr("pendingTreasuryTarget"));
        (address treasuryTarget, uint64 treasuryEta) = router.pendingTreasury();

        vm.prank(admin);
        router.proposeAdmin(newAdmin);
        warpPastDelay();
        router.applyAdmin();

        (address targetAfter, uint64 etaAfter) = router.pendingTreasury();
        assertEq(targetAfter, treasuryTarget, "pending treasury target survives unchanged");
        assertEq(etaAfter, treasuryEta, "eta neither shortened nor extended");

        // It matured during the wait and is now applicable by anyone.
        router.applyTreasury();
        assertEq(router.treasury(), treasuryTarget, "matured normally");
    }

    /// @dev Treasury and authority proposals are independent slots and do not block each other.
    function test_TreasuryAndAdminProposalsCoexist() public {
        vm.startPrank(admin);
        router.proposeTreasury(makeAddr("t"));
        router.proposeAdmin(newAdmin);
        vm.stopPrank();

        (address t,) = router.pendingTreasury();
        (address a,) = router.pendingAdmin();
        assertTrue(t != address(0) && a != address(0), "both pending independently");
    }

    /*//////////////////////////////////////////////////////////////
            US6: THE ONE-WAY MULTISIG LATCH (002 FR-022, FR-023)
    //////////////////////////////////////////////////////////////*/

    function test_Latch_FalseAfterEoaDeployment() public view {
        assertFalse(router.multisigEstablished(), "EOA admin leaves the latch open");
    }

    /// @dev 002 FR-022: governance posture is publicly determinable before anyone tops up.
    function test_Latch_SetsAfterHandoverToContractAdmin() public {
        MockMultisig ms = deployMockMultisig();

        vm.prank(admin);
        router.proposeAdmin(address(ms));
        warpPastDelay();

        vm.expectEmit(true, true, true, true, address(router));
        emit MultisigEstablished(address(ms));
        router.applyAdmin();

        assertTrue(router.multisigEstablished(), "latch closed");
        assertEq(router.admin(), address(ms), "multisig now governs");
    }

    /// @dev 002 FR-023: the transition is one-way and permanent.
    function test_Latch_RevertWhen_ReturningToEoaAfterMultisig() public {
        MockMultisig ms = deployMockMultisig();
        vm.prank(admin);
        router.proposeAdmin(address(ms));
        warpPastDelay();
        router.applyAdmin();

        // The multisig proposes an EOA. Proposing is permitted; APPLYING is not.
        vm.prank(address(ms));
        router.proposeAdmin(newAdmin);
        warpPastDelay();

        vm.expectRevert(TopUpRouter.MustBeContract.selector);
        router.applyAdmin();

        assertEq(router.admin(), address(ms), "authority stays with the multisig");
        assertTrue(router.multisigEstablished(), "latch never reopens");
    }

    /// @dev Moving between two contract authorities remains possible after the latch.
    function test_Latch_ContractToContractTransferStillAllowed() public {
        MockMultisig first = deployMockMultisig();
        MockMultisig second = deployMockMultisig();

        vm.prank(admin);
        router.proposeAdmin(address(first));
        warpPastDelay();
        router.applyAdmin();

        vm.prank(address(first));
        router.proposeAdmin(address(second));
        warpPastDelay();
        router.applyAdmin();

        assertEq(router.admin(), address(second), "contract-to-contract transfer works");
    }

    /// @dev T060 / research R-003: the code check is evaluated at APPLY time, not at propose
    ///      time, because the state that matters is the moment authority actually transfers.
    ///      An address may be codeless when proposed and hold code by the time it takes power.
    function test_Latch_CodeCheckIsEvaluatedAtApplyTime() public {
        MockMultisig ms = deployMockMultisig();
        vm.prank(admin);
        router.proposeAdmin(address(ms));
        warpPastDelay();
        router.applyAdmin();

        address futureContract = makeAddr("deployedLater");

        // Codeless when proposed - proposing does not check.
        vm.prank(address(ms));
        router.proposeAdmin(futureContract);
        warpPastDelay();

        // Still codeless at apply time: rejected.
        vm.expectRevert(TopUpRouter.MustBeContract.selector);
        router.applyAdmin();

        // Give it code, then apply the same proposal: now accepted.
        vm.etch(futureContract, hex"600160005260206000f3");
        router.applyAdmin();

        assertEq(router.admin(), futureContract, "checked against state at apply time");
    }

    /// @dev 002 FR-023a: the INITIAL handover is itself an authority transfer, so it waits the
    ///      full 2 days like everything else. It is not a one-time exemption.
    function test_Latch_InitialHandoverWaitsFullTwoDays() public {
        MockMultisig ms = deployMockMultisig();

        vm.prank(admin);
        router.proposeAdmin(address(ms));
        (, uint64 eta) = router.pendingAdmin();
        assertEq(eta, block.timestamp + DELAY, "handover carries the full delay");

        warpToJustBeforeEta(eta);
        vm.expectRevert(
            abi.encodeWithSelector(TopUpRouter.TimelockNotElapsed.selector, block.timestamp, eta)
        );
        router.applyAdmin();
        assertFalse(router.multisigEstablished(), "still single-key one second early");
    }

    /// @dev 002 FR-023a: a handover proposed to a wrong address is recoverable inside the window.
    function test_Latch_InitialHandoverCancellableByPrimaryKey() public {
        MockMultisig wrong = deployMockMultisig();

        vm.startPrank(admin);
        router.proposeAdmin(address(wrong));
        router.cancelAdmin();
        vm.stopPrank();

        warpPastDelay();
        vm.expectRevert(TopUpRouter.NoPendingChange.selector);
        router.applyAdmin();

        assertEq(router.admin(), admin, "primary key retains authority");
        assertFalse(router.multisigEstablished(), "latch untouched");
    }
}

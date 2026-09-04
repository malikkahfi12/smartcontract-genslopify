// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../src/TopUpRouter.sol";
import {BaseTest} from "../BaseTest.sol";
import {MockMultisig} from "../mocks/MockMultisig.sol";

/// @title DeploymentTest
/// @notice Phase 2 checkpoint: the skeleton deploys and every getter reports constructor state.
/// @dev Behavioural tests for top-up and governance arrive in Phase 3+ alongside their features.
contract DeploymentTest is BaseTest {
    function test_ConstructorWiresGovernanceState() public view {
        assertEq(router.treasury(), treasury, "treasury");
        assertEq(router.admin(), admin, "admin");
        assertEq(router.pauser(), pauser, "pauser");
        assertEq(router.MIN_TOPUP(), MIN_TOPUP, "minTopUp");
    }

    function test_DelayIsExactlyTwoDays() public view {
        assertEq(router.DELAY(), 2 days, "DELAY must be 2 days");
        assertEq(router.DELAY(), 172_800, "DELAY in seconds");
    }

    function test_AccountingStartsEmpty() public view {
        assertEq(router.totalRouted(), 0, "totalRouted");
        assertEq(router.contributions(beneficiary), 0, "never-credited account reads zero");
        assertFalse(router.paused(), "starts unpaused");
    }

    function test_NoPendingChangesAtDeployment() public view {
        (address t, uint64 e) = router.pendingTreasury();
        assertEq(t, address(0), "no pending treasury");
        assertEq(e, 0, "no eta");
        (address a,) = router.pendingAdmin();
        assertEq(a, address(0), "no pending admin");
        (address p,) = router.pendingPauser();
        assertEq(p, address(0), "no pending pauser");
    }

    function test_EoaAdminDoesNotLatchMultisig() public view {
        assertFalse(router.multisigEstablished(), "EOA admin must not latch the one-way flag");
    }

    function test_ContractAdminLatchesMultisigAtDeployment() public {
        MockMultisig ms = deployMockMultisig();
        TopUpRouter r = new TopUpRouter(treasury, address(ms), pauser, MIN_TOPUP);
        assertTrue(r.multisigEstablished(), "contract admin must latch immediately");
    }

    function test_RevertWhen_ConstructorGivenZeroAddress() public {
        vm.expectRevert(TopUpRouter.ZeroAddress.selector);
        new TopUpRouter(address(0), admin, pauser, MIN_TOPUP);

        vm.expectRevert(TopUpRouter.ZeroAddress.selector);
        new TopUpRouter(treasury, address(0), pauser, MIN_TOPUP);

        vm.expectRevert(TopUpRouter.ZeroAddress.selector);
        new TopUpRouter(treasury, admin, address(0), MIN_TOPUP);
    }

    function test_RevertWhen_ConstructorGivenZeroMinimum() public {
        vm.expectRevert(TopUpRouter.ZeroAmount.selector);
        new TopUpRouter(treasury, admin, pauser, 0);
    }

    /// @dev 001 FR-028: no receive/fallback exists, so a bare value transfer must revert.
    function test_RevertWhen_BareValueTransferSent() public {
        vm.prank(payer);
        (bool ok,) = address(router).call{value: 1 ether}("");
        assertFalse(ok, "bare transfer must be rejected: no receive/fallback");
    }
}

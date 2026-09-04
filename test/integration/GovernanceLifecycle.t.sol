// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../src/TopUpRouter.sol";
import {BaseTest} from "../BaseTest.sol";
import {MockMultisig} from "../mocks/MockMultisig.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title GovernanceLifecycleTest
/// @notice T062: the full intended operational path, end to end, in one test.
/// @dev Mirrors the 9-step scenario in quickstart.md. This is the closest thing to a rehearsal
///      that automated tests can provide — the testnet scope deliberately does not perform a
///      live handover (spec Q2 -> B), so this is where the procedure is actually exercised.
contract GovernanceLifecycleTest is BaseTest {
    MockMultisig internal multisig;
    address internal finalTreasury = makeAddr("finalTreasury");

    function test_FullLifecycle_DeploySingleKeyThenHardenThenOperate() public {
        // ---- 1. Deployed with a single primary key ----
        assertFalse(router.multisigEstablished(), "1: starts single-key");
        assertEq(router.admin(), admin, "1: primary key governs");

        // ---- 2. A user tops up; funds route, record is correct ----
        uint256 treasuryBefore = treasury.balance;
        vm.prank(payer);
        router.topUp{value: 10e18}(beneficiary);
        assertEq(treasury.balance - treasuryBefore, 10e18, "2: treasury received");
        assertEq(router.contributions(beneficiary), 10e18, "2: credited");

        // ---- 3. Primary key proposes handover; NOT effective yet ----
        multisig = deployMockMultisig();
        vm.prank(admin);
        router.proposeAdmin(address(multisig));
        (, uint64 handoverEta) = router.pendingAdmin();
        assertEq(router.admin(), admin, "3: still the primary key");
        assertFalse(router.multisigEstablished(), "3: latch still open");

        // ---- 4. One second short: apply must revert ----
        warpToJustBeforeEta(handoverEta);
        vm.expectRevert(
            abi.encodeWithSelector(
                TopUpRouter.TimelockNotElapsed.selector, block.timestamp, handoverEta
            )
        );
        router.applyAdmin();

        // ---- 5. At eta: handover completes, primary key is powerless ----
        vm.warp(handoverEta);
        router.applyAdmin();
        assertEq(router.admin(), address(multisig), "5: multisig governs");
        assertTrue(router.multisigEstablished(), "5: latch closed");

        vm.prank(admin);
        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.proposeTreasury(finalTreasury);

        // ---- 6. Cannot go back to an EOA ----
        vm.prank(address(multisig));
        router.proposeAdmin(makeAddr("someEoa"));
        warpPastDelay();
        vm.expectRevert(TopUpRouter.MustBeContract.selector);
        router.applyAdmin();
        vm.prank(address(multisig));
        router.cancelAdmin();

        // ---- 7. Multisig rotates the treasury: visible for 2 days, cancellable ----
        vm.prank(address(multisig));
        router.proposeTreasury(finalTreasury);
        (address pendingTarget, uint64 rotEta) = router.pendingTreasury();
        assertEq(pendingTarget, finalTreasury, "7: rotation publicly visible");
        assertEq(rotEta - block.timestamp, DELAY, "7: full window to react");

        vm.warp(rotEta);
        router.applyTreasury();
        assertEq(router.treasury(), finalTreasury, "7: rotated");

        // ---- 8. Pauser halts top-ups immediately; governance still works ----
        // Completed in Phase 9 once pause() existed. Deferred from Phase 8 rather than pulling
        // US7 forward ahead of its own tests.
        vm.prank(pauser);
        router.pause();
        assertTrue(router.paused(), "8: paused in one transaction, no delay");

        vm.prank(payer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.topUp{value: 5e18}(beneficiary);

        // Governance stays operable while halted (002 FR-027) - this is what makes the pause a
        // usable incident response rather than a self-inflicted freeze.
        vm.prank(address(multisig));
        router.proposeTreasury(makeAddr("anotherTreasury"));
        (address stillWorks,) = router.pendingTreasury();
        assertTrue(stillWorks != address(0), "8: governance operable while paused");

        vm.prank(address(multisig));
        router.cancelTreasury();

        // The pauser cannot use its speed to reach the treasury.
        vm.prank(pauser);
        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.proposeTreasury(makeAddr("pauserGrab"));

        vm.prank(pauser);
        router.unpause();
        assertFalse(router.paused(), "8: service restored");

        // ---- 9. Invariants hold across the whole lifecycle ----
        vm.prank(payer);
        router.topUp{value: 4e18}(beneficiary);

        assertEq(router.contributions(beneficiary), 14e18, "9: INV-1 totals accumulated");
        assertEq(router.totalRouted(), 14e18, "9: INV-1 system total matches");
        assertEq(finalTreasury.balance, 4e18, "9: post-rotation funds went to the new treasury");
        assertEq(treasury.balance - treasuryBefore, 10e18, "9: pre-rotation funds stayed put");
        assertEq(address(router).balance, 0, "9: INV-8 router retains nothing");
    }
}

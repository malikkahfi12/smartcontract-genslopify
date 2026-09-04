// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../src/TopUpRouter.sol";
import {BaseTest} from "../BaseTest.sol";

/// @title TimelockBypassAttackTest
/// @notice 002 FR-005/FR-009/FR-011: the 2-day delay must be unbypassable by every route.
/// @dev Each test ATTEMPTS a bypass and asserts it FAILS. The authority-swap case — the single
///      most important test in the suite — arrives in Phase 7 (T052) once authority transfer
///      exists; it is the attack that motivated 002 FR-017.
contract TimelockBypassAttackTest is BaseTest {
    address internal attackerTreasury = makeAddr("attackerTreasury");

    /// @notice ATTACK: apply one second early.
    function test_AttackFails_ApplyOneSecondBeforeEta() public {
        vm.prank(admin);
        router.proposeTreasury(attackerTreasury);
        (, uint64 eta) = router.pendingTreasury();

        warpToJustBeforeEta(eta);

        vm.expectRevert(
            abi.encodeWithSelector(TopUpRouter.TimelockNotElapsed.selector, block.timestamp, eta)
        );
        router.applyTreasury();

        assertEq(router.treasury(), treasury, "treasury unchanged one second early");
    }

    /// @notice The boundary must be inclusive: exactly at `eta` the change becomes applicable.
    function test_ApplyExactlyAtEtaSucceeds() public {
        vm.prank(admin);
        router.proposeTreasury(attackerTreasury);
        (, uint64 eta) = router.pendingTreasury();

        vm.warp(eta);
        router.applyTreasury();

        assertEq(router.treasury(), attackerTreasury, "applicable from the moment of expiry");
    }

    /// @notice ATTACK: apply a change that was cancelled (002 FR-011).
    function test_AttackFails_ApplyCancelledChange() public {
        vm.startPrank(admin);
        router.proposeTreasury(attackerTreasury);
        router.cancelTreasury();
        vm.stopPrank();

        warpPastDelay();

        vm.expectRevert(TopUpRouter.NoPendingChange.selector);
        router.applyTreasury();
        assertEq(router.treasury(), treasury, "cancelled change is permanently dead");
    }

    /// @notice ATTACK: cancel then re-propose, hoping the new proposal inherits elapsed time.
    function test_AttackFails_ReproposeDoesNotInheritElapsedTime() public {
        vm.prank(admin);
        router.proposeTreasury(attackerTreasury);

        vm.warp(block.timestamp + DELAY - 1); // one second short

        vm.startPrank(admin);
        router.cancelTreasury();
        router.proposeTreasury(attackerTreasury);
        vm.stopPrank();

        (, uint64 eta) = router.pendingTreasury();
        assertEq(eta, block.timestamp + DELAY, "full fresh window, no inherited time");

        // Still not applicable now, despite the earlier proposal nearly maturing.
        vm.expectRevert(
            abi.encodeWithSelector(TopUpRouter.TimelockNotElapsed.selector, block.timestamp, eta)
        );
        router.applyTreasury();
    }

    /// @notice ATTACK: spam proposals hoping one matures early. Each restarts the clock.
    function test_AttackFails_RepeatedProposalsNeverShortenTheWait() public {
        uint256 start = block.timestamp;

        vm.startPrank(admin);
        for (uint256 i = 0; i < 10; i++) {
            router.proposeTreasury(attackerTreasury);
            vm.warp(block.timestamp + 4 hours);
        }
        vm.stopPrank();

        (, uint64 eta) = router.pendingTreasury();
        assertGe(eta, start + DELAY, "never matures earlier than 2 days from the first proposal");

        vm.expectRevert(
            abi.encodeWithSelector(TopUpRouter.TimelockNotElapsed.selector, block.timestamp, eta)
        );
        router.applyTreasury();
    }

    /// @notice The delay holds for any elapsed time short of the full window.
    function testFuzz_AttackFails_ApplyBeforeEtaAlwaysReverts(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, DELAY - 1);

        vm.prank(admin);
        router.proposeTreasury(attackerTreasury);
        (, uint64 eta) = router.pendingTreasury();

        vm.warp(block.timestamp + elapsed);

        vm.expectRevert(
            abi.encodeWithSelector(TopUpRouter.TimelockNotElapsed.selector, block.timestamp, eta)
        );
        router.applyTreasury();
        assertEq(router.treasury(), treasury, "unchanged for any wait under 2 days");
    }

    /*//////////////////////////////////////////////////////////////
        T052: THE AUTHORITY-SWAP BYPASS (002 FR-017)
    //////////////////////////////////////////////////////////////*/

    /// @notice ATTACK: the reason 002 FR-017 exists.
    ///
    /// An attacker who compromises `admin` tries to escape the 2-day treasury delay by first
    /// making themselves the authority. If authority transfer were instant, they would swap
    /// themselves in and rotate the treasury in a single transaction, and the delay protecting
    /// the treasury would be worth nothing.
    ///
    /// The defence is that authority transfer carries the SAME delay. There is no route to the
    /// treasury shorter than 2 days.
    function test_AttackFails_AuthoritySwapCannotShortcutTreasuryDelay() public {
        uint256 t0 = block.timestamp;

        // Step 1: attacker (holding the compromised admin key) proposes themselves as authority.
        vm.prank(admin);
        router.proposeAdmin(attacker);

        // Step 2: try to apply it immediately. Blocked, and for the RIGHT reason.
        (, uint64 adminEta) = router.pendingAdmin();
        vm.expectRevert(
            abi.encodeWithSelector(
                TopUpRouter.TimelockNotElapsed.selector, block.timestamp, adminEta
            )
        );
        router.applyAdmin();
        assertEq(router.admin(), admin, "authority cannot change instantly");

        // Step 3: even one second short of 2 days, still blocked.
        vm.warp(t0 + DELAY - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TopUpRouter.TimelockNotElapsed.selector, block.timestamp, adminEta
            )
        );
        router.applyAdmin();
        assertEq(router.treasury(), treasury, "treasury untouched after nearly 2 days");

        // Step 4: at 2 days the attacker finally becomes admin.
        vm.warp(t0 + DELAY);
        router.applyAdmin();
        assertEq(router.admin(), attacker, "attacker is now the authority");

        // Step 5: but the treasury is STILL not theirs. It needs its own full 2 days.
        vm.prank(attacker);
        router.proposeTreasury(attackerTreasury);

        (, uint64 treasuryEta) = router.pendingTreasury();
        vm.expectRevert(
            abi.encodeWithSelector(
                TopUpRouter.TimelockNotElapsed.selector, block.timestamp, treasuryEta
            )
        );
        router.applyTreasury();
        assertEq(router.treasury(), treasury, "treasury still safe");

        // Step 6: only after a second full delay - 4 days total - can they redirect funds.
        vm.warp(block.timestamp + DELAY);
        router.applyTreasury();
        assertEq(router.treasury(), attackerTreasury, "succeeds only after 4 days total");
        assertEq(block.timestamp, t0 + 2 * DELAY, "the swap route is SLOWER, never faster");
    }

    /// @notice The core guarantee stated directly: no route changes the treasury inside 2 days.
    function test_AttackFails_NoRouteChangesTreasuryWithinTwoDays() public {
        uint256 t0 = block.timestamp;

        vm.startPrank(admin);
        router.proposeTreasury(attackerTreasury);
        router.proposeAdmin(attacker);
        router.proposePauser(attacker);
        vm.stopPrank();

        // Hammer every apply entry point at many points inside the window.
        for (uint256 elapsed = 0; elapsed < DELAY; elapsed += 6 hours) {
            vm.warp(t0 + elapsed);

            try router.applyTreasury() {
                revert("treasury applied inside the 2-day window");
            } catch {}
            try router.applyAdmin() {
                revert("admin applied inside the 2-day window");
            } catch {}
            try router.applyPauser() {
                revert("pauser applied inside the 2-day window");
            } catch {}

            assertEq(router.treasury(), treasury, "treasury unchanged throughout the window");
            assertEq(router.admin(), admin, "admin unchanged throughout the window");
        }
    }

    /// @notice ATTACK: run both proposals in parallel hoping they compound into a shortcut.
    ///         They do not - parallel proposals still each serve the full delay.
    function test_AttackFails_ParallelProposalsDoNotCompound() public {
        uint256 t0 = block.timestamp;

        vm.startPrank(admin);
        router.proposeTreasury(attackerTreasury);
        router.proposeAdmin(attacker);
        vm.stopPrank();

        vm.warp(t0 + DELAY);

        // Both mature at the same moment. That is not a bypass: the treasury rotation was itself
        // proposed by the legitimate admin and served its own full 2 days in the open.
        router.applyTreasury();
        router.applyAdmin();

        assertEq(block.timestamp - t0, DELAY, "still a full 2 days, never less");
    }

    /// @notice A compromised admin cannot reach funds already stranded in the router, ever.
    function test_AttackFails_CompromisedAdminCannotReachStrandedFunds() public {
        forceFundsInto(address(router), 250e18);

        vm.prank(admin);
        router.proposeAdmin(attacker);
        warpPastDelay();
        router.applyAdmin();

        vm.startPrank(attacker);
        router.proposeTreasury(attackerTreasury);
        vm.stopPrank();
        warpPastDelay();
        router.applyTreasury();

        assertEq(address(router).balance, 250e18, "stranded funds remain unreachable (INV-8)");
    }
}

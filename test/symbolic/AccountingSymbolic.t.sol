// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../src/TopUpRouter.sol";
import {Test} from "forge-std/Test.sol";

/// @title AccountingSymbolicTest
/// @notice T075: symbolic proof of the accounting identity (INV-1 / 001 FR-013).
/// @dev Constitution requires symbolic or formal tooling for accounting-critical components.
///      Run with: `halmos --contract AccountingSymbolicTest`
///
///      Fuzzing samples the input space; halmos reasons over ALL inputs symbolically, so a pass
///      here is a proof for every amount rather than evidence from 10,000 samples.
///
///      STATUS 2026-09-04: BLOCKED on a halmos limitation, not on a defect in these properties.
///      halmos 0.3.3 cannot construct TopUpRouter: `setUp()` fails with
///      "No successful path found in setUp()". Diagnosed by bisection — a trivial contract
///      deploys and verifies fine under the same halmos install, and a minimal probe that does
///      nothing but `new TopUpRouter(...)` reproduces the failure, so the blocker is constructor
///      deployment rather than these assertions.
///
///      Left in the tree deliberately: the properties are correct and this file should verify
///      unchanged once the tooling issue is resolved (newer halmos, or deploying via a factory).
///      Not wired into CI while it cannot run.
///
///      Meanwhile INV-1 is covered by test/invariant/AccountingInvariant.t.sol (256 runs x 12,800
///      calls, with forced-balance interference) and by 10,000-run fuzz tests in
///      test/unit/TopUp.t.sol. That is strong evidence, but it is sampling, not proof — which is
///      exactly the gap this file exists to close.
contract AccountingSymbolicTest is Test {
    TopUpRouter internal router;

    address internal treasury = address(0xBEEF);
    uint256 internal constant MIN_TOPUP = 1;

    function setUp() public {
        router = new TopUpRouter(treasury);
    }

    /// @notice For ANY single top-up, the credited amount equals what the treasury received and
    ///         equals the increase in the system total (001 FR-007, FR-013).
    function check_CreditEqualsTransferEqualsTotal(uint256 amount) public {
        address bene = address(0x1111);
        address payer = address(0xDEAD);

        vm.assume(amount >= MIN_TOPUP);
        vm.assume(amount < type(uint128).max);
        vm.deal(payer, amount);

        uint256 treasuryBefore = treasury.balance;
        uint256 creditedBefore = router.contributions(bene);
        uint256 totalBefore = router.totalRouted();

        vm.prank(payer);
        router.topUp{value: amount}(bene);

        assert(treasury.balance - treasuryBefore == amount);
        assert(router.contributions(bene) - creditedBefore == amount);
        assert(router.totalRouted() - totalBefore == amount);
    }

    /// @notice For ANY two top-ups to distinct beneficiaries, the sum of per-account totals
    ///         equals the system total (INV-1).
    function check_SumOfContributionsEqualsTotalRouted(uint256 a, uint256 b) public {
        address x = address(0x1111);
        address y = address(0x2222);
        address payer = address(0xDEAD);

        vm.assume(a >= MIN_TOPUP && a < type(uint96).max);
        vm.assume(b >= MIN_TOPUP && b < type(uint96).max);
        vm.deal(payer, a + b);

        vm.startPrank(payer);
        router.topUp{value: a}(x);
        router.topUp{value: b}(y);
        vm.stopPrank();

        assert(router.contributions(x) + router.contributions(y) == router.totalRouted());
    }

    /// @notice The router never retains value from a top-up, for ANY amount (001 FR-003).
    function check_RouterRetainsNothing(uint256 amount) public {
        address payer = address(0xDEAD);

        vm.assume(amount >= MIN_TOPUP);
        vm.assume(amount < type(uint128).max);
        vm.deal(payer, amount);

        vm.prank(payer);
        router.topUp{value: amount}(address(0x3333));

        assert(address(router).balance == 0);
    }
}

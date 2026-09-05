// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../src/TopUpRouter.sol";
import {BaseTest} from "../BaseTest.sol";

/// @title ArithmeticAttackTest
/// @notice 001 FR-014 / INV-2: boundary and accumulation behaviour must not wrap or saturate.
contract ArithmeticAttackTest is BaseTest {
    function test_BoundaryExactlyAtMinimumSucceeds() public {
        vm.prank(payer);
        router.topUp{value: MIN_TOPUP}(beneficiary);
        assertEq(router.contributions(beneficiary), MIN_TOPUP, "exact minimum accepted");
    }

    function test_BoundaryOneWeiBelowMinimumReverts() public {
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(TopUpRouter.BelowMinimum.selector, MIN_TOPUP - 1, MIN_TOPUP)
        );
        router.topUp{value: MIN_TOPUP - 1}(beneficiary);
    }

    function test_SingleWeiRevertsWhenBelowMinimum() public {
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(TopUpRouter.BelowMinimum.selector, 1, MIN_TOPUP));
        router.topUp{value: 1}(beneficiary);
    }

    /// @notice Totals accumulate correctly across many top-ups without wrapping.
    function test_ManyTopUpsAccumulateExactly() public {
        uint256 n = 50;
        uint256 each = 2e6;
        vm.deal(payer, n * each);

        vm.startPrank(payer);
        for (uint256 i = 0; i < n; i++) {
            router.topUp{value: each}(beneficiary);
        }
        vm.stopPrank();

        assertEq(router.contributions(beneficiary), n * each, "no drift over many top-ups");
        assertEq(router.totalRouted(), n * each, "system total matches");
    }

    /// @notice A very large single top-up is handled without overflow.
    function test_VeryLargeAmountDoesNotOverflow() public {
        uint256 huge = 1e30;
        vm.deal(payer, huge);

        vm.prank(payer);
        router.topUp{value: huge}(beneficiary);

        assertEq(router.contributions(beneficiary), huge, "large amount credited exactly");
        assertEq(router.totalRouted(), huge, "system total exact");
    }

    /// @notice INV-2: totals are monotonically non-decreasing across arbitrary sequences.
    function testFuzz_TotalsAreMonotonic(uint256 a, uint256 b) public {
        a = bound(a, MIN_TOPUP, 100e6);
        b = bound(b, MIN_TOPUP, 100e6);

        vm.startPrank(payer);
        router.topUp{value: a}(beneficiary);
        uint256 afterFirst = router.totalRouted();
        router.topUp{value: b}(beneficiary);
        vm.stopPrank();

        assertGe(router.totalRouted(), afterFirst, "totalRouted never decreases");
        assertEq(router.totalRouted(), a + b, "exact sum");
    }
}

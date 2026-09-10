// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../src/TopUpRouter.sol";
import {BaseTest} from "../BaseTest.sol";

/// @title TopUpTest
/// @notice US1 core behaviour: 001 FR-001..FR-009.
contract TopUpTest is BaseTest {
    event ToppedUp(
        address indexed payer,
        address indexed beneficiary,
        uint256 amount,
        address treasury,
        uint256 newTotal
    );

    function test_RoutesFullAmountToTreasury() public {
        uint256 amount = 10e18;
        uint256 before = treasury.balance;

        vm.prank(payer);
        router.topUp{value: amount}(beneficiary);

        assertEq(treasury.balance - before, amount, "treasury must receive the full amount");
    }

    /// @dev 001 FR-003: nothing attributable to top-ups is retained.
    function test_RouterRetainsNothing() public {
        vm.prank(payer);
        router.topUp{value: 10e18}(beneficiary);
        assertEq(address(router).balance, 0, "router must retain nothing");
    }

    function test_CreditsBeneficiaryNotPayer() public {
        uint256 amount = 5e18;
        vm.prank(payer);
        router.topUp{value: amount}(beneficiary);

        assertEq(router.contributions(beneficiary), amount, "beneficiary credited");
        assertEq(router.contributions(payer), 0, "payer not credited");
        assertEq(router.totalRouted(), amount, "system total");
    }

    function test_EmitsToppedUpWithAllFields() public {
        uint256 amount = 3e18;
        vm.expectEmit(true, true, true, true, address(router));
        emit ToppedUp(payer, beneficiary, amount, treasury, amount);

        vm.prank(payer);
        router.topUp{value: amount}(beneficiary);
    }

    /// @dev 001 FR-010: newTotal is the post-state so an indexer can detect gaps.
    function test_RepeatTopUpsAccumulate() public {
        vm.startPrank(payer);
        router.topUp{value: 2e18}(beneficiary);
        router.topUp{value: 3e18}(beneficiary);
        vm.stopPrank();

        assertEq(router.contributions(beneficiary), 5e18, "totals accumulate");
        assertEq(router.totalRouted(), 5e18, "system total accumulates");
    }

    function test_TopUpSelfCreditsCaller() public {
        vm.prank(payer);
        router.topUpSelf{value: 4e18}();
        assertEq(router.contributions(payer), 4e18, "self top-up credits caller");
    }

    function test_RevertWhen_ZeroAmount() public {
        vm.prank(payer);
        vm.expectRevert(TopUpRouter.ZeroAmount.selector);
        router.topUp{value: 0}(beneficiary);
    }

    function test_RevertWhen_BelowMinimum() public {
        uint256 amount = MIN_TOPUP - 1;
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(TopUpRouter.BelowMinimum.selector, amount, MIN_TOPUP)
        );
        router.topUp{value: amount}(beneficiary);
    }

    function test_RevertWhen_ZeroBeneficiary() public {
        vm.prank(payer);
        vm.expectRevert(TopUpRouter.ZeroBeneficiary.selector);
        router.topUp{value: 10e18}(address(0));
    }

    function test_FailedTopUpChangesNothing() public {
        vm.prank(payer);
        vm.expectRevert(TopUpRouter.ZeroBeneficiary.selector);
        router.topUp{value: 10e18}(address(0));

        assertEq(router.totalRouted(), 0, "no state change on failure");
        assertEq(payer.balance, STARTING_BALANCE, "payer keeps funds");
    }

    /// @dev 001 FR-007: credited amount always equals the amount transferred to treasury.
    function testFuzz_CreditedEqualsTransferred(uint256 amount, address who) public {
        amount = bound(amount, MIN_TOPUP, 100e18);
        vm.assume(who != address(0));
        vm.assume(who != treasury);
        vm.assume(uint160(who) > 20); // exclude precompiles

        uint256 treasuryBefore = treasury.balance;
        uint256 creditedBefore = router.contributions(who);

        vm.prank(payer);
        router.topUp{value: amount}(who);

        assertEq(treasury.balance - treasuryBefore, amount, "transferred");
        assertEq(router.contributions(who) - creditedBefore, amount, "credited");
        assertEq(address(router).balance, 0, "nothing retained");
    }

    function testFuzz_RevertWhen_BelowMinimum(uint256 amount) public {
        amount = bound(amount, 1, MIN_TOPUP - 1);
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(TopUpRouter.BelowMinimum.selector, amount, MIN_TOPUP)
        );
        router.topUp{value: amount}(beneficiary);
    }

    /*//////////////////////////////////////////////////////////////
              US3: SPONSORED / THIRD-PARTY TOP-UPS (001 FR-006)
    //////////////////////////////////////////////////////////////*/

    /// @dev The record must distinguish who PAID from who was CREDITED.
    function test_Sponsored_EventNamesPayerAndBeneficiaryDistinctly() public {
        uint256 amount = 7e18;

        vm.expectEmit(true, true, true, true, address(router));
        emit ToppedUp(payer, beneficiary, amount, treasury, amount);

        vm.prank(payer);
        router.topUp{value: amount}(beneficiary);

        assertTrue(payer != beneficiary, "precondition: distinct actors");
    }

    /// @dev A sponsor funding many people must not cross-contaminate their totals.
    function test_Sponsored_ManyBeneficiariesAccumulateIndependently() public {
        address a = makeAddr("recipientA");
        address b = makeAddr("recipientB");
        address c = makeAddr("recipientC");

        vm.startPrank(payer);
        router.topUp{value: 1e18}(a);
        router.topUp{value: 2e18}(b);
        router.topUp{value: 3e18}(c);
        router.topUp{value: 4e18}(a);
        vm.stopPrank();

        assertEq(router.contributions(a), 5e18, "A credited 1 + 4");
        assertEq(router.contributions(b), 2e18, "B credited 2");
        assertEq(router.contributions(c), 3e18, "C credited 3");
        assertEq(router.contributions(payer), 0, "sponsor never credited");
        assertEq(router.totalRouted(), 10e18, "system total is the sum");
    }

    /// @dev Several sponsors funding one beneficiary accumulate onto that one account.
    function test_Sponsored_MultipleSponsorsFundOneBeneficiary() public {
        vm.prank(payer);
        router.topUp{value: 3e18}(beneficiary);

        vm.prank(stranger);
        router.topUp{value: 5e18}(beneficiary);

        assertEq(router.contributions(beneficiary), 8e18, "credits from both sponsors");
        assertEq(router.contributions(payer), 0, "sponsor 1 uncredited");
        assertEq(router.contributions(stranger), 0, "sponsor 2 uncredited");
    }

    /// @dev Edge case: paying for yourself via `topUp(msg.sender)` must credit exactly ONCE,
    ///      not once as payer and again as beneficiary.
    function test_Sponsored_PayingForSelfCreditsExactlyOnce() public {
        vm.prank(payer);
        router.topUp{value: 6e18}(payer);

        assertEq(router.contributions(payer), 6e18, "credited once, not doubled");
        assertEq(router.totalRouted(), 6e18, "system total matches");
    }

    /// @dev `topUpSelf()` and `topUp(msg.sender)` must be equivalent.
    function test_Sponsored_TopUpSelfEquivalentToTopUpWithOwnAddress() public {
        vm.prank(payer);
        router.topUp{value: 5e18}(payer);

        vm.prank(stranger);
        router.topUpSelf{value: 5e18}();

        assertEq(
            router.contributions(payer), router.contributions(stranger), "both paths equivalent"
        );
    }

    /// @dev 001 FR-006: a sponsor's own total is NEVER touched when funding someone else.
    function testFuzz_Sponsored_PayerNeverCreditedWhenSponsoring(uint256 amount, address recipient)
        public
    {
        amount = bound(amount, MIN_TOPUP, 100e18);
        vm.assume(recipient != address(0));
        vm.assume(recipient != payer);
        vm.assume(recipient != treasury);
        vm.assume(uint160(recipient) > 20); // exclude precompiles

        vm.prank(payer);
        router.topUp{value: amount}(recipient);

        assertEq(router.contributions(payer), 0, "sponsor total untouched");
        assertEq(router.contributions(recipient), amount, "recipient credited in full");
    }

    /*//////////////////////////////////////////////////////////////
              003: UNCONDITIONAL AVAILABILITY & DENOMINATION
    //////////////////////////////////////////////////////////////*/

    /// @dev 003 FR-005: top-ups are accepted on identical terms for the entire life of the
    ///      contract. There is no pause and nothing that waits on time, so no timestamp can put
    ///      the router into a state where a valid top-up is refused. Spread across a century to
    ///      make the point that this is unconditional, not merely true near deployment.
    function test_TopUpsSucceedAtAnyPointInTime() public {
        uint256[5] memory times = [
            block.timestamp, block.timestamp + 1 days, 2_000_000_000, 3_000_000_000, 4_000_000_000
        ];

        for (uint256 i = 0; i < times.length; i++) {
            vm.warp(times[i]);
            vm.deal(payer, 10e18);

            vm.prank(payer);
            router.topUp{value: 2e18}(beneficiary);

            assertEq(
                router.contributions(beneficiary),
                2e18 * (i + 1),
                "top-up accepted on the same terms regardless of when it arrives"
            );
        }
    }

    /// @dev 003 FR-005: nor does the passage of time between top-ups change anything.
    function testFuzz_TimeNeverBlocksATopUp(uint64 timestamp) public {
        vm.assume(timestamp > 0);
        vm.warp(timestamp);

        vm.deal(payer, 10e18);
        vm.prank(payer);
        router.topUp{value: MIN_TOPUP}(beneficiary);

        assertEq(router.contributions(beneficiary), MIN_TOPUP, "no time-based refusal exists");
    }

    /// @dev 003 FR-006/FR-010: the boundary sits at exactly one whole USDC in 18-decimal base
    ///      units. Getting this scale wrong by 1e12 is what made the previous deployment unusable,
    ///      so the boundary is asserted in explicit units, not via a constant that could itself be
    ///      wrong.
    function test_MinimumBoundaryIsExactlyOneWholeUsdc() public {
        vm.deal(payer, 10e18);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TopUpRouter.BelowMinimum.selector,
                999_999_999_999_999_999,
                1_000_000_000_000_000_000
            )
        );
        router.topUp{value: 999_999_999_999_999_999}(beneficiary);

        vm.prank(payer);
        router.topUp{value: 1_000_000_000_000_000_000}(beneficiary);

        assertEq(
            router.contributions(beneficiary),
            1_000_000_000_000_000_000,
            "exactly 1.000000000000000000 USDC accepted"
        );
        assertEq(router.totalRouted(), 1_000_000_000_000_000_000, "recorded in base units");
    }
}

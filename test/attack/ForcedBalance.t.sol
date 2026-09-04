// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../BaseTest.sol";

/// @title ForcedBalanceAttackTest
/// @notice INV-9 / 001 FR-008: funds forced into the router must never affect accounting.
/// @dev Native funds can be pushed into any address via SELFDESTRUCT, which no code can refuse.
///      The defence is not to prevent it - that is impossible - but to never read
///      `address(this).balance`, so forced funds are invisible to the contract's logic.
contract ForcedBalanceAttackTest is BaseTest {
    /// @notice ATTACK: inflate the router's balance, hoping accounting reads it.
    function test_AttackFails_ForcedFundsDoNotAffectAccounting() public {
        forceFundsInto(address(router), 500e18);
        assertEq(address(router).balance, 500e18, "precondition: router holds forced funds");

        assertEq(router.totalRouted(), 0, "forced funds are not routed");
        assertEq(router.contributions(attacker), 0, "forced funds credit nobody");
    }

    /// @notice ATTACK: force funds first, then top up, hoping the credit is inflated.
    function test_AttackFails_TopUpAfterForcedFundsCreditsOnlyMsgValue() public {
        forceFundsInto(address(router), 500e18);

        uint256 amount = 10e18;
        uint256 treasuryBefore = treasury.balance;

        vm.prank(payer);
        router.topUp{value: amount}(beneficiary);

        assertEq(router.contributions(beneficiary), amount, "credited msg.value only");
        assertEq(router.totalRouted(), amount, "routed msg.value only");
        assertEq(treasury.balance - treasuryBefore, amount, "treasury got msg.value only");
        assertEq(address(router).balance, 500e18, "forced funds remain stranded, untouched");
    }

    /// @notice Forced funds must not brick the contract either: top-ups keep working.
    function test_ForcedFundsDoNotBreakSubsequentTopUps() public {
        forceFundsInto(address(router), 1e18);

        vm.startPrank(payer);
        router.topUp{value: 2e18}(beneficiary);
        router.topUp{value: 3e18}(beneficiary);
        vm.stopPrank();

        assertEq(router.contributions(beneficiary), 5e18, "accounting unaffected");
    }

    /// @notice Stranded funds are permanently unrecoverable, by design (001 FR-015).
    function test_StrandedFundsAreUnrecoverableByAnyRole() public {
        forceFundsInto(address(router), 100e18);

        // There is no function to call. Confirm a bare transfer/withdraw attempt fails for admin.
        vm.prank(admin);
        (bool ok,) = address(router).call(abi.encodeWithSignature("withdraw()"));
        assertFalse(ok, "no withdraw function exists");

        vm.prank(admin);
        (bool ok2,) = address(router).call(abi.encodeWithSignature("sweep(address)", admin));
        assertFalse(ok2, "no sweep function exists");

        assertEq(address(router).balance, 100e18, "funds remain stranded");
    }

    function testFuzz_ForcedFundsNeverAffectCredit(uint256 forced, uint256 amount) public {
        forced = bound(forced, 1, 1000e18);
        amount = bound(amount, MIN_TOPUP, 100e18);

        forceFundsInto(address(router), forced);

        vm.prank(payer);
        router.topUp{value: amount}(beneficiary);

        assertEq(router.contributions(beneficiary), amount, "credit equals msg.value exactly");
    }
}

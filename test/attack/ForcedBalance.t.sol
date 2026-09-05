// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../BaseTest.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title ForcedBalanceAttackTest
/// @notice INV-9 / 001 FR-008: funds forced into the router must never affect accounting.
/// @dev Native funds can be pushed into any address via SELFDESTRUCT, which no code can refuse.
///      The defence is not to prevent it - that is impossible - but to never read
///      `address(this).balance`, so forced funds are invisible to the contract's logic.
contract ForcedBalanceAttackTest is BaseTest {
    /// @notice ATTACK: inflate the router's balance, hoping accounting reads it.
    function test_AttackFails_ForcedFundsDoNotAffectAccounting() public {
        forceFundsInto(address(router), 500e6);
        assertEq(address(router).balance, 500e6, "precondition: router holds forced funds");

        assertEq(router.totalRouted(), 0, "forced funds are not routed");
        assertEq(router.contributions(attacker), 0, "forced funds credit nobody");
    }

    /// @notice ATTACK: force funds first, then top up, hoping the credit is inflated.
    function test_AttackFails_TopUpAfterForcedFundsCreditsOnlyMsgValue() public {
        forceFundsInto(address(router), 500e6);

        uint256 amount = 10e6;
        uint256 treasuryBefore = treasury.balance;

        vm.prank(payer);
        router.topUp{value: amount}(beneficiary);

        assertEq(router.contributions(beneficiary), amount, "credited msg.value only");
        assertEq(router.totalRouted(), amount, "routed msg.value only");
        assertEq(treasury.balance - treasuryBefore, amount, "treasury got msg.value only");
        assertEq(address(router).balance, 500e6, "forced funds remain stranded, untouched");
    }

    /// @notice Forced funds must not brick the contract either: top-ups keep working.
    function test_ForcedFundsDoNotBreakSubsequentTopUps() public {
        forceFundsInto(address(router), 1e6);

        vm.startPrank(payer);
        router.topUp{value: 2e6}(beneficiary);
        router.topUp{value: 3e6}(beneficiary);
        vm.stopPrank();

        assertEq(router.contributions(beneficiary), 5e6, "accounting unaffected");
    }

    /// @notice Stranded funds are permanently unrecoverable (003 FR-015).
    /// @dev There is no role left to try this from — that is the point. Under 002 this test asked
    ///      whether the admin could extract stranded funds; now there is no admin, so it asks
    ///      whether ANYONE can, which is the stronger question.
    function test_StrandedFundsAreUnrecoverableByAnyone() public {
        forceFundsInto(address(router), 100e6);

        vm.prank(attacker);
        (bool ok,) = address(router).call(abi.encodeWithSignature("withdraw()"));
        assertFalse(ok, "no withdraw function exists");

        vm.prank(attacker);
        (bool ok2,) = address(router).call(abi.encodeWithSignature("sweep(address)", attacker));
        assertFalse(ok2, "no sweep function exists");

        assertEq(address(router).balance, 100e6, "funds remain stranded");
    }

    function testFuzz_ForcedFundsNeverAffectCredit(uint256 forced, uint256 amount) public {
        forced = bound(forced, 1, 1000e6);
        amount = bound(amount, MIN_TOPUP, 100e6);

        forceFundsInto(address(router), forced);

        vm.prank(payer);
        router.topUp{value: amount}(beneficiary);

        assertEq(router.contributions(beneficiary), amount, "credit equals msg.value exactly");
    }

    /*//////////////////////////////////////////////////////////////
                   003 FR-017c: STRANDED ERC-20 TOKENS
    //////////////////////////////////////////////////////////////*/

    /// @dev 003 FR-017c. Native USDC is the only accepted payment, and there is no rescue path —
    ///      a rescue would need a privileged caller and a non-treasury outflow, the two things
    ///      FR-014 and FR-015 forbid. So a mis-sent token is lost, permanently.
    ///
    ///      This test pins that behaviour deliberately rather than leaving it as an untested
    ///      consequence. It is not asserting that losing funds is good; it is asserting that the
    ///      contract does not pretend otherwise, and that a future "helpful" rescue function would
    ///      break a test rather than slip through review. The mitigation lives in documentation
    ///      (003 FR-018), which is the only place it can live.
    function test_MisSentTokensAreStrandedAndAffectNothing() public {
        MockERC20 token = new MockERC20(stranger, 1000e6);

        vm.prank(stranger);
        token.transfer(address(router), 500e6);

        assertEq(token.balanceOf(address(router)), 500e6, "tokens arrived at the router");

        // The contribution record is untouched: no credit, no total.
        assertEq(router.contributions(stranger), 0, "sending a token credits nobody");
        assertEq(router.totalRouted(), 0, "token transfers never reach the routed total");

        // A native top-up afterwards behaves exactly as if the tokens were not there.
        vm.prank(payer);
        router.topUp{value: 5e6}(beneficiary);

        assertEq(router.contributions(beneficiary), 5e6, "native accounting is unaffected");
        assertEq(router.totalRouted(), 5e6, "totals count native USDC only");
        assertEq(token.balanceOf(address(router)), 500e6, "tokens remain stranded, untouched");
    }

    /// @dev And nobody can get them back — not the sender, not the treasury, not the deployer.
    function test_NoCallerCanRecoverMisSentTokens() public {
        MockERC20 token = new MockERC20(stranger, 1000e6);
        vm.prank(stranger);
        token.transfer(address(router), 500e6);

        address[3] memory callers = [stranger, treasury, address(this)];
        string[3] memory attempts =
            ["rescueTokens(address,uint256)", "sweepToken(address)", "withdraw()"];

        for (uint256 i = 0; i < callers.length; i++) {
            for (uint256 j = 0; j < attempts.length; j++) {
                vm.prank(callers[i]);
                (bool ok,) = address(router)
                    .call(abi.encodeWithSignature(attempts[j], address(token), uint256(500e6)));
                assertFalse(ok, "no recovery path exists for any caller");
            }
        }

        assertEq(token.balanceOf(address(router)), 500e6, "tokens are lost permanently");
    }
}

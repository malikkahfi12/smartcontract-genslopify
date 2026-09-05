// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../BaseTest.sol";

/// @title AccessControlAttackTest
/// @notice The adversarial suite for a contract with no access control to attack.
///
/// @dev 003 FR-014, SC-004a. Constitution Principle II requires access-control bypass tests:
///      "every privileged function called by an unauthorized address". There are no privileged
///      functions, so the requirement inverts. Instead of proving that outsiders are kept out,
///      this suite proves there is no inside — that no address is distinguishable from any other.
///
///      That is the stronger property, and it is worth testing rather than assuming. A privilege
///      can be reintroduced accidentally: an `onlyOwner` added for convenience, an inherited
///      OpenZeppelin module dragging in `owner()`, a constructor quietly stashing `msg.sender`.
///      Each of those would break SC-004a while every other test in the suite kept passing.
contract AccessControlAttackTest is BaseTest {
    /// @dev The deployer is the likeliest accidental privilege holder — it is the one address the
    ///      constructor sees. It must be as ordinary as anyone else.
    function test_DeployerHasNoStandingPrivilege() public {
        // `address(this)` deployed the router in setUp().
        vm.deal(address(this), 10e6);
        uint256 before = treasury.balance;

        router.topUp{value: 2e6}(beneficiary);

        assertEq(treasury.balance - before, 2e6, "deployer's top-up behaves like anyone else's");
        assertEq(router.contributions(beneficiary), 2e6, "credited on the same terms");
    }

    /// @dev The treasury is named in the contract, which makes it the second-likeliest accidental
    ///      privilege holder. Being the destination confers nothing.
    function test_TreasuryHasNoStandingPrivilege() public {
        vm.deal(treasury, 10e6);
        vm.prank(treasury);
        router.topUp{value: 2e6}(beneficiary);

        assertEq(router.contributions(beneficiary), 2e6, "treasury is just another caller");
    }

    /// @dev SC-004a stated directly: the full surface behaves identically for any two callers.
    ///      Two arbitrary addresses, same inputs, same observable outcome.
    function testFuzz_EveryCallerIsEquivalent(address callerA, address callerB) public {
        vm.assume(callerA != address(0) && callerB != address(0));
        vm.assume(callerA != treasury && callerB != treasury);
        vm.assume(callerA != address(router) && callerB != address(router));
        vm.assume(callerA.code.length == 0 && callerB.code.length == 0);

        address benA = makeAddr("benA");
        address benB = makeAddr("benB");

        vm.deal(callerA, 10e6);
        vm.prank(callerA);
        router.topUp{value: 3e6}(benA);

        vm.deal(callerB, 10e6);
        vm.prank(callerB);
        router.topUp{value: 3e6}(benB);

        assertEq(
            router.contributions(benA),
            router.contributions(benB),
            "identical inputs from different callers produce identical results"
        );
    }

    /// @dev The same equivalence on the failure side: a rejected top-up is rejected for everyone,
    ///      for the same reason. No caller gets a waiver on the minimum.
    function testFuzz_MinimumAppliesToEveryCallerAlike(address caller) public {
        vm.assume(caller != address(0) && caller.code.length == 0);
        vm.assume(caller != address(router));

        vm.deal(caller, 10e6);
        vm.prank(caller);
        vm.expectRevert();
        router.topUp{value: MIN_TOPUP - 1}(beneficiary);
    }

    /// @dev 003 FR-015: no caller — deployer, treasury, or stranger — can extract stranded funds.
    ///      Complements Immutability.t.sol: that file proves no extraction FUNCTION exists; this
    ///      proves no CALLER can drain the contract by any means available to them.
    function test_NoCallerCanExtractStrandedFunds() public {
        forceFundsInto(address(router), 100e6);
        assertEq(address(router).balance, 100e6, "precondition: router holds stranded funds");

        address[3] memory callers = [address(this), treasury, attacker];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            (bool ok,) = address(router).call(abi.encodeWithSignature("withdraw()"));
            assertFalse(ok, "no caller has a withdrawal path");
        }

        assertEq(address(router).balance, 100e6, "stranded funds remain unreachable");
    }

    /// @dev Stranded funds stay out of the accounting no matter who tops up afterwards.
    function test_StrandedFundsNeverEnterAccountingForAnyCaller() public {
        forceFundsInto(address(router), 50e6);

        vm.prank(attacker);
        router.topUp{value: 5e6}(beneficiary);

        assertEq(router.contributions(beneficiary), 5e6, "credited msg.value only");
        assertEq(router.totalRouted(), 5e6, "totals ignore the forced balance");
        assertEq(address(router).balance, 50e6, "stranded funds untouched");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../BaseTest.sol";

/// @title ImmutabilityTest
/// @notice Proves that the removed and forbidden surfaces are ABSENT, not merely guarded.
///
/// @dev 003 FR-001, FR-002, FR-004, FR-014, FR-014a, FR-015, FR-016, FR-017a/b. SC-002.
///
///      Why this file exists in this shape (research R-005): a test asserting that
///      `proposeTreasury(...)` reverts proves almost nothing — a function that exists and reverts
///      with `NotAdmin` passes it too, and that is exactly the state we are trying to rule out.
///      The spec's claim is stronger: these operations DO NOT EXIST.
///
///      The probe below distinguishes the two. With no `receive` and no `fallback`, a call
///      carrying an unrecognised selector cannot be dispatched at all and reverts with EMPTY
///      returndata. A function that exists and reverts returns a 4-byte error selector, or a
///      revert string, or — for a successful view — the encoded value. So: empty returndata plus
///      failure means absent; anything else means present. That is the assertion.
contract ImmutabilityTest is BaseTest {
    /// @dev Asserts `signature` names no function on the router.
    ///      A present-but-reverting function fails this, and so does a present view that succeeds.
    function assertSelectorAbsent(string memory signature) internal {
        (bool ok, bytes memory ret) = address(router).call(abi.encodeWithSignature(signature));

        assertFalse(ok, string.concat("selector must not be callable: ", signature));
        assertEq(
            ret.length,
            0,
            string.concat(
                "selector EXISTS (it returned error/revert data) but must be absent: ", signature
            )
        );
    }

    /// @dev Sanity check on the probe itself. Without this, a broken probe would silently pass
    ///      every assertion in the file and prove nothing at all.
    function test_ProbeDetectsAFunctionThatDoesExist() public {
        // `treasury()` exists and succeeds, so it must return data — the probe must NOT call it
        // absent.
        (bool ok, bytes memory ret) = address(router).call(abi.encodeWithSignature("treasury()"));
        assertTrue(ok, "control: treasury() exists and succeeds");
        assertGt(ret.length, 0, "control: an existing function returns data");

        // And a genuinely absent selector must produce the opposite.
        (bool ok2, bytes memory ret2) =
            address(router).call(abi.encodeWithSignature("thisFunctionNeverExisted()"));
        assertFalse(ok2, "control: an absent selector cannot be called");
        assertEq(ret2.length, 0, "control: an absent selector returns no data");
    }

    /*//////////////////////////////////////////////////////////////
                    REMOVED: TREASURY GOVERNANCE (T013)
    //////////////////////////////////////////////////////////////*/

    /// @dev 003 FR-001/FR-002: the destination is fixed and no proposal flow survives.
    function test_TreasuryGovernanceIsAbsent() public {
        assertSelectorAbsent("proposeTreasury(address)");
        assertSelectorAbsent("applyTreasury()");
        assertSelectorAbsent("cancelTreasury()");
        assertSelectorAbsent("pendingTreasury()");
        assertSelectorAbsent("setTreasury(address)");
    }

    /// @dev 003 FR-014a: nothing waits on time any more, so the delay constant is gone too.
    function test_TimelockMechanismIsAbsent() public {
        assertSelectorAbsent("DELAY()");
        assertSelectorAbsent("pendingAdmin()");
        assertSelectorAbsent("pendingPauser()");
    }

    /*//////////////////////////////////////////////////////////////
                      REMOVED: ROLES AND PAUSE (T021)
    //////////////////////////////////////////////////////////////*/

    /// @dev 003 FR-004: no operation halts top-ups, and no state records that they are halted.
    function test_PauseSurfaceIsAbsent() public {
        assertSelectorAbsent("pause()");
        assertSelectorAbsent("unpause()");
        assertSelectorAbsent("paused()");
    }

    /// @dev 003 FR-014: no address confers privilege, so no getter reports who holds one.
    function test_RoleSurfaceIsAbsent() public {
        assertSelectorAbsent("admin()");
        assertSelectorAbsent("pauser()");
        assertSelectorAbsent("owner()");
        assertSelectorAbsent("multisigEstablished()");
        assertSelectorAbsent("proposeAdmin(address)");
        assertSelectorAbsent("applyAdmin()");
        assertSelectorAbsent("cancelAdmin()");
        assertSelectorAbsent("proposePauser(address)");
        assertSelectorAbsent("applyPauser()");
        assertSelectorAbsent("cancelPauser()");
        assertSelectorAbsent("transferOwnership(address)");
        assertSelectorAbsent("renounceOwnership()");
    }

    /*//////////////////////////////////////////////////////////////
              NEVER EXISTED, MUST NEVER EXIST (T013a)
    //////////////////////////////////////////////////////////////*/

    /// @dev 003 FR-015 — the central guarantee. Every other absence in this file removes a feature
    ///      that once existed; this one guards a line that has never been crossed and must not be.
    ///      No function moves value out of this contract to anyone but the treasury, and the only
    ///      way to reach the treasury is by paying into it.
    ///
    ///      This test is the difference between the guarantee being true and merely being claimed
    ///      in a comment. Do not delete it to make room for a "temporary" rescue helper.
    function test_NoFundExtractionPathExists() public {
        assertSelectorAbsent("withdraw()");
        assertSelectorAbsent("withdraw(uint256)");
        assertSelectorAbsent("withdrawAll()");
        assertSelectorAbsent("sweep()");
        assertSelectorAbsent("sweep(address)");
        assertSelectorAbsent("sweepToken(address)");
        assertSelectorAbsent("rescue(address)");
        assertSelectorAbsent("rescueTokens(address,uint256)");
        assertSelectorAbsent("rescueERC20(address,uint256)");
        assertSelectorAbsent("emergencyWithdraw()");
        assertSelectorAbsent("execute(address,uint256,bytes)");
        assertSelectorAbsent("call(address,bytes)");
    }

    /// @dev 003 FR-016: immutable and non-upgradeable. No proxy hook, no initializer.
    function test_NoUpgradePathExists() public {
        assertSelectorAbsent("upgradeTo(address)");
        assertSelectorAbsent("upgradeToAndCall(address,bytes)");
        assertSelectorAbsent("initialize(address)");
        assertSelectorAbsent("implementation()");
        assertSelectorAbsent("proxiableUUID()");
        assertSelectorAbsent("UPGRADE_INTERFACE_VERSION()");
    }

    /// @dev 003 FR-017a/b: native USDC only. No token is named, accepted, or configured anywhere.
    function test_NoTokenSurfaceExists() public {
        assertSelectorAbsent("token()");
        assertSelectorAbsent("usdc()");
        assertSelectorAbsent("acceptedTokens(address)");
        assertSelectorAbsent("addToken(address)");
        assertSelectorAbsent("setToken(address)");
        assertSelectorAbsent("topUpWithToken(address,address,uint256)");
        assertSelectorAbsent("onERC20Received(address,uint256)");
        assertSelectorAbsent("onERC721Received(address,address,uint256,bytes)");
    }

    /// @dev 003 FR-015/FR-017c: no `receive` or `fallback`, so nothing can be pushed in by a bare
    ///      transfer and no unmatched call is silently swallowed.
    function test_NoReceiveOrFallbackExists() public {
        vm.deal(stranger, 10e18);
        vm.prank(stranger);
        (bool bare,) = address(router).call{value: 1e18}("");
        assertFalse(bare, "bare value transfer must revert: no receive");

        vm.prank(stranger);
        (bool garbage,) = address(router).call(hex"deadbeef");
        assertFalse(garbage, "unmatched calldata must revert: no fallback");
    }
}

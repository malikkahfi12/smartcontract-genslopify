// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../src/TopUpRouter.sol";
import {BaseTest} from "../BaseTest.sol";

/// @title DeploymentTest
/// @notice The contract deploys from one argument and every getter reports the expected state.
/// @dev 003 FR-003, FR-006, FR-014b. What this suite does NOT assert is as important as what it
///      does: there is no role to wire, no minimum to configure, and no pending change to be
///      empty, because none of those exist. Their absence is proved in Immutability.t.sol.
contract DeploymentTest is BaseTest {
    function test_ConstructorSetsTreasury() public view {
        assertEq(router.treasury(), treasury, "treasury is the sole constructor argument");
    }

    /// @dev 003 FR-006: the minimum is a compile-time constant, identical in every build.
    function test_MinimumIsOneWholeUsdcAtSixDecimals() public view {
        assertEq(router.MIN_TOPUP(), MIN_TOPUP, "minimum matches the harness constant");
        assertEq(router.MIN_TOPUP(), 1e6, "one whole USDC at Arc's 6 decimals");
        assertEq(router.MIN_TOPUP(), 1_000_000, "stated in base units, unambiguously");
    }

    /// @dev A deployment at any other address reports the same constant: it is not per-deployment.
    function test_MinimumIsIdenticalAcrossDeployments() public {
        TopUpRouter other = new TopUpRouter(makeAddr("otherTreasury"));
        assertEq(other.MIN_TOPUP(), router.MIN_TOPUP(), "constant, not a deployment parameter");
    }

    function test_AccountingStartsEmpty() public view {
        assertEq(router.totalRouted(), 0, "totalRouted");
        assertEq(router.contributions(beneficiary), 0, "never-credited account reads zero");
    }

    function test_RevertWhen_ConstructorGivenZeroAddress() public {
        vm.expectRevert(TopUpRouter.ZeroAddress.selector);
        new TopUpRouter(address(0));
    }

    /// @dev A router pointed at itself would strand every top-up it ever accepted.
    function test_RevertWhen_ConstructorGivenSelfAddress() public {
        // The deployed address is deterministic from deployer + nonce, so precompute it and hand
        // the constructor its own address.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(TopUpRouter.SelfAddress.selector);
        new TopUpRouter(predicted);
    }

    /// @dev A contract treasury is legitimate — a Safe is the intended production destination.
    function test_ContractTreasuryIsAccepted() public {
        TopUpRouter r = new TopUpRouter(address(this));
        assertEq(r.treasury(), address(this), "a contract treasury is valid");
    }

    /// @dev 003 FR-015: no receive/fallback exists, so a bare value transfer must revert.
    function test_RevertWhen_BareValueTransferSent() public {
        vm.prank(payer);
        (bool ok,) = address(router).call{value: 1e6}("");
        assertFalse(ok, "bare transfer must be rejected: no receive/fallback");
    }
}

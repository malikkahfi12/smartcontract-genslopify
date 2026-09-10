// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Deploy} from "../../script/Deploy.s.sol";
import {TopUpRouter} from "../../src/TopUpRouter.sol";
import {Test} from "forge-std/Test.sol";

/// @title DeployScriptTest
/// @notice The deploy script must refuse an unsafe configuration BEFORE broadcasting.
/// @dev 003 FR-011, FR-012, FR-013.
contract DeployScriptTest is Test {
    Deploy internal deployer;

    address internal treasury = makeAddr("t");

    function setUp() public {
        deployer = new Deploy();
        vm.chainId(5_042_002); // Arc testnet
    }

    function test_AcceptsValidArcTestnetConfiguration() public view {
        deployer.validate(treasury);
    }

    /// @dev Constitution Principle VI: never deploy to an unintended network.
    function test_RevertWhen_WrongNetwork() public {
        vm.chainId(1); // Ethereum mainnet
        vm.expectRevert(abi.encodeWithSelector(Deploy.WrongNetwork.selector, 1, 5_042_002));
        deployer.validate(treasury);
    }

    /// @dev 003 FR-013: refusal must name the missing parameter, so the operator can act on it.
    function test_RevertWhen_TreasuryMissing() public {
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.MissingParameter.selector, "TREASURY_ADDRESS")
        );
        deployer.validate(address(0));
    }

    /// @dev 003 FR-014b: validate takes exactly one argument. A leftover `ADMIN_ADDRESS`,
    ///      `PAUSER_ADDRESS`, or `MIN_TOPUP_WEI` in the operator's environment is never read, so
    ///      it cannot reach the deployed contract (US3 scenario 2). This test states that
    ///      structurally: the deployed router's surface has no field any of them could occupy,
    ///      and its minimum is a constant no environment value can influence.
    function test_LeftoverEnvironmentValuesCannotReachTheContract() public {
        vm.setEnv("ADMIN_ADDRESS", "0x000000000000000000000000000000000000dEaD");
        vm.setEnv("PAUSER_ADDRESS", "0x000000000000000000000000000000000000bEEF");
        vm.setEnv("MIN_TOPUP_WEI", "999000000000000000000");

        TopUpRouter router = new TopUpRouter(treasury);

        assertEq(router.treasury(), treasury, "treasury unaffected by leftover values");
        assertEq(router.MIN_TOPUP(), 1e18, "minimum is a constant, not read from the environment");
    }
}

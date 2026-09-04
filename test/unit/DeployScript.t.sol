// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Deploy} from "../../script/Deploy.s.sol";
import {Test} from "forge-std/Test.sol";

/// @title DeployScriptTest
/// @notice T066: the deploy script must refuse an unsafe configuration BEFORE broadcasting.
contract DeployScriptTest is Test {
    Deploy internal deployer;

    address internal treasury = makeAddr("t");
    address internal admin = makeAddr("a");
    address internal pauser = makeAddr("p");
    uint256 internal constant MIN_TOPUP = 1e18;

    function setUp() public {
        deployer = new Deploy();
        vm.chainId(5_042_002); // Arc testnet
    }

    function test_AcceptsValidArcTestnetConfiguration() public view {
        deployer.validate(treasury, admin, pauser, MIN_TOPUP);
    }

    /// @dev The deployment decision of 2026-09-04: pauser must be a separate key from admin.
    function test_RevertWhen_PauserEqualsAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.PauserMustDifferFromAdmin.selector, admin));
        deployer.validate(treasury, admin, admin, MIN_TOPUP);
    }

    /// @dev Constitution Principle VI: never deploy to an unintended network.
    function test_RevertWhen_WrongNetwork() public {
        vm.chainId(1); // Ethereum mainnet
        vm.expectRevert(abi.encodeWithSelector(Deploy.WrongNetwork.selector, 1, 5_042_002));
        deployer.validate(treasury, admin, pauser, MIN_TOPUP);
    }

    function test_RevertWhen_AnyParameterMissing() public {
        vm.expectRevert();
        deployer.validate(address(0), admin, pauser, MIN_TOPUP);

        vm.expectRevert();
        deployer.validate(treasury, address(0), pauser, MIN_TOPUP);

        vm.expectRevert();
        deployer.validate(treasury, admin, address(0), MIN_TOPUP);

        vm.expectRevert();
        deployer.validate(treasury, admin, pauser, 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../src/TopUpRouter.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title ProposeHandover
/// @notice Propose transferring administrative authority from the primary key to a multisig.
/// @dev This is step one of two. The handover is itself timelocked (002 FR-017/FR-023a), so it
///      does NOT take effect for 2 days. Call `applyAdmin()` after the delay - anyone may call it.
///      Until then the primary key retains authority and may cancel with `cancelAdmin()`.
contract ProposeHandover is Script {
    error TargetHasNoCode(address target);
    error AlreadyHandedOver();

    function run() external {
        TopUpRouter router = TopUpRouter(vm.envAddress("ROUTER_ADDRESS"));
        address multisig = vm.envAddress("MULTISIG_ADDRESS");

        if (router.multisigEstablished()) revert AlreadyHandedOver();

        // The router checks this at apply time; failing here gives the operator the error two days
        // earlier, when it is still cheap to fix.
        if (multisig.code.length == 0) revert TargetHasNoCode(multisig);

        vm.startBroadcast();
        router.proposeAdmin(multisig);
        vm.stopBroadcast();

        (address pendingTarget, uint64 eta) = router.pendingAdmin();
        console2.log("Handover proposed to:", pendingTarget);
        console2.log("Applicable from (unix):", eta);
        console2.log("Until then the primary key still governs and may call cancelAdmin().");
    }
}

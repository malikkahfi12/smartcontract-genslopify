// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../src/TopUpRouter.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title Deploy
/// @notice Deterministic deployment of TopUpRouter to Arc.
/// @dev Constitution Principle VI: no chain id or address is hardcoded in `src/`. All deployment
///      parameters come from the environment, and the network is validated before broadcasting.
///      Constitution (Secrets): sign with an encrypted keystore (`--account`) or a hardware
///      wallet (`--ledger` / `--trezor`). Never pass a literal private key outside local anvil.
///      Walkthrough: docs/DEPLOYMENT.md
contract Deploy is Script {
    /// @dev Arc testnet, confirmed by the T082 opcode probe on 2026-09-04.
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5_042_002;

    error WrongNetwork(uint256 actual, uint256 expected);
    error PauserMustDifferFromAdmin(address shared);
    error MissingParameter(string name);

    function run() external returns (TopUpRouter router) {
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address pauser = vm.envAddress("PAUSER_ADDRESS");
        uint256 minTopUp = vm.envUint("MIN_TOPUP_WEI");

        validate(treasury, admin, pauser, minTopUp);

        vm.startBroadcast();
        router = new TopUpRouter(treasury, admin, pauser, minTopUp);
        vm.stopBroadcast();

        _report(router, treasury, admin, pauser, minTopUp);
    }

    /// @notice All pre-broadcast checks. Public so tests can exercise them without broadcasting.
    function validate(address treasury, address admin, address pauser, uint256 minTopUp)
        public
        view
    {
        if (block.chainid != ARC_TESTNET_CHAIN_ID) {
            revert WrongNetwork(block.chainid, ARC_TESTNET_CHAIN_ID);
        }

        if (treasury == address(0)) revert MissingParameter("TREASURY_ADDRESS");
        if (admin == address(0)) revert MissingParameter("ADMIN_ADDRESS");
        if (pauser == address(0)) revert MissingParameter("PAUSER_ADDRESS");
        if (minTopUp == 0) revert MissingParameter("MIN_TOPUP_WEI");

        // Deployment decision recorded 2026-09-04: the testnet pauser is a SEPARATE key from
        // admin, so 002 FR-024's role separation is real on the deployed contract rather than
        // proven only in unit tests. Enforced here rather than in TopUpRouter, because FR-024
        // requires the authorities be *separable*, not always distinct - a deployment where they
        // coincide stays a legitimate configuration the immutable contract must not forbid.
        if (pauser == admin) revert PauserMustDifferFromAdmin(pauser);
    }

    function _report(
        TopUpRouter router,
        address treasury,
        address admin,
        address pauser,
        uint256 minTopUp
    ) internal pure {
        console2.log("TopUpRouter deployed:", address(router));
        console2.log("  treasury: ", treasury);
        console2.log("  admin:    ", admin, "(single key - hand over to a multisig)");
        console2.log("  pauser:   ", pauser);
        console2.log("  minTopUp: ", minTopUp);
        console2.log("Next: verify on https://testnet.arcscan.app, commit deployment artifacts,");
        console2.log("then run script/ProposeHandover.s.sol. The handover takes 2 days.");
    }
}

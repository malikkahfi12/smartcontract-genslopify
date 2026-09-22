// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../src/TopUpRouter.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title Deploy
/// @notice Deterministic deployment of TopUpRouter to Arc.
/// @dev Constitution Principle VI: no chain id or address is hardcoded in `src/`. The one
///      deployment parameter comes from the environment, and the network is validated before
///      broadcasting. Constitution (Secrets): sign with an encrypted keystore (`--account`) or a
///      hardware wallet (`--ledger` / `--trezor`). Never pass a literal private key outside local
///      anvil. Walkthrough: docs/DEPLOYMENT.md
///
///      ## Read this before you broadcast
///
///      `TREASURY_ADDRESS` is PERMANENT. The deployed contract has no administrator, no pauser,
///      and no way to change its destination — not after two days, not by quorum, not ever. Two
///      failure modes follow, and neither has a remedy:
///
///        1. A wrong address routes every future top-up to it, irreversibly.
///        2. A contract treasury that reverts on receipt makes EVERY top-up fail, permanently,
///           bricking the deployment from block one.
///
///      The checks below catch the zero address and this contract's own address. They cannot
///      catch a typo that happens to be a valid address, and they cannot tell you whether the
///      destination will accept funds. Verify the address against an independent source and send
///      one real top-up before announcing it.
contract Deploy is Script {
    /// @dev Arc testnet, confirmed by the T082 opcode probe on 2026-09-04.
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5_042_002;
    /// @dev Arc mainnet (docs.arc.io/integrate/connect-to-arc). Cancun opcodes (PUSH0, TSTORE/TLOAD,
    ///      MCOPY) confirmed by eth_call probe against rpc.mainnet.arc.io on 2026-09-22.
    uint256 internal constant ARC_MAINNET_CHAIN_ID = 5042;

    error WrongNetwork(uint256 actual, uint256 expected);
    error MissingParameter(string name);
    error UnknownNetwork(string network);

    function run() external returns (TopUpRouter router) {
        string memory network = vm.envString("DEPLOY_NETWORK");
        address treasury = vm.envAddress("TREASURY_ADDRESS");

        validate(network, treasury);

        vm.startBroadcast();
        router = new TopUpRouter(treasury);
        vm.stopBroadcast();

        _report(router, treasury);
    }

    /// @notice All pre-broadcast checks. Public so tests can exercise them without broadcasting.
    /// @param network `DEPLOY_NETWORK`: "testnet" or "mainnet". The RPC's chain must match it, so
    ///      a stale `--rpc-url` can never deploy to a network the operator did not name.
    /// @param treasury The permanent destination for every top-up.
    /// @dev Deliberately short: with no roles and no minimum to configure, there is exactly one
    ///      contract parameter left to get wrong. Any `ADMIN_ADDRESS`, `PAUSER_ADDRESS`, or `MIN_TOPUP_WEI`
    ///      left over in the environment is ignored entirely and reaches nothing (003 FR-011/012).
    function validate(string memory network, address treasury) public view {
        uint256 expected = expectedChainId(network);
        if (block.chainid != expected) revert WrongNetwork(block.chainid, expected);

        if (treasury == address(0)) revert MissingParameter("TREASURY_ADDRESS");
    }

    /// @notice Chain id for a `DEPLOY_NETWORK` value. Reverts on anything else, including "".
    function expectedChainId(string memory network) public pure returns (uint256) {
        bytes32 h = keccak256(bytes(network));
        if (h == keccak256("testnet")) return ARC_TESTNET_CHAIN_ID;
        if (h == keccak256("mainnet")) return ARC_MAINNET_CHAIN_ID;
        revert UnknownNetwork(network);
    }

    function _report(TopUpRouter router, address treasury) internal view {
        console2.log("TopUpRouter deployed:", address(router));
        console2.log("  treasury: ", treasury, "(PERMANENT - cannot be changed by anyone)");
        console2.log("  MIN_TOPUP:", router.MIN_TOPUP(), "base units = 1.000000000000000000 USDC");
        console2.log("");
        console2.log("This contract has no admin, no pauser, and no upgrade path.");
        string memory explorer = block.chainid == ARC_MAINNET_CHAIN_ID
            ? "https://explorer.arc.io"
            : "https://explorer.testnet.arc.io";
        console2.log("Next: verify on", explorer, "- then send one test top-up to");
        console2.log("confirm the treasury accepts funds, then commit deployment artifacts.");
    }
}

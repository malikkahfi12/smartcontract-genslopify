// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../src/TopUpRouter.sol";
import {Test} from "forge-std/Test.sol";

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function getThreshold() external view returns (uint256);
}

/// @title ArcTestnetForkTest
/// @notice Exercise the router against Arc testnet and a REAL deployed Safe.
/// @dev Everything else in the suite runs against a local EVM. This is the only place the
///      contract meets the actual chain: real chain id, real Cancun support, real Safe bytecode,
///      and — most importantly for 003 — the chain's real native denomination.
///      Skipped automatically when the RPC is unreachable so CI does not fail on network flakes.
///
///      ## Why the denomination test here is the important one
///
///      A router deployed with its minimum at the wrong scale is permanently unusable: too high and
///      it can accept nothing, too low and its floor is meaningless. A suite that picks the same
///      scale for BOTH the minimum and the amounts cannot detect either case — arithmetic that is
///      internally consistent at the wrong scale satisfies every assertion you can write about it.
///
///      The defense is not more assertions at the same scale. It is to make the CHAIN supply a
///      number the test does not choose: see `test_Fork_NativeDenominationIsEighteenDecimals`,
///      which reads a real funded balance instead of a literal. A test whose inputs all come from
///      the same mistaken assumption can only ever confirm that assumption.
contract ArcTestnetForkTest is Test {
    string internal constant ARC_RPC = "https://rpc.testnet.arc.io";
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    /// @dev One whole USDC on Arc: 18 decimals, not 6.
    uint256 internal constant ONE_USDC = 1e18;

    // Canonical Safe v1.4.1 deployments, confirmed present on Arc testnet 2026-09-04.
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;

    TopUpRouter internal router;
    address internal treasury = makeAddr("forkTreasury");

    address internal ownerA = vm.addr(0xA11CE);
    address internal ownerB = vm.addr(0xB0B);

    bool internal forked;

    function setUp() public {
        try vm.createSelectFork(ARC_RPC) {
            forked = true;
        } catch {
            forked = false;
        }
    }

    modifier onlyForked() {
        if (!forked) {
            emit log_string("SKIP: Arc testnet RPC unreachable");
            return;
        }
        _;
    }

    /// @dev Principle VI: the chain we target must be the chain we think it is.
    function test_Fork_ChainIdMatchesArcTestnet() public onlyForked {
        assertEq(block.chainid, ARC_CHAIN_ID, "connected to Arc testnet");
    }

    /// @dev The T082 probe concluded Cancun. Confirm the compiled artifact actually deploys and
    ///      runs on the real chain, which is the claim that matters.
    function test_Fork_ContractDeploysAndRunsOnArc() public onlyForked {
        router = new TopUpRouter(treasury);

        assertEq(router.treasury(), treasury, "constructor wiring intact");
        assertEq(router.MIN_TOPUP(), ONE_USDC, "minimum is one whole USDC on the real chain");

        address payer = makeAddr("forkPayer");
        vm.deal(payer, 100 * ONE_USDC);
        vm.prank(payer);
        router.topUp{value: 10 * ONE_USDC}(makeAddr("forkBeneficiary"));

        assertEq(treasury.balance, 10 * ONE_USDC, "native USDC routed on the real chain");
        assertEq(address(router).balance, 0, "nothing retained");
    }

    /// @dev 003 FR-010. The denomination check that does NOT take its scale from this file.
    ///
    ///      An account funded from the Arc faucet holds a balance the faucet chose, denominated by
    ///      the chain. If native USDC had 6 decimals, a faucet grant of a few USDC would read as a
    ///      small multiple of 1e6 — twelve orders of magnitude below what the same grant reads as
    ///      at 18 decimals. So a real balance discriminates between the two scales even though this
    ///      file never supplies it.
    ///
    ///      Set `ARC_FUNDED_ACCOUNT` to a faucet-funded address to run the strict check. Without
    ///      it the test still runs a bounded sanity check against the chain's own gas price, which
    ///      needs no configuration.
    function test_Fork_NativeDenominationIsEighteenDecimals() public onlyForked {
        address funded = vm.envOr("ARC_FUNDED_ACCOUNT", address(0));

        if (funded != address(0)) {
            uint256 balance = funded.balance;
            assertGt(balance, 0, "ARC_FUNDED_ACCOUNT must actually hold a faucet balance");

            // A faucet grant is single- or double-digit USDC. At 18 decimals that is 1e18..1e20
            // base units. At 6 decimals the same grant would be <= 1e8 — ten orders of magnitude
            // below this bound, so the assertion genuinely discriminates between the two.
            assertGe(
                balance,
                ONE_USDC,
                "faucet balance is far too small for 18 decimals: the chain may not be 18-decimal, "
                "or ARC_FUNDED_ACCOUNT is not a faucet account. STOP and re-verify before deploying"
            );
        } else {
            emit log_string("NOTE: set ARC_FUNDED_ACCOUNT to a faucet-funded address for the strict check");
        }

        // Configuration-free corroboration: gas is priced in the native token, so a plausible gas
        // price is itself evidence about the denomination. An 18-decimal chain prices gas in
        // gwei-scale numbers (~1e9); a 6-decimal chain cannot reach that scale at all.
        // Reads the forked block's base fee, which comes from the chain. `tx.gasprice` would not:
        // forge sets it to 0 in tests unless `--gas-price` is passed.
        assertGe(
            block.basefee,
            1e6,
            "base fee looks 6-decimal-scaled; re-verify the native denomination before deploying"
        );
    }

    /// @dev A REAL Safe as the TREASURY — the intended production destination. Under 002 this test
    ///      exercised a Safe governing the router; there is no governance now, so what matters is
    ///      that a Safe can RECEIVE. That is not a given: the payout uses a full-gas `call`
    ///      precisely because a 2300-gas stipend would break for a Safe (research R-006), and a
    ///      treasury that cannot accept funds would brick the contract permanently.
    function test_Fork_RealSafeCanReceiveAsTreasury() public onlyForked {
        address safe = _deploySafe();
        assertGt(safe.code.length, 0, "real Safe deployed");
        assertEq(ISafe(safe).getThreshold(), 2, "2-of-2 Safe");

        router = new TopUpRouter(safe);
        assertEq(router.treasury(), safe, "Safe is the permanent treasury");

        address payer = makeAddr("forkSafePayer");
        vm.deal(payer, 100 * ONE_USDC);
        uint256 before = safe.balance;

        vm.prank(payer);
        router.topUp{value: 25 * ONE_USDC}(makeAddr("forkSafeBeneficiary"));

        assertEq(safe.balance - before, 25 * ONE_USDC, "real Safe accepted the routed funds");
        assertEq(address(router).balance, 0, "nothing retained");
    }

    /// @dev 003 FR-014/SC-004a on the real chain: no caller is privileged, including the deployer
    ///      and the treasury itself.
    function test_Fork_NoGovernanceSurfaceOnChain() public onlyForked {
        router = new TopUpRouter(treasury);

        string[4] memory absent = ["admin()", "pauser()", "paused()", "DELAY()"];
        for (uint256 i = 0; i < absent.length; i++) {
            (bool ok, bytes memory ret) = address(router).call(abi.encodeWithSignature(absent[i]));
            assertFalse(ok, "governance selector must not be callable on the deployed bytecode");
            assertEq(ret.length, 0, "governance selector must be absent, not merely reverting");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deploySafe() internal returns (address safe) {
        address[] memory owners = new address[](2);
        owners[0] = ownerA;
        owners[1] = ownerB;

        bytes memory initializer = abi.encodeCall(
            ISafe.setup, (owners, 2, address(0), "", address(0), address(0), 0, payable(address(0)))
        );

        safe = ISafeProxyFactory(SAFE_PROXY_FACTORY)
            .createProxyWithNonce(
                SAFE_SINGLETON, initializer, uint256(keccak256("forgeify-fork-test-003"))
            );
    }
}

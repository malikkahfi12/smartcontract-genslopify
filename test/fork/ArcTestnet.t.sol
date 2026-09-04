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

    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 _nonce
    ) external view returns (bytes32);

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);

    function nonce() external view returns (uint256);
    function getThreshold() external view returns (uint256);
}

/// @title ArcTestnetForkTest
/// @notice T074: exercise the router against Arc testnet and a REAL deployed Safe.
/// @dev Everything else in the suite runs against a local EVM. This is the only place the
///      contract meets the actual chain: real chain id, real Cancun support, real Safe bytecode.
///      Skipped automatically when the RPC is unreachable so CI does not fail on network flakes.
contract ArcTestnetForkTest is Test {
    string internal constant ARC_RPC = "https://rpc.testnet.arc.io";
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    // Canonical Safe v1.4.1 deployments, confirmed present on Arc testnet 2026-09-04.
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;

    TopUpRouter internal router;
    address internal treasury = makeAddr("forkTreasury");
    address internal pauser = makeAddr("forkPauser");

    uint256 internal ownerAKey = 0xA11CE;
    uint256 internal ownerBKey = 0xB0B;
    address internal ownerA;
    address internal ownerB;

    bool internal forked;

    function setUp() public {
        try vm.createSelectFork(ARC_RPC) {
            forked = true;
        } catch {
            forked = false;
        }
        ownerA = vm.addr(ownerAKey);
        ownerB = vm.addr(ownerBKey);
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
        router = new TopUpRouter(treasury, ownerA, pauser, 1e18);

        assertEq(router.DELAY(), 172_800, "delay intact on-chain");
        assertEq(router.treasury(), treasury, "constructor wiring intact");

        address payer = makeAddr("forkPayer");
        vm.deal(payer, 100e18);
        vm.prank(payer);
        router.topUp{value: 10e18}(makeAddr("forkBeneficiary"));

        assertEq(treasury.balance, 10e18, "native USDC routed on the real chain");
        assertEq(address(router).balance, 0, "nothing retained");
    }

    /// @dev A REAL Safe, deployed through the canonical factory, governs the router and executes
    ///      a treasury rotation with real owner signatures.
    function test_Fork_RealSafeGovernsTheRouter() public onlyForked {
        address safe = _deploySafe();
        assertGt(safe.code.length, 0, "real Safe deployed");
        assertEq(ISafe(safe).getThreshold(), 2, "2-of-2 Safe");

        // Deploying with the Safe as admin latches the one-way flag immediately.
        router = new TopUpRouter(treasury, safe, pauser, 1e18);
        assertTrue(router.multisigEstablished(), "contract admin latches");

        // The Safe proposes a treasury rotation, signed by both owners.
        address newTreasury = makeAddr("forkNewTreasury");
        _execViaSafe(safe, abi.encodeCall(TopUpRouter.proposeTreasury, (newTreasury)));

        (address pending, uint64 eta) = router.pendingTreasury();
        assertEq(pending, newTreasury, "real Safe created the proposal");
        assertEq(eta, block.timestamp + 2 days, "full delay on the real chain");

        // The delay is real: not applicable yet.
        vm.expectRevert();
        router.applyTreasury();

        vm.warp(eta);
        router.applyTreasury();
        assertEq(router.treasury(), newTreasury, "rotation completed under real Safe governance");
    }

    /// @dev A single owner cannot reach the treasury; the quorum is what authorizes.
    function test_Fork_SingleSafeOwnerCannotGovern() public onlyForked {
        address safe = _deploySafe();
        router = new TopUpRouter(treasury, safe, pauser, 1e18);

        vm.prank(ownerA);
        vm.expectRevert(TopUpRouter.NotAdmin.selector);
        router.proposeTreasury(makeAddr("grab"));

        assertEq(router.treasury(), treasury, "unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deploySafe() internal returns (address safe) {
        address[] memory owners = new address[](2);
        // Safe requires owners in no particular order for setup, but signatures must be sorted.
        owners[0] = ownerA;
        owners[1] = ownerB;

        bytes memory initializer = abi.encodeCall(
            ISafe.setup, (owners, 2, address(0), "", address(0), address(0), 0, payable(address(0)))
        );

        safe = ISafeProxyFactory(SAFE_PROXY_FACTORY)
            .createProxyWithNonce(
                SAFE_SINGLETON, initializer, uint256(keccak256("forgeify-fork-test"))
            );
    }

    /// @dev Build, sign with BOTH owners, and execute a Safe transaction targeting the router.
    /// @dev Split across helpers to stay within the stack limit without enabling via-ir.
    function _execViaSafe(address safe, bytes memory data) internal {
        bytes memory sigs = _signAsBothOwners(_safeTxHash(safe, data));
        bool ok = ISafe(safe)
            .execTransaction(
                address(router), 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sigs
            );
        assertTrue(ok, "Safe transaction executed");
    }

    function _safeTxHash(address safe, bytes memory data) internal view returns (bytes32) {
        return ISafe(safe)
            .getTransactionHash(
                address(router), 0, data, 0, 0, 0, 0, address(0), address(0), ISafe(safe).nonce()
            );
    }

    /// @dev Safe requires signatures concatenated in ascending owner-address order.
    function _signAsBothOwners(bytes32 txHash) internal view returns (bytes memory) {
        (uint256 firstKey, uint256 secondKey) =
            ownerA < ownerB ? (ownerAKey, ownerBKey) : (ownerBKey, ownerAKey);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(firstKey, txHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(secondKey, txHash);
        return abi.encodePacked(r1, s1, v1, r2, s2, v2);
    }
}

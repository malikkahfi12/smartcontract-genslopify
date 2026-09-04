// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../../src/TopUpRouter.sol";
import {MockMultisig} from "../../mocks/MockMultisig.sol";
import {Test} from "forge-std/Test.sol";

/// @title GovernanceHandler
/// @notice Drives randomized governance sequences: propose, cancel, apply, and time passing.
/// @dev Ghosts record what the handler believes it caused, so the invariants cross-check the
///      contract against an independent tally rather than against itself.
contract GovernanceHandler is Test {
    TopUpRouter public immutable ROUTER;

    address[] public candidateEoas;
    address[] public candidateContracts;

    /// @notice Ghost: every address ever legitimately proposed as admin, plus the initial one.
    mapping(address candidate => bool proposed) public everProposedAdmin;
    /// @notice Ghost: every address ever legitimately proposed as treasury, plus the initial one.
    mapping(address candidate => bool proposed) public everProposedTreasury;
    /// @notice Ghost: earliest timestamp at which the current admin proposal could mature.
    uint256 public lastAdminProposalTime;

    uint256 public callsPropose;
    uint256 public callsApply;
    uint256 public callsCancel;
    uint256 public callsWarp;
    uint256 public successfulAdminApplies;
    uint256 public successfulTreasuryApplies;

    constructor(TopUpRouter router_, address initialAdmin, address initialTreasury) {
        ROUTER = router_;
        everProposedAdmin[initialAdmin] = true;
        everProposedTreasury[initialTreasury] = true;

        for (uint256 i = 0; i < 3; i++) {
            candidateEoas.push(address(uint160(uint256(keccak256(abi.encode("govEoa", i))))));
            candidateContracts.push(address(new MockMultisig()));
        }
    }

    function _admin() internal view returns (address) {
        return ROUTER.admin();
    }

    function proposeAdminEoa(uint256 seed) external {
        address target = candidateEoas[seed % candidateEoas.length];
        vm.prank(_admin());
        try ROUTER.proposeAdmin(target) {
            everProposedAdmin[target] = true;
            lastAdminProposalTime = block.timestamp;
            callsPropose++;
        } catch {}
    }

    function proposeAdminContract(uint256 seed) external {
        address target = candidateContracts[seed % candidateContracts.length];
        vm.prank(_admin());
        try ROUTER.proposeAdmin(target) {
            everProposedAdmin[target] = true;
            lastAdminProposalTime = block.timestamp;
            callsPropose++;
        } catch {}
    }

    function proposeTreasury(uint256 seed) external {
        address target = candidateEoas[seed % candidateEoas.length];
        vm.prank(_admin());
        try ROUTER.proposeTreasury(target) {
            everProposedTreasury[target] = true;
            callsPropose++;
        } catch {}
    }

    function applyAdmin() external {
        try ROUTER.applyAdmin() {
            successfulAdminApplies++;
            callsApply++;
        } catch {}
    }

    function applyTreasury() external {
        try ROUTER.applyTreasury() {
            successfulTreasuryApplies++;
            callsApply++;
        } catch {}
    }

    function cancelAdmin() external {
        vm.prank(_admin());
        try ROUTER.cancelAdmin() {
            callsCancel++;
        } catch {}
    }

    function cancelTreasury() external {
        vm.prank(_admin());
        try ROUTER.cancelTreasury() {
            callsCancel++;
        } catch {}
    }

    /// @notice Complete a whole admin handover in one action: propose, wait out the full delay,
    ///         apply.
    /// @dev Needed because with purely random interleaving another proposal almost always lands
    ///      first and restarts the clock, so `applyAdmin` never succeeds and the latch invariants
    ///      go untested. This models an operator seeing a governance cycle through, and still
    ///      passes through the real contract functions with the real delay.
    function completeAdminHandover(uint256 seed, bool toContract) external {
        address target = toContract
            ? candidateContracts[seed % candidateContracts.length]
            : candidateEoas[seed % candidateEoas.length];

        vm.prank(_admin());
        try ROUTER.proposeAdmin(target) {
            everProposedAdmin[target] = true;
            lastAdminProposalTime = block.timestamp;
            callsPropose++;
        } catch {
            return;
        }

        vm.warp(block.timestamp + ROUTER.DELAY());

        try ROUTER.applyAdmin() {
            successfulAdminApplies++;
            callsApply++;
        } catch {}
    }

    /// @notice Complete a whole treasury rotation in one action.
    function completeTreasuryRotation(uint256 seed) external {
        address target = candidateEoas[seed % candidateEoas.length];

        vm.prank(_admin());
        try ROUTER.proposeTreasury(target) {
            everProposedTreasury[target] = true;
            callsPropose++;
        } catch {
            return;
        }

        vm.warp(block.timestamp + ROUTER.DELAY());

        try ROUTER.applyTreasury() {
            successfulTreasuryApplies++;
            callsApply++;
        } catch {}
    }

    /// @notice Let time pass so proposals can actually mature during a run.
    function passTime(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1 hours, 3 days));
        callsWarp++;
    }
}

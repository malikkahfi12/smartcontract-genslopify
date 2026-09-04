// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../../src/TopUpRouter.sol";
import {ForceSender} from "../../mocks/ForceSender.sol";
import {Test} from "forge-std/Test.sol";

/// @title AccountingHandler
/// @notice Drives randomized sequences of top-ups and forced-fund pushes against the router.
/// @dev Ghost variables are computed INDEPENDENTLY of the contract under test — they sum what the
///      handler believes it caused, so comparing them against the router's own totals is a real
///      cross-check rather than the contract agreeing with itself.
contract AccountingHandler is Test {
    TopUpRouter public immutable ROUTER;
    address public immutable TREASURY;

    address[] public actors;
    address[] public beneficiaries;

    /// @notice Ghost: sum of every amount this handler successfully topped up.
    uint256 public ghostTotalCredited;
    /// @notice Ghost: sum of every amount forced into the router outside the top-up path.
    uint256 public ghostTotalForced;
    /// @notice Ghost: highest `totalRouted` ever observed, for the monotonicity check.
    uint256 public ghostMaxTotalRouted;

    uint256 public callsTopUp;
    uint256 public callsForce;

    constructor(TopUpRouter router_, address treasury_) {
        ROUTER = router_;
        TREASURY = treasury_;

        for (uint256 i = 0; i < 4; i++) {
            address actor = address(uint160(uint256(keccak256(abi.encode("actor", i)))));
            actors.push(actor);
            vm.deal(actor, 1_000_000e18);
        }
        for (uint256 i = 0; i < 3; i++) {
            beneficiaries.push(address(uint160(uint256(keccak256(abi.encode("bene", i))))));
        }

        // The handler itself must hold funds, or `forceFunds` cannot construct a payable
        // ForceSender and every call reverts - which would make the INV-9 assertions pass
        // vacuously while never actually forcing anything in.
        vm.deal(address(this), 1_000_000e18);
    }

    function beneficiaryCount() external view returns (uint256) {
        return beneficiaries.length;
    }

    /// @notice Randomized successful top-up.
    function topUp(uint256 actorSeed, uint256 beneSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % actors.length];
        address bene = beneficiaries[beneSeed % beneficiaries.length];
        uint256 amount = bound(amountSeed, ROUTER.MIN_TOPUP(), 500e18);

        uint256 totalBefore = ROUTER.totalRouted();

        vm.prank(actor);
        ROUTER.topUp{value: amount}(bene);

        // INV-2 checked at the point of change, not just at the end of the run.
        assertGe(ROUTER.totalRouted(), totalBefore, "INV-2: totalRouted decreased");

        ghostTotalCredited += amount;
        if (ROUTER.totalRouted() > ghostMaxTotalRouted) ghostMaxTotalRouted = ROUTER.totalRouted();
        callsTopUp++;
    }

    /// @notice Randomized attempt below the minimum. Must always revert and change nothing.
    function topUpBelowMinimum(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, ROUTER.MIN_TOPUP() - 1);

        uint256 totalBefore = ROUTER.totalRouted();
        vm.prank(actor);
        try ROUTER.topUp{value: amount}(beneficiaries[0]) {
            revert("below-minimum top-up must never succeed");
        } catch {}
        assertEq(ROUTER.totalRouted(), totalBefore, "failed top-up changed state");
    }

    /// @notice Force native funds into the router via SELFDESTRUCT (INV-9).
    /// @dev This is the interference the accounting must be immune to.
    function forceFunds(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 100e18);
        ForceSender sender = new ForceSender{value: amount}();
        sender.forceSend(payable(address(ROUTER)));

        ghostTotalForced += amount;
        callsForce++;
    }

    receive() external payable {}
}

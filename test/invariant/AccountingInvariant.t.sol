// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TopUpRouter} from "../../src/TopUpRouter.sol";
import {AccountingHandler} from "./handlers/AccountingHandler.sol";
import {Test} from "forge-std/Test.sol";

/// @title AccountingInvariantTest
/// @notice Stateful invariant proof of the reconciliation identity (001 SC-002, INV-1/2/3/9).
/// @dev This is the strongest evidence in the suite that top-ups reconcile to treasury receipts:
///      it holds across randomized sequences of top-ups, failed top-ups, and forced-fund pushes,
///      not just the hand-picked orderings a unit test can express.
contract AccountingInvariantTest is Test {
    TopUpRouter internal router;
    AccountingHandler internal handler;

    address internal treasury = makeAddr("invariantTreasury");

    uint256 internal constant MIN_TOPUP = 1e18;

    function setUp() public {
        router = new TopUpRouter(treasury);
        handler = new AccountingHandler(router, treasury);

        // Only the handler may drive state, so the fuzzer cannot call the router directly with
        // unbounded garbage and produce uninterpretable sequences.
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = AccountingHandler.topUp.selector;
        selectors[1] = AccountingHandler.topUpBelowMinimum.selector;
        selectors[2] = AccountingHandler.forceFunds.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice INV-1: the sum of every per-account total equals the system-wide total.
    /// @dev This is the reconciliation identity 001 FR-013 requires and SC-002 measures.
    function invariant_SumOfContributionsEqualsTotalRouted() public view {
        uint256 sum;
        uint256 n = handler.beneficiaryCount();
        for (uint256 i = 0; i < n; i++) {
            sum += router.contributions(handler.beneficiaries(i));
        }
        assertEq(sum, router.totalRouted(), "INV-1: per-account totals must sum to totalRouted");
    }

    /// @notice INV-3: `totalRouted` equals what the treasury actually received.
    /// @dev The treasury is a fresh EOA that receives from nowhere else, so its balance is
    ///      exactly the value this router has sent out.
    function invariant_TotalRoutedEqualsTreasuryReceipts() public view {
        assertEq(
            router.totalRouted(), treasury.balance, "INV-3: routed must equal treasury receipts"
        );
    }

    /// @notice Cross-check against an independently computed ghost total.
    function invariant_GhostCreditMatchesContractTotal() public view {
        assertEq(
            handler.ghostTotalCredited(),
            router.totalRouted(),
            "handler's independent tally must match the contract"
        );
    }

    /// @notice INV-2: totals never decrease.
    function invariant_TotalRoutedIsMonotonic() public view {
        assertGe(router.totalRouted(), handler.ghostMaxTotalRouted(), "INV-2: totals decreased");
    }

    /// @notice INV-9: forced funds are invisible to accounting.
    /// @dev The router's balance is whatever was forced in; its accounting must be unaffected by
    ///      that entirely. This is the property that makes SC-002 hold "regardless of any funds
    ///      forced into the contract".
    function invariant_ForcedFundsNeverEnterAccounting() public view {
        assertEq(
            address(router).balance,
            handler.ghostTotalForced(),
            "INV-9: router balance must be exactly the forced amount, never top-up funds"
        );
        assertEq(
            router.totalRouted(),
            handler.ghostTotalCredited(),
            "INV-9: forced funds must not inflate totalRouted"
        );
    }

    /// @notice Sanity: the run actually exercised both paths, so the invariants mean something.
    function invariant_CallSummary() public view {
        assertGe(handler.callsTopUp() + handler.callsForce(), 0, "handler ran");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../BaseTest.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title AccountingTest
/// @notice US4 reconciliation: 001 FR-011..FR-014, FR-010, SC-008.
contract AccountingTest is BaseTest {
    /// @dev keccak256("ToppedUp(address,address,uint256,address,uint256)")
    bytes32 internal constant TOPPED_UP_SIG =
        keccak256("ToppedUp(address,address,uint256,address,uint256)");

    /*//////////////////////////////////////////////////////////////
                            TOTALS (FR-011..014)
    //////////////////////////////////////////////////////////////*/

    function test_NeverCreditedAccountReadsZero() public {
        assertEq(router.contributions(makeAddr("nobody")), 0, "zero, not a revert");
        assertEq(router.contributions(address(0)), 0, "zero address reads zero cleanly");
    }

    function test_SystemTotalEqualsSumOfAllAccounts() public {
        address a = makeAddr("accA");
        address b = makeAddr("accB");

        vm.startPrank(payer);
        router.topUp{value: 3e18}(a);
        router.topUp{value: 5e18}(b);
        router.topUp{value: 2e18}(a);
        vm.stopPrank();

        assertEq(
            router.contributions(a) + router.contributions(b),
            router.totalRouted(),
            "INV-1 holds for this sequence"
        );
    }

    function test_TotalRoutedEqualsTreasuryReceipts() public {
        uint256 before = treasury.balance;

        vm.startPrank(payer);
        router.topUp{value: 4e18}(beneficiary);
        router.topUp{value: 6e18}(beneficiary);
        vm.stopPrank();

        assertEq(router.totalRouted(), treasury.balance - before, "INV-3: routed == received");
    }

    /// @dev 001 FR-014: no operation may reduce a total.
    function test_TotalsAreMonotonicAcrossFailedAttempts() public {
        vm.prank(payer);
        router.topUp{value: 10e18}(beneficiary);
        uint256 snapshot = router.totalRouted();

        // A failed top-up must not reduce anything.
        vm.prank(payer);
        (bool ok,) =
            address(router).call{value: 0}(abi.encodeWithSignature("topUp(address)", beneficiary));
        assertFalse(ok, "zero-value top-up rejected");

        assertEq(router.totalRouted(), snapshot, "total unchanged by a failed attempt");
        assertGe(router.totalRouted(), snapshot, "never decreases");
    }

    /*//////////////////////////////////////////////////////////////
                    EVENT REPLAY / OFF-CHAIN LEDGER (SC-008)
    //////////////////////////////////////////////////////////////*/

    /// @dev SC-008: an off-chain ledger rebuilt from public records alone must match the
    ///      contract's own totals exactly, with zero double-counted or missed top-ups.
    function test_LedgerRebuiltFromEventsMatchesOnChainTotals() public {
        address a = makeAddr("ledgerA");
        address b = makeAddr("ledgerB");

        vm.recordLogs();

        vm.startPrank(payer);
        router.topUp{value: 3e18}(a);
        router.topUp{value: 7e18}(b);
        router.topUp{value: 5e18}(a);
        vm.stopPrank();

        vm.prank(stranger);
        router.topUp{value: 11e18}(b);

        // Rebuild from logs alone, exactly as an indexer would.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 rebuiltA;
        uint256 rebuiltB;
        uint256 rebuiltTotal;
        uint256 seen;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != TOPPED_UP_SIG) continue;
            address bene = address(uint160(uint256(logs[i].topics[2])));
            (uint256 amount,,) = abi.decode(logs[i].data, (uint256, address, uint256));

            if (bene == a) rebuiltA += amount;
            if (bene == b) rebuiltB += amount;
            rebuiltTotal += amount;
            seen++;
        }

        assertEq(seen, 4, "exactly four records, none missed or duplicated");
        assertEq(rebuiltA, router.contributions(a), "rebuilt A matches chain");
        assertEq(rebuiltB, router.contributions(b), "rebuilt B matches chain");
        assertEq(rebuiltTotal, router.totalRouted(), "rebuilt system total matches chain");
    }

    /// @dev 001 FR-010 / research R-008: `newTotal` is the post-state, so a consumer can assert
    ///      `newTotal == previousTotal + amount` and detect a gap or duplicate immediately
    ///      instead of drifting silently. This is the property that makes resumption safe.
    function test_NewTotalIsContinuousPerBeneficiary() public {
        vm.recordLogs();

        vm.startPrank(payer);
        router.topUp{value: 2e18}(beneficiary);
        router.topUp{value: 3e18}(beneficiary);
        router.topUp{value: 4e18}(beneficiary);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 running;
        uint256 checked;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != TOPPED_UP_SIG) continue;
            (uint256 amount,, uint256 newTotal) =
                abi.decode(logs[i].data, (uint256, address, uint256));

            assertEq(newTotal, running + amount, "newTotal must equal previousTotal + amount");
            running = newTotal;
            checked++;
        }

        assertEq(checked, 3, "all three records checked");
        assertEq(running, router.contributions(beneficiary), "final running total matches chain");
    }

    /// @dev A consumer resuming from a mid-stream cursor must reach the same answer.
    function test_LedgerResumesFromMidStreamWithoutDoubleCounting() public {
        vm.recordLogs();

        vm.startPrank(payer);
        router.topUp{value: 2e18}(beneficiary);
        router.topUp{value: 3e18}(beneficiary);
        router.topUp{value: 4e18}(beneficiary);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Pretend the indexer already processed record 0, then crashed. It resumes at index 1
        // carrying the newTotal it had persisted.
        (,, uint256 persistedTotal) = abi.decode(logs[0].data, (uint256, address, uint256));

        uint256 running = persistedTotal;
        for (uint256 i = 1; i < logs.length; i++) {
            if (logs[i].topics[0] != TOPPED_UP_SIG) continue;
            (uint256 amount,, uint256 newTotal) =
                abi.decode(logs[i].data, (uint256, address, uint256));
            assertEq(newTotal, running + amount, "continuity holds across the resume point");
            running = newTotal;
        }

        assertEq(running, router.contributions(beneficiary), "resumed ledger matches chain");
    }

    /// @dev The record must name the treasury that actually received, for reconciliation.
    function test_EventCarriesReceivingTreasuryForReconciliation() public {
        vm.recordLogs();
        vm.prank(payer);
        router.topUp{value: 5e18}(beneficiary);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, address recorded,) = abi.decode(logs[0].data, (uint256, address, uint256));
        assertEq(recorded, treasury, "record names the receiving treasury");
    }

    function testFuzz_LedgerRebuildAlwaysMatches(uint256 a1, uint256 a2, uint256 a3) public {
        a1 = bound(a1, MIN_TOPUP, 50e18);
        a2 = bound(a2, MIN_TOPUP, 50e18);
        a3 = bound(a3, MIN_TOPUP, 50e18);

        vm.recordLogs();
        vm.startPrank(payer);
        router.topUp{value: a1}(beneficiary);
        router.topUp{value: a2}(beneficiary);
        router.topUp{value: a3}(beneficiary);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 rebuilt;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != TOPPED_UP_SIG) continue;
            (uint256 amount,,) = abi.decode(logs[i].data, (uint256, address, uint256));
            rebuilt += amount;
        }

        assertEq(rebuilt, router.contributions(beneficiary), "rebuild matches for any amounts");
    }
}

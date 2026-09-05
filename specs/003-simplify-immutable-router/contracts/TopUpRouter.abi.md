# Interface Contract: TopUpRouter (003)

**Feature**: `003-simplify-immutable-router` | **Date**: 2026-09-05

This is the **complete and exhaustive** external surface. Anything not listed here does not exist on the contract. That exhaustiveness is the contract: FR-001, FR-004, FR-014, and SC-002 all assert absence, so this file is the reviewable statement of what was removed as much as what remains.

Amounts are in base units of native USDC (6 decimals on Arc): one whole USDC = `1e6`. `MIN_TOPUP` is `1e6`.

## Constructor

```solidity
constructor(address initialTreasury)
```

| Parameter | Validation | Reverts |
|-----------|-----------|---------|
| `initialTreasury` | Non-zero | `ZeroAddress()` |
| `initialTreasury` | Not `address(this)` | `SelfAddress()` |

Takes exactly one argument (FR-014b). No role addresses, no minimum (FR-011, FR-012). Emits no events — with the treasury permanently readable from a getter, there is no state an indexer could miss.

## State-changing functions

```solidity
function topUp(address beneficiary) external payable
function topUpSelf() external payable
```

Both are `nonReentrant`. Neither is guarded by any role, pause state, or time condition — they behave identically for every caller for the life of the contract (FR-005, SC-004a).

| Condition | Revert |
|-----------|--------|
| `msg.value == 0` | `ZeroAmount()` |
| `msg.value < MIN_TOPUP` | `BelowMinimum(uint256 sent, uint256 minimum)` |
| `beneficiary == address(0)` (`topUp` only) | `ZeroBeneficiary()` |
| Outbound transfer to treasury fails | `TreasuryTransferFailed()` |

On success: credits `beneficiary`, increases `totalRouted`, emits `ToppedUp`, and forwards the full `msg.value` to the treasury within the same call, retaining nothing (FR-008).

Payment is native USDC as transaction value. There is no approval step and no token parameter (FR-017a).

## View functions

```solidity
function treasury()      external view returns (address)   // immutable getter
function MIN_TOPUP()     external view returns (uint256)   // constant getter
function totalRouted()   external view returns (uint256)
function contributions(address account) external view returns (uint256)
```

## Events

```solidity
event ToppedUp(
    address indexed payer,
    address indexed beneficiary,
    uint256 amount,
    address treasury,
    uint256 newTotal
);
```

The only event. Emitted before the outbound transfer, per checks-effects-interactions. Schema is unchanged from the 002 router so the off-chain ledger consumer needs no migration.

## Errors

```solidity
error ZeroAmount();
error BelowMinimum(uint256 sent, uint256 minimum);
error ZeroBeneficiary();
error TreasuryTransferFailed();
error ZeroAddress();   // constructor only
error SelfAddress();   // constructor only
```

Plus one inherited error, which appears in the built ABI and must be expected there:

```solidity
error ReentrancyGuardReentrantCall();   // from OpenZeppelin ReentrancyGuard
```

## Absent by design

Calling any of these reverts as an unrecognised selector — there is no `receive`, no `fallback`, and no dispatch target. `test/unit/Immutability.t.sol` probes each one (R-005).

**Governance — removed entirely (FR-002, FR-014, FR-014a)**

`proposeTreasury` · `applyTreasury` · `cancelTreasury` · `proposeAdmin` · `applyAdmin` · `cancelAdmin` · `proposePauser` · `applyPauser` · `cancelPauser` · `admin` · `pauser` · `multisigEstablished` · `DELAY` · `pendingTreasury` · `pendingAdmin` · `pendingPauser`

**Pause — removed entirely (FR-004)**

`pause` · `unpause` · `paused`

**Never existed, and must never be added (FR-015, FR-016, FR-017a/b)**

Withdraw, sweep, rescue, or arbitrary-call helpers of any kind · any upgrade or proxy hook · `receive` / `fallback` · any function accepting or naming an ERC-20 token · any token allowlist or per-token configuration

**Removed events**: `ChangeProposed` · `ChangeApplied` · `ChangeCancelled` · `MultisigEstablished`

**Removed errors**: `NotAdmin` · `NotPauser` · `NoPendingChange` · `TimelockNotElapsed` · `MustBeContract`

## Enforcement

`forge inspect TopUpRouter abi` must match this document exactly. Any addition is a spec violation requiring an amendment, not a code review comment — the guarantee that no privileged operation exists is only as strong as the check that keeps one from being added.

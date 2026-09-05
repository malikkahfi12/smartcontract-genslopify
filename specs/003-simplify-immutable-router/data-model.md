# Phase 1 Data Model: Fully Immutable Top-Up Router

**Feature**: `003-simplify-immutable-router` | **Date**: 2026-09-05

All amounts are in base units of native USDC, which on Arc has **6 decimals**: one whole USDC = `1e6` base units (confirmed, research R-001).

## Entities

### Treasury

The single permanent destination for all routed funds.

| Field | Type | Mutability | Validation |
|-------|------|-----------|------------|
| `treasury` | `address` | `immutable`, set in constructor | Non-zero; not `address(this)` |

- Publicly readable at any time (FR-003), via the getter the `public immutable` generates.
- No setter exists at any visibility (FR-001). No pending-change record exists (FR-002).
- **State transitions**: none. Set once at construction; constant for the life of the contract.
- Not required to be a contract or an EOA. A contract treasury is called with full gas, so a Safe works; a treasury that reverts on receipt makes every top-up fail permanently, which is unrecoverable and is why deployment-time validation matters more than it used to.

### Minimum top-up

| Field | Type | Mutability | Value |
|-------|------|-----------|-------|
| `MIN_TOPUP` | `uint256` | `constant` | `1e6` — one whole USDC (FR-006) |

- Not a constructor parameter and not present in deployment configuration (FR-011).
- Identical across every build of a given commit; verifiable from source without inspecting constructor calldata.

### Contribution record

Per-beneficiary lifetime credit.

| Field | Type | Mutability |
|-------|------|-----------|
| `contributions` | `mapping(address => uint256)` | Increases only |

- Keyed by beneficiary, who need not be the payer (anyone may top up on anyone's behalf).
- Denominated in base units of native USDC.
- **Invariant**: monotonically non-decreasing per key. No operation decrements or clears an entry.
- Unwritten keys read zero, indistinguishable from a beneficiary credited zero — which cannot occur, since zero-value top-ups revert.

### Routed total

| Field | Type | Mutability |
|-------|------|-----------|
| `totalRouted` | `uint256` | Increases only |

- **Invariant (INV-2)**: `totalRouted == Σ contributions[a]` over all `a`, at every point between transactions. Verified by the surviving invariant suite and symbolically.
- **Invariant (INV-9)**: independent of `address(this).balance`. Funds forced in by SELFDESTRUCT never affect it, because the balance is never read.
- Overflow is impossible in practice but remains checked; no `unchecked` block is introduced in the accounting path.

### Top-up (transient — an event, not storage)

| Field | Type | Source |
|-------|------|--------|
| `payer` | `address` (indexed) | `msg.sender` |
| `beneficiary` | `address` (indexed) | Caller-supplied, or `msg.sender` for `topUpSelf` |
| `amount` | `uint256` | `msg.value` — never `address(this).balance` |
| `treasury` | `address` | The immutable treasury |
| `newTotal` | `uint256` | `contributions[beneficiary]` after the credit |

- Emitted before the outbound transfer, per checks-effects-interactions.
- `newTotal` is the post-state so a consumer can assert `newTotal == previousTotal + amount` and detect a gap or a duplicate.
- The `treasury` field is retained even though it is now constant: it keeps the off-chain consumer's schema stable across the migration from the 002 router, and a record that names its own destination stays self-contained.

## Removed entities

These existed in the 002 router and are deleted entirely — not disabled, not made unreachable (FR-002, FR-004, FR-014, FR-014a).

| Entity | Was | Removed because |
|--------|-----|-----------------|
| `admin` | `address` storage | FR-014 — no privileged roles |
| `pauser` | `address` storage | FR-004 — no emergency-stop role |
| `multisigEstablished` | `bool` storage | Latch for a governance path that no longer exists |
| `pendingTreasury`, `pendingAdmin`, `pendingPauser` | `PendingChange` storage | FR-002, FR-014a |
| `PendingChange` | struct | Nothing pending can exist |
| `Subject` | enum | No subjects to govern |
| `DELAY` | `uint256 constant` | FR-014a — no operation waits on time |
| `paused` | `Pausable` storage | FR-004 |

## Validation rules

Applied in `_topUp`, in this order, before any state is written:

1. `msg.value != 0` → else `ZeroAmount` (FR-007)
2. `msg.value >= MIN_TOPUP` → else `BelowMinimum(sent, minimum)` (FR-006)
3. `beneficiary != address(0)` → else `ZeroBeneficiary` (FR-007)
4. After effects: the outbound transfer must succeed → else `TreasuryTransferFailed`, unwinding everything (FR-007, FR-008)

Applied in the constructor:

5. `treasury != address(0)` and `treasury != address(this)` → else `ZeroAddress` / `SelfAddress`

There are no other validation paths, because there are no other state-changing entry points.

## Denomination

Every amount above — `MIN_TOPUP`, `contributions`, `totalRouted`, `amount`, `newTotal` — is in base units of native USDC, 6 decimals. The contract performs no scaling and no conversion, and holds no second denomination. Since native and bridged USDC share the 6-decimal scale on Arc, no conversion constant is required and none may be introduced: a `1e12` factor anywhere in this codebase would be a defect, not a safeguard.

Every whole-USDC literal in source, scripts, and tests uses the `1e6` scale. A bare `1e18` in a native-amount position is the defect that rendered the deployed 002 router unusable (R-001) and must be caught on sight.

## Single-currency constraint

The model contains no token entity of any kind (FR-017a/b). There is no token address in storage, in configuration, or in any function signature. The sole value input is `msg.value`. Non-native tokens transferred to the contract address are not represented in this model, do not affect any field above, and are unrecoverable (FR-017c).

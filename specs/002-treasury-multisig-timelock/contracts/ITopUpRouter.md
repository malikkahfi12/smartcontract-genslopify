# Interface Contract: `ITopUpRouter`

**Date**: 2026-09-04 | **Plan**: [plan.md](./plan.md)

The complete external surface of `TopUpRouter`. This is the contract's public API — the thing users,
the multisig, and the off-chain indexer integrate against. Nothing outside this list is callable.

**Design rule for this surface**: every function below either moves the caller's own money to the
treasury, changes governance state under a 2-day delay, or reads. There is deliberately **no**
function that moves funds out of the contract, and no `receive`/`fallback`, so a bare transfer to
the contract reverts.

## Write functions

### `topUp(address beneficiary) external payable`

Routes `msg.value` to `treasury` and credits `beneficiary`.

| | |
|---|---|
| Reverts | `ContractPaused`, `ZeroAmount`, `BelowMinimum(sent, min)`, `ZeroBeneficiary`, `TreasuryTransferFailed` |
| Emits | `ToppedUp` |
| Guards | `whenNotPaused`, `nonReentrant` |
| Requirements | 001 FR-001..FR-009 |

Ordering is strictly checks → effects → interactions: validate, write `contributions` and
`totalRouted`, emit, **then** transfer. The transfer is the final statement.

### `topUpSelf() external payable`

Convenience equivalent to `topUp(msg.sender)`. Same guards, same event, same reverts.

### Governance — propose / apply / cancel

Three subjects (`Treasury`, `Admin`, `Pauser`), each with the same three-verb shape:

| Function | Caller | Effect |
|---|---|---|
| `proposeTreasury(address)` | `admin` | Sets `pendingTreasury`, `eta = now + 2 days`. Replaces any existing proposal and restarts the clock. |
| `applyTreasury()` | **anyone** | Applies once `eta` reached. Clears the slot. |
| `cancelTreasury()` | `admin` | Clears the slot; the change becomes permanently unapplicable. |
| `proposeAdmin(address)` | `admin` | As above. If `multisigEstablished`, target must have code. |
| `applyAdmin()` | **anyone** | Applies; sets `multisigEstablished` if the new admin has code. |
| `cancelAdmin()` | `admin` | Clears the slot. |
| `proposePauser(address)` | `admin` | As above. |
| `applyPauser()` | **anyone** | Applies. |
| `cancelPauser()` | `admin` | Clears the slot. |

`apply*` being permissionless is deliberate: authorization happened at proposal time, and requiring
`admin` to appear twice adds no security while creating an availability risk. The delay and the
quorum are the protection (see data-model.md, "State transitions").

| | |
|---|---|
| Reverts | `NotAdmin`, `ZeroAddress`, `SelfAddress`, `NoPendingChange`, `TimelockNotElapsed(nowTs, eta)`, `MustBeContract` |
| Emits | `ChangeProposed`, `ChangeApplied`, `ChangeCancelled` |
| Requirements | 002 FR-001..FR-023a |

### `pause()` / `unpause()`

| | |
|---|---|
| Caller | `pauser` only |
| Delay | **None** — immediate (002 FR-025) |
| Effect | Blocks `topUp` only. Governance and all reads continue (002 FR-027). |
| Reverts | `NotPauser` |
| Emits | OpenZeppelin `Paused` / `Unpaused` |

The `pauser` cannot propose, apply, or cancel any change (002 FR-026) — enforced by the `onlyAdmin`
modifier on every governance write, tested explicitly in `test/attack/AccessControl.t.sol`.

## Read functions

| Function | Returns | Requirement |
|---|---|---|
| `treasury()` | current destination | 001 FR-009 |
| `admin()` | current authority | 002 FR-018 |
| `pauser()` | current pauser | 002 FR-018 |
| `paused()` | pause state | — |
| `multisigEstablished()` | `false` while single-key | 002 FR-022 |
| `contributions(address)` | that account's lifetime total, `0` if never | 001 FR-011 |
| `totalRouted()` | system-wide lifetime total | 001 FR-012 |
| `pendingTreasury()` | `(target, eta)`; `target == 0` means none | 002 FR-006, FR-030 |
| `pendingAdmin()` | `(target, eta)` | 002 FR-006 |
| `pendingPauser()` | `(target, eta)` | 002 FR-006 |
| `DELAY()` | `172800` — constant | 002 FR-008 |
| `MIN_TOPUP()` | immutable floor | 001 FR-005 |

All reads work while paused. `pendingTreasury()` returning a non-zero target is the signal an
off-chain monitor watches (002 FR-030) — a rotation is visible for its full two days.

## Events

```
event ToppedUp(
    address indexed payer,
    address indexed beneficiary,
    uint256 amount,
    address treasury,
    uint256 newTotal
);

event ChangeProposed(Subject indexed subject, address indexed target, uint64 eta);
event ChangeApplied(Subject indexed subject, address indexed previous, address indexed target);
event ChangeCancelled(Subject indexed subject, address indexed target);
event MultisigEstablished(address indexed admin);

enum Subject { Treasury, Admin, Pauser }
```

**Why `ToppedUp` carries `newTotal` and `treasury`:**
- `newTotal` is the post-state, letting an indexer assert `newTotal == prevTotal + amount` and
  detect a missed or duplicated event immediately instead of drifting silently. This is what makes
  001 SC-008 testable.
- `treasury` records the address that *actually* received the funds, which disambiguates a top-up
  landing in the same block as a rotation (001 edge case).

Resume cursor for the indexer is standard `(blockNumber, logIndex)`; no in-contract sequence number
is added (research R-008).

## Errors

All custom errors, no revert strings (constitution Principle IV).

```
error ContractPaused();
error ZeroAmount();
error BelowMinimum(uint256 sent, uint256 minimum);
error ZeroBeneficiary();
error TreasuryTransferFailed();
error NotAdmin();
error NotPauser();
error ZeroAddress();
error SelfAddress();
error NoPendingChange();
error TimelockNotElapsed(uint256 currentTime, uint256 eta);
error MustBeContract();
```

`BelowMinimum` and `TimelockNotElapsed` carry parameters because in both cases the caller needs the
actual numbers to act — a bare error would send them to a block explorer to find out how long is
left.

## Functions that deliberately do not exist

Listed because their absence is a requirement, and a reviewer should be able to confirm it at a
glance:

| Absent | Why |
|---|---|
| `withdraw` / `sweep` / `rescue` / `emergencyWithdraw` | 001 FR-015 — absolute, all roles |
| `receive()` / `fallback()` | 001 FR-028 — a bare transfer has no beneficiary and must revert |
| Any `execute(address,bytes)` or arbitrary-call helper | 001 FR-017 — would reintroduce withdrawal indirectly |
| `setDelay` | 002 FR-008 — the delay constrains the admin, so the admin cannot change it |
| Any ERC-20 handling | 001 FR-031 — the payment asset is native |
| Any upgrade or proxy admin function | 001 FR-018 — code is immutable |

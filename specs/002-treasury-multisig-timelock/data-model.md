# Phase 1 Data Model: TopUpRouter

**Date**: 2026-09-04 | **Plan**: [plan.md](./plan.md) | **Research**: [research.md](./research.md)

There is no database. "Data model" here means contract storage, its validation rules, its state
transitions, and the invariants that must hold over it.

## Storage

| Name | Type | Mutable by | Description |
|---|---|---|---|
| `treasury` | `address` | `admin`, after 2-day delay | Destination for every top-up. Never zero, never this contract. |
| `admin` | `address` | `admin`, after 2-day delay | Governing authority. Initially the primary key (EOA); later a multisig. |
| `pauser` | `address` | `admin`, after 2-day delay | May pause/resume only. Immediate effect, no delay on its *use*. |
| `paused` | `bool` | `pauser` | Halts `topUp` only. Never blocks governance or reads. |
| `multisigEstablished` | `bool` | set once, automatically | `true` once `admin` has been a contract. Latches; never unset. |
| `totalRouted` | `uint256` | `topUp` | System-wide lifetime total sent to treasuries. Monotonic. |
| `contributions` | `mapping(address => uint256)` | `topUp` | Per-beneficiary lifetime total. Each entry monotonic. |
| `pendingTreasury` | `PendingChange` | `admin` | Proposed treasury and its `eta`. |
| `pendingAdmin` | `PendingChange` | `admin` | Proposed authority and its `eta`. |
| `pendingPauser` | `PendingChange` | `admin` | Proposed pauser and its `eta`. |

```
struct PendingChange {
    address target;   // zero means "no pending change"
    uint64  eta;      // absolute timestamp from which apply is permitted
}
```

**Constants (not storage — unalterable by anyone, 002 FR-008)**

| Name | Value | Source |
|---|---|---|
| `DELAY` | `2 days` (172,800 s) | 002 FR-005 |
| `MIN_TOPUP` | set `immutable` at deployment, non-zero | 001 FR-005 |

`MIN_TOPUP` is `immutable` rather than `constant` because the right floor depends on Arc's gas
costs at launch; it is fixed at construction and never changeable thereafter, per 001 FR-005.

**Explicitly absent**: any `balance` read, any token address, any array of signers, any sweep or
withdraw target. Their absence is the design (001 FR-015/016/017).

## Entities → storage mapping

| Spec entity | Representation |
|---|---|
| Payer | `msg.sender` at `topUp`; recorded in the event, never stored |
| Credited Account | `beneficiary` argument; key of `contributions` |
| Treasury | `treasury` |
| Administrative Authority | `admin` (+ `multisigEstablished` for posture) |
| Signer / Quorum | **Not represented** — lives inside the external multisig (research R-002) |
| Pending Rotation | `pendingTreasury` |
| Waiting Period | `DELAY` |
| Pauser | `pauser` |
| Top-Up Record | `ToppedUp` event (not storage) |
| Lifetime Total | `contributions[account]`, `totalRouted` |
| Governance Record | Governance events |

## Validation rules

**`topUp(beneficiary)` — payable**

| Rule | Requirement |
|---|---|
| not paused | 002 FR-025 |
| `msg.value != 0` | 001 FR-004 |
| `msg.value >= MIN_TOPUP` | 001 FR-005 |
| `beneficiary != address(0)` | 001 FR-004 |
| amount derives only from `msg.value` | 001 FR-007, FR-008 |
| treasury transfer must succeed in full | 001 FR-007, FR-026 |

**Any address-setting governance write**

| Rule | Requirement |
|---|---|
| caller is `admin` | 002 FR-002 |
| `target != address(0)` | 002 FR-003, FR-015 |
| `target != address(this)` | 002 FR-003 |
| for `admin` transfers, if `multisigEstablished` then `target.code.length > 0` | 002 FR-023 |
| apply requires `block.timestamp >= eta` and `target != address(0)` | 002 FR-009, FR-011 |

**Rejected implicitly**: a bare value transfer to the contract. No `receive()` or `fallback()` is
declared, so such a call reverts (001 FR-028). Funds can still be forced in by `selfdestruct`, which
no code can prevent — hence 001 FR-008.

## State transitions

### Pending change lifecycle (identical for treasury, admin, pauser)

```
        ┌─────────┐   propose (admin)          ┌─────────┐
        │  None   │ ─────────────────────────► │ Pending │
        │ (t = 0) │ ◄───────────────────────── │ eta set │
        └─────────┘   cancel (admin)           └─────────┘
             ▲                                      │
             │                                      │ propose again (admin)
             │                                      │ → target replaced, eta RESET to now+2d
             │                                      ▼
             │  apply (anyone, once eta reached)  ┌─────────┐
             └────────────────────────────────────│ Applied │
                        slot cleared              └─────────┘
```

- Proposing while pending **replaces** and restarts the full clock — it can never shorten the wait
  (research R-007).
- Applying is callable by **anyone** once `eta` is reached. The authorization was the proposal;
  requiring `admin` to also apply adds no security and creates an availability risk. The delay and
  the quorum are what protect the change.
- Cancelling clears `target`, making the change permanently unapplicable (002 FR-011).
- No expiry: a pending change stays applicable until applied or cancelled (research R-007).

### Governance posture (one-way, 002 FR-023)

```
  ┌──────────────────┐  apply admin transfer     ┌───────────────────┐
  │ Single key (EOA) │  to address with code     │ Multisig          │
  │ multisig         │ ────────────────────────► │ multisig          │
  │ Established=false│                           │ Established=true  │
  └──────────────────┘                           └───────────────────┘
                                                    │        ▲
                              apply admin transfer  │        │
                              to another contract   └────────┘
                                                 (EOA target now rejected)
```

The latch never resets. Once `true`, an EOA can never again be `admin`.

### Pause

`Active ⇄ Paused`, toggled by `pauser`, immediate, no delay (002 FR-025). Orthogonal to everything
above: pausing blocks `topUp` and nothing else — governance and all reads continue (002 FR-027).

## Invariants

These are the properties the invariant suite asserts across randomized sequences.

| ID | Invariant | Source |
|---|---|---|
| INV-1 | `sum(contributions[*]) == totalRouted` | 001 FR-013 |
| INV-2 | `totalRouted` and every `contributions[a]` are non-decreasing | 001 FR-014 |
| INV-3 | `totalRouted` equals the total value this contract has ever sent out | 001 FR-013 |
| INV-4 | `treasury != address(0)` and `admin != address(0)` at all times | 002 FR-015 |
| INV-5 | `treasury` changes only in a transaction applying a `pendingTreasury` whose `eta` had passed | 002 FR-005, FR-009 |
| INV-6 | `admin` changes only in a transaction applying a `pendingAdmin` whose `eta` had passed | 002 FR-017 |
| INV-7 | Once `multisigEstablished`, `admin.code.length > 0` | 002 FR-023 |
| INV-8 | No sequence of calls increases any caller's native balance at the contract's expense | 001 FR-015, 002 FR-031 |
| INV-9 | Contract accounting is unchanged by funds forced in via `selfdestruct` | 001 FR-008 |
| INV-10 | No `eta` is ever less than its proposal timestamp + `DELAY` | 002 FR-007 |

INV-8 is the one that matters most: it is the formal statement of "no withdrawal exists", and it is
what the `test/attack/` suite attempts to falsify from every role.

## Overflow

`totalRouted` and `contributions` are `uint256` accumulating a token with a finite supply, so
overflow is unreachable in practice. Solidity 0.8 checked arithmetic makes it a revert rather than a
wrap if it ever were reachable, satisfying 001 FR-014 without `unchecked` blocks. No `unchecked` is
used anywhere in the accounting path — the gas saving is not worth weakening the guarantee
(constitution Principle IV: optimization must not reduce safety).

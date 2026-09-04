# Phase 0 Research: TopUpRouter

**Date**: 2026-09-04 | **Plan**: [plan.md](./plan.md)

Decisions resolving the unknowns and technology choices in the Technical Context. Each records
what was chosen, why, and what was rejected.

---

## R-001: Threat model (constitution Principle I gate)

**Decision**: Documented threat model, reproduced here and to be mirrored in the contract's NatSpec
header.

**Assets at risk**:
1. In-flight funds during a `topUp` call (seconds of exposure, one transaction).
2. The *future* stream of top-ups, controlled by whoever controls the `treasury` address.
3. The integrity of the contribution record, which the off-chain ledger trusts (001 Q2).

Note what is *not* at risk: the contract never holds user funds between transactions (001 FR-016),
so there is no pooled balance to drain. This is the single largest reduction in attack surface in
the design, and it is a consequence of the "route directly, no withdrawal" requirement rather than
something added for security.

**Trusted roles**: `admin` (treasury rotation, authority transfer, pauser changes — all delayed
2 days); `pauser` (immediate pause/resume only). Neither can move funds.

**Assumed adversary capabilities**: can call any external function with any arguments; can deploy
malicious contracts and make them the treasury or the caller; can force native funds into the
contract via `selfdestruct`; can reorder and front-run transactions within a block; can nudge block
timestamps within ordinary consensus bounds; may compromise a single signer key, or the primary key
during the single-key window.

**Primary threats and mitigations**:

| Threat | Mitigation |
|---|---|
| Reentrancy via malicious treasury on receive | CEI ordering + `nonReentrant`; the treasury call is the last statement |
| Credit without payment | Amount comes solely from `msg.value`; state written before the transfer; transfer failure reverts everything |
| Forced-balance accounting corruption | `address(this).balance` is never read (001 FR-008) |
| Treasury redirection | 2-day delay + multisig quorum + public pending state + cancellation |
| Delay bypass via authority swap | Authority transfer carries the same 2-day delay (002 FR-017) |
| Delay bypass via parameter change | Delay is a `constant`, not storage (002 FR-008) |
| Griefing via reverting/gas-hungry treasury | Full gas forwarded, success checked, whole tx reverts — user loses gas but no funds |
| Governance lockout | Zero-address and self-address rejected on every authority and treasury write |

**Rationale**: Principle I requires a named threat model before implementation. Writing it first
changed the design twice — it is what ruled out a stranded-funds sweep function and what surfaced
the authority-swap bypass that became 002 FR-017.

**Alternatives considered**: An informal "follow best practices" posture — rejected, because it
would not have caught the authority-swap bypass, which is invisible unless you enumerate paths to
the asset rather than paths through the code.

---

## R-002: Multi-signature mechanism — external multisig vs. in-contract signers

**Decision**: **External multisig held as the `admin` address.** The contract stores a single
`admin` address and checks `msg.sender == admin`. It implements no signature verification, no signer
set, and no quorum logic of its own. The multisig (a Safe or equivalent) is deployed separately and
its address becomes `admin`.

**Rationale**:
- Constitution Principle IV/dependencies guidance prefers audited, widely used implementations over
  bespoke ones. Safe is among the most heavily audited contracts in existence; a hand-rolled M-of-N
  with signature recovery would be new, unaudited code sitting directly on the highest-value control
  in the system.
- It satisfies every governance requirement without new primitives. "Single primary key at
  deployment" (002 FR-019) is simply an EOA as `admin`. "The multisig can be upgraded"
  (002 FR-013) is either changing signers *inside* the Safe — which needs no cooperation from this
  contract at all — or pointing `admin` at a different address. Both work.
- It keeps the bespoke security surface to exactly two things that genuinely must be custom: the
  timelock and the payment path.
- It eliminates an entire class of attacks from scope: signature replay, malleability, nonce
  handling, and quorum-counting bugs cannot exist in code that does not verify signatures.

**Consequences accepted**:
- The contract **cannot verify** that `admin` is genuinely a multisig. 002's edge case already
  anticipated this ("handover to an address that is not actually a multisig"). Mitigated by making
  `admin` publicly readable (002 FR-018) so it is externally auditable, and by the one-way check in
  R-003. It is not fully preventable and is documented as such rather than papered over.
- Quorum is configured in the Safe, not here. `forge` tests exercise governance through a mock
  contract-with-code admin; the fork test exercises it through a real Safe on Arc testnet.

**Alternatives considered**:
- *In-contract M-of-N with EIP-712 signatures*: rejected — significant new attack surface
  (replay, malleability, deadline handling) on the most sensitive control, for no capability gain.
- *OpenZeppelin Governor*: rejected — designed for token-weighted voting, far heavier than needed,
  and irrelevant to a small operator-controlled treasury.

---

## R-003: Enforcing the one-way single-key transition (002 FR-023)

**Decision**: A boolean `multisigEstablished`, set to `true` the first time an authority transfer
completes to an address with non-empty code. Once set, every subsequent authority transfer requires
`newAdmin.code.length > 0`.

**Rationale**: This is the strongest available on-chain approximation of "never return to a single
key". An EOA always has empty code, so the check reliably blocks a return to a plain key. It is
checked at **apply** time, not propose time, so a contract cannot be created after the proposal to
sneak past it.

**Known limitation, stated plainly**: `code.length > 0` proves the target is a contract, not that it
is a multisig or that it is honest. An attacker with `admin` could hand authority to a malicious
contract that forwards everything to a single key. The check raises the cost and makes the
substitution visible on-chain; it does not make it impossible. 002 FR-022's public readability is
what actually lets observers catch this. Recorded as a residual risk rather than claimed as a
guarantee.

**Alternatives considered**:
- *ERC-165 interface probe on the new admin*: rejected — trivially spoofable, so it adds a false
  sense of verification for real complexity.
- *No enforcement, policy only*: rejected — 002 FR-023 requires the contract to reject the
  transition, and the code check is cheap and blocks the accidental case entirely.

---

## R-004: Access control implementation — why not OpenZeppelin `AccessControl`

**Decision**: Two explicit address slots, `admin` and `pauser`, each checked by a dedicated
modifier. No role registry.

**Rationale**: `AccessControl`'s `DEFAULT_ADMIN_ROLE` can grant and revoke every other role,
including granting itself — which is exactly the "single unbounded owner role" constitution
Principle V forbids, and exactly what 001 FR-023 ruled out. Using it and then documenting a
carve-out would be worse than not using it. Two address slots are also dramatically easier to audit:
authority is legible from two storage variables rather than from a mapping's history.

`Ownable` was rejected for the same reason, more obviously.

**Alternatives considered**: `AccessControlDefaultAdminRules` (which adds a delay to admin transfer)
was the closest fit and was seriously considered — but it still centralizes role granting, and this
design needs only two roles, so the dependency buys nothing that ~15 lines of explicit code does not.

---

## R-005: Solidity version and Arc EVM target

**Decision**: Solidity `0.8.28` pinned exactly. `evm_version = "paris"` as the initial conservative
setting, with verification against Arc's actual support as a **blocking pre-mainnet task**.

**Rationale**:
- `0.8.x` gives checked arithmetic by default, removing an entire bug class; a recent patch release
  avoids known codegen issues while being mature enough to be widely exercised.
- `paris` avoids `PUSH0` (Shanghai), transient storage and `MCOPY` (Cancun). A newly launched chain
  may not support the newest opcodes, and a contract that deploys but misbehaves due to an
  unsupported opcode is exactly the Principle VI failure mode. Starting conservative and relaxing
  after verification is the safe direction; the reverse is not.
- Nothing in this design needs post-Paris features. Transient storage would marginally cheapen the
  reentrancy guard; that is not worth a compatibility risk on an immutable contract.

**Open item (blocking for mainnet)**: Arc's published documentation confirms chain ID, RPC,
explorer, and the USDC gas token, but **does not state its supported EVM version**. This must be
confirmed — by documentation or by deploying a probe contract to Arc testnet — before mainnet. If
Arc supports Cancun, `evm_version` may be raised deliberately; it must not be raised by accident via
a toolchain default, which Principle VI explicitly forbids.

---

## R-006: Native value transfer mechanism

**Decision**: `(bool ok, ) = treasury.call{value: msg.value}("")` with an explicit `ok` check and a
custom error on failure. Full gas forwarded. Called last, after all state writes, under
`nonReentrant`.

**Rationale**: `transfer` and `send` forward only 2300 gas, which breaks for any treasury that is a
contract — including a Safe, which is the *intended* treasury. Using them would make the system fail
against its own primary use case, and their 2300-gas stipend has been unreliable across gas-schedule
changes. `call` with a checked return is the current standard practice; the reentrancy risk it
introduces is closed by CEI ordering plus the guard, not by starving the callee of gas.

Because the transfer is last and all state is already written, a re-entering treasury finds fully
consistent state and is blocked by the guard regardless.

**Alternatives considered**: `transfer()` — rejected as above. A pull-payment pattern — rejected
outright: it would mean the contract holds funds, which directly violates 001 FR-016 and would
reintroduce the withdrawal surface the whole feature exists to avoid.

---

## R-007: Timelock semantics — one pending change per subject

**Decision**: Two independent single-slot pending changes — `pendingTreasury` and `pendingAdmin` —
each holding a target address and an `eta` (`block.timestamp + DELAY`). Proposing again for the same
subject **replaces** the pending entry and restarts the full 2-day clock. Applying requires
`block.timestamp >= eta`. Cancelling clears the slot.

**Rationale**:
- Single-slot-per-subject makes 002 FR-012 ("never two applicable pending rotations") structurally
  true rather than something enforced by checks that could be wrong.
- Replace-with-fresh-clock was chosen over reject-while-pending because it cannot be used to grief:
  a wrong proposal can be corrected immediately, and the replacement never inherits elapsed time, so
  it can never shorten the wait. Rejecting-while-pending would force a cancel-then-propose sequence
  with no security benefit.
- Separate slots for treasury and admin mean an urgent authority rotation is not blocked behind a
  pending treasury change. The two are independent concerns and coupling them would create an
  availability problem with no compensating safety gain.
- `eta` is stored absolutely rather than as a start time, so the deadline cannot drift and is
  directly readable by monitors (002 FR-030).

**Timestamp dependence**: block timestamps are manipulable by roughly seconds. Against a 172,800-second
delay this is immaterial, which is precisely why a timestamp is acceptable here when it would not be
for a short-interval control. Block-number-based delay was rejected: Arc's block time is not
guaranteed stable, so a block count would not reliably mean two days.

**No expiry on pending changes**: a stale proposal remains applicable indefinitely. This is
deterministic and matches 002's edge case requirement. An expiry window was considered and rejected
as added complexity that introduces its own failure mode (a legitimate change silently expiring)
without removing a real threat, since any pending change is publicly visible and cancellable for its
entire life.

---

## R-008: Event design for exactly-once off-chain consumption (001 FR-010)

**Decision**: One `ToppedUp` event per successful top-up, carrying `payer` (indexed), `beneficiary`
(indexed), `amount`, `treasury`, and the beneficiary's `newTotal`. Governance actions each emit
their own distinct event including proposals, cancellations, and applications.

**Rationale**: Including `newTotal` — the post-state, not just the delta — gives the off-chain
ledger a self-checking property: a consumer that has processed events in order can assert
`newTotal == previousTotal + amount` and detect a gap or a duplicate immediately rather than
silently drifting. That is what makes 001 SC-008 ("rebuilt from scratch, zero double-counting")
testable rather than aspirational. Including `treasury` in the event satisfies 001's edge case that
the record must name the address that *actually* received the funds, which matters when a rotation
lands in the same block.

Standard `(blockNumber, logIndex)` ordering plus `transactionHash` gives the consumer its resume
cursor; no in-contract sequence number is needed and adding one would cost gas on every top-up for
information the chain already provides.

**Alternatives considered**: Emitting only `(payer, amount)` — rejected, insufficient for
beneficiary attribution or gap detection. Adding an in-contract monotonic nonce — rejected as
redundant with log ordering.

# Feature Specification: USDC Top-Up to Treasury

**Feature Branch**: `001-usdc-topup`

**Created**: 2026-09-03

**Status**: Draft — clarifications resolved

**Input**: User description: "Develop a smart contract that allows users to top up their balance using USDC. Deposited funds should be directly routed to the treasury address, and no withdrawal mechanism should be implemented"

**Resolved clarifications (2026-09-03)**:

- **Q1 → A**: The payment asset is **native USDC** on Arc (18 decimals), sent as the transaction's
  attached value. No token approval step exists, and no ERC-20 token is involved.
- **Q2 → A**: Credited totals are consumed by an **off-chain backend only**. The contract emits
  records and maintains totals as a convenience; the product's own system is the source of truth
  for spendable credit.
- **Q3 → C**: The contract's **code is immutable and non-upgradeable**; only the treasury
  destination address and the governing authority may change, behind a multi-signature authority
  and a delay.

**Superseded by feature 002 (2026-09-04)**: The administrative governance requirements below —
FR-019, FR-020, FR-022, and FR-023 — are superseded by
[`002-treasury-multisig-timelock`](../002-treasury-multisig-timelock/spec.md), which fixes the
delay at 2 days, makes multi-signature authorization explicit, makes the signing authority itself
changeable under the same delay, and defines an initial single-key deployment posture with a
one-way exit. Where the two specs differ, **002 governs**. Everything else in this document remains
authoritative — in particular the no-withdrawal guarantee (FR-015/016/017), code immutability
(FR-018), and all top-up, accounting, and chain-specific requirements, none of which 002 weakens.
Superseded requirements are retained below, marked and cross-referenced, rather than deleted, so
the history of the decision stays legible.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Top up with native USDC (Priority: P1)

A user wants to add credit to their account. They submit a single transaction to the top-up
contract with USDC attached as the transaction's value. The funds move immediately and
irreversibly to the treasury address within that same transaction, and the system produces a
permanent, publicly verifiable record that credits that amount to the user's identity. The user
can point to that record as proof of payment.

**Why this priority**: This is the entire product. Without it there is no feature. It is also the
only path by which value enters the system, so every other story depends on it.

**Independent Test**: Fully testable in isolation — a funded account performs one top-up, and the
test asserts the treasury balance increased by exactly the amount attached, the contract retains
nothing from the top-up, and a record attributing the amount to that user was emitted. Delivers
complete value on its own.

**Acceptance Scenarios**:

1. **Given** a user holding at least the minimum top-up amount of USDC plus enough to cover their
   transaction cost, **When** they submit a top-up with that amount attached, **Then** the full
   attached amount arrives at the treasury address in the same transaction, the contract retains
   none of it, and a record is produced naming the payer, the credited account, the amount, the
   receiving treasury address, and the running lifetime total for that account.
2. **Given** a user who has previously topped up, **When** they top up again, **Then** the new
   amount is added to their lifetime total and a new record is produced; earlier records remain
   unchanged and independently readable.
3. **Given** a user, **When** they submit a top-up with zero value attached, **Then** the
   operation is rejected with a clear reason and no record is produced.
4. **Given** a user whose holdings are less than the amount they attempt to attach, **When** they
   submit the top-up, **Then** the transaction cannot proceed, no funds move, and their lifetime
   total is unchanged.
5. **Given** a user, **When** they submit a top-up with an amount below the configured minimum,
   **Then** the operation is rejected and their full amount remains theirs.

---

### User Story 2 - Top up on behalf of another account (Priority: P2)

A payer wants to credit an account other than their own — a sponsor funding a team member, a
custodial operator funding an end user, or a payment processor settling for a customer. They name
the account to be credited when submitting. The funds still route to the treasury, and the record
distinguishes who paid from who was credited.

**Why this priority**: It substantially widens who can use the system (sponsorships, custodial and
agency flows) without changing the money path, but the product is viable without it.

**Independent Test**: A payer account tops up naming a different beneficiary; the test asserts the
beneficiary's lifetime total increased, the payer's did not, the treasury received the full
amount, and the record names both parties.

**Acceptance Scenarios**:

1. **Given** a payer with sufficient USDC, **When** they top up naming a beneficiary other than
   themselves, **Then** the beneficiary's lifetime total increases by the attached amount, the
   payer's lifetime total is unchanged, and the record names both.
2. **Given** a payer, **When** they name an empty beneficiary address, **Then** the operation is
   rejected and no funds move.

---

### User Story 3 - Reconcile and audit top-up history (Priority: P2)

A finance operator, an auditor, or the product's own backend needs to reconcile what users paid
against what the treasury received. They read the system's permanent record of top-ups and its
running totals, and confirm that the sum of all credited amounts equals the total routed to the
treasury, with nothing unaccounted for.

**Why this priority**: Money that cannot be reconciled cannot be recognized as revenue or credited
reliably in the product. Because credit is consumed by an off-chain backend (Q2), the records are
that backend's only input, so their completeness and ordering are operationally critical. Still
not required for a first demonstrable top-up.

**Independent Test**: Perform a series of top-ups from several accounts, then independently sum the
emitted records and compare against both the reported per-account totals and the amount the
treasury received; all three must agree exactly.

**Acceptance Scenarios**:

1. **Given** any sequence of successful top-ups, **When** the recorded amounts are summed, **Then**
   the total equals the reported system-wide lifetime total and equals the amount the treasury
   received from the contract.
2. **Given** an account that has never topped up, **When** its lifetime total is read, **Then** the
   result is zero and no error occurs.
3. **Given** any sequence of successful top-ups, **When** the contract's own holdings are
   inspected, **Then** the amount attributable to top-ups is zero, independent of any funds
   forced into the contract by other means.
4. **Given** the off-chain backend has processed all records up to a point, **When** it resumes
   from that point, **Then** it can determine unambiguously which top-ups it has already counted
   and never double-credits an account.

---

### User Story 4 - Change the treasury destination (Priority: P3)

The organization rotates its treasury — a key rotation, a move to a new multisig, or a migration to
a different custodian. Authorized administrators propose the change, it becomes effective only
after a mandatory delay, and all subsequent top-ups route to the new treasury. Past top-ups are
unaffected. Code remains immutable (Q3); only governance state changes.

> **Superseded by 002.** This story is refined by
> [`002-treasury-multisig-timelock`](../002-treasury-multisig-timelock/spec.md) User Stories 1–4,
> which fix the delay at 2 days, require a multi-signature quorum, and extend the same delay to
> changes of the governing authority itself. The scenarios below remain correct but are less
> specific than 002's; **plan against 002**.

**Why this priority**: Needed over the lifetime of the deployment, and its absence would force a
redeployment and a client migration. But the first release can operate with the initial
destination.

**Independent Test**: Authorized administrators propose a change; the test asserts it cannot take
effect before the delay elapses, that it does take effect after, that a subsequent top-up arrives
at the new address, and that an unauthorized account attempting the same is rejected.

**Acceptance Scenarios**:

1. **Given** authorized administrators, **When** they propose a new valid treasury address,
   **Then** a record of the proposal is produced naming the old and new addresses and the earliest
   time it may take effect.
2. **Given** a proposed treasury change whose delay has not yet elapsed, **When** anyone attempts
   to apply it, **Then** the attempt is rejected and top-ups continue routing to the current
   treasury.
3. **Given** a proposed treasury change whose delay has elapsed, **When** it is applied, **Then** a
   record of the change is produced and all subsequent top-ups arrive at the new address.
4. **Given** an account without administrative authority, **When** it attempts to propose or apply
   a treasury change, **Then** the attempt is rejected and the destination is unchanged.
5. **Given** administrators, **When** they attempt to set the destination to an empty address or to
   the contract's own address, **Then** the attempt is rejected.
6. **Given** a pending treasury change, **When** administrators cancel it before it takes effect,
   **Then** a record of the cancellation is produced and the destination remains unchanged.

---

### User Story 5 - Pause top-ups during an incident (Priority: P3)

During a suspected incident, a compromised treasury, or a treasury migration, authorized
administrators halt new top-ups so that no further funds enter a destination that may be unsafe.
Once resolved, administrators resume normal operation.

> **Refined by 002.** Pause authority is specified in detail in
> [`002-treasury-multisig-timelock`](../002-treasury-multisig-timelock/spec.md) User Story 5 and
> FR-024–FR-027: it must be separable from and easier to satisfy than the treasury-rotation
> quorum, and must take effect immediately with no waiting period.

**Why this priority**: A pure safety control. It prevents loss during the window between
discovering a problem and fixing it — which matters more here than usual, because an immutable
contract (Q3) cannot be patched and a misdirected top-up cannot be refunded. Still not part of the
core value path.

**Independent Test**: An administrator pauses; a user top-up attempt is rejected and no funds move.
An administrator resumes; the same attempt now succeeds.

**Acceptance Scenarios**:

1. **Given** authorized administrators have paused top-ups, **When** any user attempts a top-up,
   **Then** it is rejected with a clear reason, no funds move, and the user's full amount remains
   theirs.
2. **Given** the system is paused, **When** administrators resume it, **Then** top-ups succeed
   again and lifetime totals continue from their prior values.
3. **Given** an account without administrative authority, **When** it attempts to pause or resume,
   **Then** the attempt is rejected.
4. **Given** the system is paused, **When** anyone reads any lifetime total, **Then** the reads
   still succeed; pausing halts new top-ups only, never the record.

### Edge Cases

- **Zero and below-minimum amounts**: Rejected rather than silently recorded, so the record never
  contains meaningless entries and users are never charged a transaction cost for a no-op credit.
- **Empty beneficiary**: A top-up naming an empty address is rejected, so credit is never assigned
  to an unrecoverable identity.
- **Treasury refuses receipt**: If the destination cannot accept the transfer, or consumes
  excessive gas doing so, the top-up fails atomically. Funds are never stranded in the contract
  and the user is never credited for a transfer that did not land.
- **Treasury re-enters on receipt**: The destination is a contract that calls back into the top-up
  contract when it receives funds. This MUST NOT allow a second credit, a double record, or any
  inconsistency between funds moved and totals recorded.
- **Gas token is the payment token**: On Arc, USDC pays for both the top-up and the transaction
  itself. A user attempting to top up their entire holdings will fail for lack of transaction
  cost. The system MUST NOT attempt to compensate for this, but the failure MUST be clean — no
  partial credit, no partial transfer.
- **Funds forced into the contract**: USDC can be pushed into the contract by means that no code
  can refuse. Such funds are not credited to anyone and are permanently stranded. The system MUST
  NOT read its own holdings when deciding what to credit or transfer, so forced funds can never
  inflate a credit, corrupt reconciliation, or cause a top-up to fail.
- **Treasury changed mid-flight**: A treasury change and a user's top-up landing in the same block
  must not produce an outcome where the funds and the record disagree about the destination; the
  record MUST name the address that actually received the funds.
- **Repeated top-ups and overflow**: An account tops up many times over the deployment's life; its
  lifetime total must accumulate correctly without wrapping or silently saturating.
- **Duplicate submission**: A user submits the same top-up twice; both are treated as two
  independent, separately recorded top-ups, not deduplicated. The off-chain backend must be able
  to distinguish them.
- **Unexpected call to the contract**: An account sends a transaction to the contract that matches
  no defined operation. The system MUST reject it and MUST NOT treat it as an implicit top-up,
  since such a transaction carries no beneficiary and would otherwise create an uncreditable
  payment.
- **Immutability under a discovered bug**: Because the code cannot be changed (Q3), the only
  available responses to a defect are pausing and redeploying. The pause control MUST therefore
  remain functional under every state the contract can reach.

## Requirements *(mandatory)*

### Functional Requirements

**Top-up**

- **FR-001**: The system MUST allow any account to top up by attaching a chosen amount of native
  USDC to a single transaction. No prior authorization or approval step exists.
- **FR-002**: The system MUST route the full attached amount directly to the treasury address
  within the same transaction, retaining no portion of it.
- **FR-003**: The system MUST retain zero funds attributable to top-ups. Any amount forced into
  the contract by means outside the top-up operation is explicitly out of this accounting and MUST
  NOT affect it.
- **FR-004**: The system MUST reject a top-up of zero and MUST reject a top-up that names an empty
  beneficiary address.
- **FR-005**: The system MUST enforce a minimum top-up amount, fixed at deployment to a non-zero
  value, and MUST reject amounts below it.
- **FR-006**: The system MUST allow a payer to credit an account other than their own, and MUST
  record the payer and the credited account distinctly.
- **FR-007**: The system MUST credit exactly the amount attached to the transaction and exactly the
  amount transferred to the treasury; these three amounts MUST always be equal. If the transfer to
  the treasury does not succeed in full, the entire top-up MUST fail.
- **FR-008**: The system MUST NOT determine the amount to credit or to transfer by reading its own
  holdings; the amount MUST come solely from the value attached to the transaction.

**Records and accounting**

- **FR-009**: The system MUST produce a permanent, publicly readable record for every successful
  top-up, naming at minimum the payer, the credited account, the amount credited, the treasury
  address that received the funds, and the credited account's resulting lifetime total.
- **FR-010**: Records MUST be sufficient for an off-chain consumer to process them exactly once,
  in order, and to resume after an interruption without double-counting or omission.
- **FR-011**: The system MUST maintain a per-account lifetime total of all amounts credited to that
  account, readable by anyone at any time, returning zero for accounts that have never been
  credited.
- **FR-012**: The system MUST maintain a system-wide lifetime total of all amounts routed to the
  treasury, readable by anyone.
- **FR-013**: The sum of all per-account lifetime totals MUST always equal the system-wide lifetime
  total, which MUST always equal the total funds this contract has sent to treasury addresses.
- **FR-014**: Recorded totals MUST be monotonically non-decreasing; no operation may reduce or
  reset any lifetime total.

**No withdrawal**

- **FR-015**: The system MUST NOT expose any mechanism — for users, administrators, or any other
  party — to withdraw, refund, reclaim, or redirect funds. This prohibition is absolute, applies to
  every role, and extends to funds forced into the contract, which are accepted as permanently
  stranded rather than made recoverable.
- **FR-016**: The system MUST NOT hold custody of user funds between transactions; there is no
  contract-held balance for any withdrawal mechanism to target.
- **FR-017**: The system MUST NOT expose any general-purpose mechanism that would let a privileged
  party execute arbitrary calls, move arbitrary assets, or otherwise reintroduce a withdrawal path
  indirectly.
- **FR-018**: The system's code MUST be immutable and non-upgradeable, so that the absence of a
  withdrawal path cannot be revoked by a later change. The treasury destination is the only
  mutable state governed by administrators.

**Administration**

> **FR-019, FR-020, FR-022 and FR-023 are SUPERSEDED by
> [`002-treasury-multisig-timelock`](../002-treasury-multisig-timelock/spec.md).** They are
> retained here for history. Implement 002's requirements, which are strictly stronger. FR-021 and
> FR-024 remain in force and are refined, not replaced, by 002.

- **FR-019** *(SUPERSEDED by 002 FR-001–FR-009)*: The system MUST allow authorized administrators
  to change the treasury destination address only through a two-step process: a proposal, then
  application after a mandatory delay has elapsed. It MUST reject an empty destination and MUST
  reject its own address as a destination. — *002 fixes the delay at exactly 2 days, requires a
  multi-signature quorum, and forbids any bypass.*
- **FR-020** *(SUPERSEDED by 002 FR-010–FR-012)*: The system MUST allow authorized administrators
  to cancel a pending treasury change before it takes effect. — *002 adds that a cancelled change
  can never be applied and that two applicable pending changes may never coexist.*
- **FR-021** *(IN FORCE; refined by 002 FR-024–FR-027)*: The system MUST allow authorized
  administrators to pause and resume top-ups, and MUST reject all top-ups while paused. Pausing
  MUST NOT affect reads of any recorded total.
- **FR-022** *(SUPERSEDED by 002 FR-002)*: The system MUST reject every administrative action
  attempted by an account without the corresponding authority. — *002 additionally requires
  rejection of below-quorum approval sets, not merely non-signers.*
- **FR-023** *(SUPERSEDED by 002 FR-019–FR-023a)*: Administrative authority MUST be role-based and
  least-privilege, with no single unbounded owner role, and MUST be held by a multi-party signer.
  The pause and treasury-change authorities MUST be separable, so that an urgent pause does not
  require the same quorum as a treasury rotation.
  — **Reconciliation note**: 002 permits a *single primary key* as the initial administrative
  authority, which contradicts this requirement as originally written. 002 governs. The
  contradiction is resolved by treating the single-key posture as an explicitly time-limited
  transitional exception, not a steady state: it is one-way (002 FR-023), it grants no privilege
  beyond reducing the number of approvals (002 FR-020), it is bound by the same 2-day delay on
  every action including its own handover (002 FR-017, FR-023a), and it is publicly visible so
  users can price the risk (002 FR-022). The separability of pause and rotation authority required
  here is preserved in 002 FR-024–FR-026.
- **FR-024** *(IN FORCE; refined by 002 FR-028–FR-030)*: The system MUST produce a record of every
  administrative action affecting where funds go or whether top-ups are accepted, including
  proposals and cancellations.

**Security**

- **FR-025**: The system MUST resist reentrancy on the top-up path, including reentrancy attempted
  by the treasury destination when it receives funds.
- **FR-026**: A top-up MUST be atomic: either the treasury receives the full amount and the record
  is produced, or nothing changes at all.
- **FR-027**: The system MUST NOT allow any party to increase an account's lifetime total without a
  corresponding, equal transfer of funds to the treasury.
- **FR-028**: The system MUST reject any transaction that does not correspond to a defined
  operation, including a bare transfer of value carrying no beneficiary.
- **FR-029**: The attack scenarios required by the project constitution — reentrancy,
  access-control bypass, arithmetic boundaries, denial of service and gas griefing, forced-balance
  manipulation, and front-running — MUST each have an explicit failing-exploit test against this
  contract.

**Chain-specific**

- **FR-030**: The system MUST treat the payment asset as native USDC with 18 decimals on Arc, and
  MUST NOT assume the 6-decimal convention associated with bridged USDC anywhere in its logic,
  records, or configuration.
- **FR-031**: The system MUST NOT accept any asset other than the native payment asset; it holds no
  facility for receiving or handling tokens.

### Key Entities

- **Payer**: The account that supplies the USDC for a top-up. May or may not be the credited
  account.
- **Credited Account**: The account whose lifetime total increases as a result of a top-up. The
  identity against which the off-chain product recognizes the payment.
- **Treasury**: The single destination address that receives all top-up funds. Changeable only by
  authorized administrators through a delayed two-step process; never a contract-held pool. See
  002 for the governing authority and the 2-day delay.
- **Top-Up Record**: The permanent, publicly readable evidence of one successful top-up — payer,
  credited account, amount, receiving treasury address, and resulting lifetime total. The sole
  input to the off-chain crediting system.
- **Lifetime Total**: A per-account, monotonically non-decreasing sum of every amount ever credited
  to that account. Also maintained system-wide.
- **Administrator**: The multi-party authority permitted to propose, apply, and cancel treasury
  changes and to pause or resume top-ups. Explicitly not permitted to move funds or change code.
- **Off-Chain Credit Ledger**: The product's own system, outside this contract's scope, which
  consumes top-up records and is the source of truth for spendable credit.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of successfully paid top-up amounts arrive at the treasury address in the same
  transaction as the payment, with zero retained by the system.
- **SC-002**: At every point in the contract's life, an independent audit of the public record
  reconciles top-ups to treasury receipts to the exact unit, with zero unexplained discrepancy —
  and this holds regardless of any funds forced into the contract.
- **SC-003**: A user completes a top-up in exactly one submitted transaction with no preparatory
  step, and sees confirmation of their credited amount without any manual reconciliation.
- **SC-004**: No party — user, administrator, or any other — can extract funds from the system.
  Demonstrated by an exhaustive review of every callable operation plus explicit tests attempting
  extraction from each role, all of which fail.
- **SC-005**: Every attack scenario mandated by the project constitution has an explicit test that
  attempts the exploit and asserts it fails; the suite achieves at least 95% line and branch
  coverage, and stateful invariant testing confirms the reconciliation identity of SC-002 holds
  across randomized sequences of operations including forced-balance manipulation.
- **SC-006**: A finance operator can determine any account's total lifetime contribution, and the
  system-wide total, at any time from public data without privileged access.
- **SC-007**: A treasury rotation takes effect for all subsequent top-ups with no interruption to
  users and no loss or misattribution of any in-flight or historical top-up, and cannot take effect
  in less than the mandated delay — fixed at 2 days by 002 SC-001.
- **SC-008**: The off-chain credit ledger, rebuilt from scratch from public records alone, produces
  per-account totals identical to those the contract reports, with zero double-counted or missed
  top-ups.

## Assumptions

- **Payment asset (Q1 → A)**: Users pay in native USDC on Arc, 18 decimals, attached as transaction
  value. There is no ERC-20 token, no approval flow, and therefore none of the non-standard-token
  hazards (fee-on-transfer, rebasing, missing return values) that an ERC-20 design would face. In
  exchange, the design must contend with native-transfer hazards instead: a reverting or
  gas-hungry recipient, reentrancy on receipt, and funds forced in by means code cannot refuse.
- **Balance semantics (Q2 → A)**: "Top up their balance" means a permanent, publicly verifiable
  record of contribution consumed by an off-chain backend, not a redeemable on-chain balance. This
  follows necessarily from the stated constraints: funds leave for the treasury immediately and no
  withdrawal exists, so no redeemable balance can exist. On-chain totals are a convenience and a
  reconciliation aid; the product's own system is the source of truth for spendable credit.
- **Mutability (Q3 → C)**: Contract code is immutable and non-upgradeable. Only the treasury
  address and the governing authority change, behind a multi-signature authority and a mandatory
  2-day delay as specified in 002. A defect in deployed code is
  remediated by pausing and redeploying, not by patching — so the pause control is the sole
  incident response and must be reachable in every state.
- **Target chain**: Deployment targets the Arc chain, per the project constitution. Arc Testnet is
  chain ID 5042002 and uses USDC as its native gas token with 18 decimals. Arc mainnet parameters
  are not yet published (tracked as `TODO(ARC_MAINNET_PARAMS)` in the constitution).
- **Treasury address**: An externally controlled multisig. Assumed capable of receiving native
  transfers without consuming excessive gas. If it ever cannot, top-ups fail safely rather than
  stranding funds.
- **Gas**: Users pay their own transaction costs, denominated in USDC — the same asset as the
  top-up. A user therefore cannot top up their entire holdings. No meta-transaction or
  sponsored-gas mechanism is in scope.
- **Refunds**: Out of scope entirely. The no-withdrawal constraint means erroneous or duplicate
  top-ups cannot be reversed on-chain. Any remediation is an off-chain business process against the
  treasury.
- **Stranded funds**: USDC forced into the contract is permanently unrecoverable and uncredited.
  This is accepted deliberately: any recovery path would violate FR-015.
- **Fees**: The system takes no fee. The full paid amount reaches the treasury.
- **Off-chain integration**: The backend or indexer consuming top-up records is assumed to exist and
  is out of scope for this contract, but FR-010 and SC-008 constrain the contract to make that
  consumer's job correct and resumable.

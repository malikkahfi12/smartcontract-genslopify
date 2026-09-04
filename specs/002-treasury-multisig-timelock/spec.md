# Feature Specification: Treasury Multi-Sig Governance with 2-Day Timelock

**Feature Branch**: `002-treasury-multisig-timelock`

**Created**: 2026-09-04

**Status**: Draft — clarifications resolved

**Input**: User description: "Change address treasury must need multi-sig for security and set the waiting time to 2 days, The multisig can also be upgradable. For the initial deployment, providing only the primary key is sufficient"

**Relationship to prior work**: This feature refines and supersedes the administrative governance
requirements of [`001-usdc-topup`](../001-usdc-topup/spec.md) — specifically FR-019, FR-020,
FR-022, and FR-023, which established a propose/delay/apply treasury rotation held by an
unspecified "multi-party signer" with an unspecified delay. This specification fixes the delay at
2 days, makes multi-signature authorization explicit and mandatory, makes the signing authority
itself changeable, and defines the initial single-key deployment posture. All other requirements
of 001 — most importantly the absolute no-withdrawal guarantee (FR-015/016/017) and code
immutability (FR-018) — remain in force and are not weakened by anything here.

**Resolved clarifications (2026-09-04)**:

- **Q1 → A**: The 2-day waiting period applies to **transfers of administrative authority as well
  as treasury rotations**. Every path that can lead to the treasury is gated by the same delay,
  including the initial handover from the primary key to the multisig.
- **Q2 → A**: The waiting period is **permanently fixed at 2 days** and cannot be changed by any
  party. Changing it requires redeployment.
- **Q3 → A**: The single-key posture is **one-way**. Once administrative authority rests with a
  multi-signature arrangement, it can never return to a single key.

## Clarifications

### Session 2026-09-04

- Q: On the live Arc testnet deployment, should the treasury-rotation waiting period stay the full 2 days, or be shortened so governance rehearsals don't take two days each? → A: A — keep `DELAY` a hard-coded 2-day constant everywhere; testnet and mainnet run identical bytecode and testnet rehearsals take the full 48 hours.
- Q: On testnet, should the treasury be a plain wallet address, or a deployed contract such as a Safe? → A: B — a plain wallet (EOA) address on testnet; the contract-recipient path remains covered by automated tests against the malicious//gas-hungry treasury mocks, but is not exercised in the live deployment.
- Q: With scope limited to testnet, does the independent external audit stay a required gate, or is it dropped until a production deployment is actually planned? → A: A — out of testnet scope; recorded as a deferred obligation that re-activates when a mainnet deployment is proposed.
- Q: When should the Arc EVM version be confirmed — before any contract code is written, or later as a pre-deployment check? → A: A — verify in Phase 1 via a probe deployment to Arc testnet, then set `evm_version` deliberately before `TopUpRouter.sol` is written.
- Q: On Arc testnet, will you actually perform the handover from the single primary key to a real multisig, or will testnet stay under single-key control permanently? → A: B — testnet remains single-key permanently; the handover is validated by automated tests against a mock multisig only, and no live handover rehearsal is performed.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Rotate the treasury under multi-signature approval (Priority: P1)

The organization needs to move its treasury to a new address — a key rotation, a move to a new
custodian, or a migration to a different multisig. No single person can do this alone. A quorum of
authorized signers must approve the change, and even once approved it does not take effect for two
full days, giving the organization and the public a window to notice and react to an unexpected
rotation before any funds reach the new address.

**Why this priority**: The treasury address is the single point at which all user money lands.
Whoever can change it can redirect every future top-up. This is the highest-value target in the
system and the control that most needs to be sound.

**Independent Test**: A quorum of signers approves a rotation to a new address; the test asserts
that the change cannot take effect before two days have elapsed, that it does take effect after,
that a subsequent top-up arrives at the new address, and that no quantity of approvals below the
quorum can make it happen at all.

**Acceptance Scenarios**:

1. **Given** a quorum of authorized signers, **When** they approve a rotation to a new valid
   address, **Then** the change is recorded as pending, a record is produced naming the previous
   address, the new address, and the exact time at which it becomes applicable, and top-ups
   continue routing to the current treasury.
2. **Given** a pending rotation whose two-day waiting period has not fully elapsed, **When** anyone
   attempts to apply it, **Then** the attempt is rejected and top-ups continue routing to the
   current treasury.
3. **Given** a pending rotation whose two-day waiting period has elapsed, **When** it is applied,
   **Then** a record of the completed change is produced and every subsequent top-up arrives at the
   new address.
4. **Given** a number of approving signers below the required quorum, **When** they attempt to
   propose or apply a rotation, **Then** the attempt is rejected and no pending change is created.
5. **Given** an account that is not an authorized signer at all, **When** it attempts to approve,
   propose, or apply a rotation, **Then** the attempt is rejected.
6. **Given** signers attempting to rotate to an empty address, or to the top-up contract's own
   address, **When** they propose it, **Then** the proposal is rejected.

---

### User Story 2 - Cancel a rotation during the waiting period (Priority: P1)

An unexpected or unauthorized rotation appears as pending — perhaps a signer key was compromised,
perhaps the wrong address was entered. The organization uses the two-day window for exactly what it
exists for: it cancels the pending change before any funds can be redirected, and separately pauses
top-ups if it suspects a compromise.

**Why this priority**: A waiting period is only a security control if something can actually be
done during it. Without cancellation the delay merely announces the theft two days in advance.
This is inseparable from User Story 1 and shares its priority.

**Independent Test**: A pending rotation is created, then cancelled by an authorized quorum; the
test asserts the pending change is gone, that applying it afterwards fails, and that the treasury
destination is unchanged.

**Acceptance Scenarios**:

1. **Given** a pending rotation inside its waiting period, **When** an authorized quorum cancels
   it, **Then** a record of the cancellation is produced, the pending change no longer exists, and
   the treasury destination is unchanged.
2. **Given** a cancelled rotation, **When** anyone attempts to apply it after the original waiting
   period would have elapsed, **Then** the attempt is rejected.
3. **Given** a pending rotation, **When** an account below the cancellation authority attempts to
   cancel it, **Then** the attempt is rejected and the rotation remains pending.
4. **Given** a pending rotation, **When** a new rotation is proposed before the first is resolved,
   **Then** the system's behaviour is unambiguous — either the second is rejected while one is
   pending, or it replaces the first with its own fresh two-day period. It MUST NOT be possible for
   two pending rotations to exist such that either could be applied.

---

### User Story 3 - Change the signing authority itself (Priority: P2)

The set of people who control the treasury changes — someone leaves the organization, a signer's
key is rotated, the quorum needs raising as the treasury grows, or the organization moves to an
entirely different signing arrangement. Authorized signers change the governing authority itself.
The contract's code remains immutable; only who governs it changes.

**Why this priority**: Without this, a departed employee retains treasury control forever and a
single lost key permanently degrades the quorum, with no remedy short of redeployment. It is
essential over the deployment's life but the system operates correctly on day one without it.

**Independent Test**: The current authority changes the signing arrangement to a new one; the test
asserts the old authority can no longer act, the new authority can, and that the transition itself
required proper authorization.

**Acceptance Scenarios**:

1. **Given** the current authorized signing authority, **When** it changes the signing arrangement
   to a new valid one, **Then** a record is produced naming the previous and new authority, and
   subsequent administrative actions require the new authority.
2. **Given** a completed change of signing authority, **When** the previous authority attempts any
   administrative action, **Then** the attempt is rejected.
3. **Given** any party other than the current authority, **When** it attempts to change the signing
   authority, **Then** the attempt is rejected.
4. **Given** an attempt to set the signing authority to an empty address, or to an arrangement that
   nobody can satisfy, **When** it is submitted, **Then** it is rejected, so that the system can
   never be left ungovernable.
5. **Given** a pending treasury rotation, **When** the signing authority changes while it is
   pending, **Then** the outcome is unambiguous and does not allow the pending rotation to bypass
   its remaining waiting period.

---

### User Story 4 - Deploy with a single primary key and harden afterwards (Priority: P2)

At deployment, setting up a full multi-signature arrangement is operationally burdensome and would
delay launch. The contract is therefore deployed with a single primary key holding administrative
authority. Once the multisig is provisioned, the primary key initiates a handover to it — which,
like every other governance change, becomes effective only after two days. When it completes, the
single-key posture is gone permanently and cannot be restored.

**Why this priority**: It is what makes launch practical, and it is the explicit request. But it is
also the system's most dangerous state, so it is specified as a transitional posture with a defined,
one-way exit rather than a supported steady state.

**Independent Test**: The contract is deployed with one primary key; the test asserts that key can
initiate governance actions, that the full two-day waiting period applies to it exactly as it would
to a multisig, that the handover to a multi-signature authority itself waits two days, that
afterwards the original key can no longer act, and that no path returns authority to a single key.

> **Testnet scope (Session 2026-09-04, Q2 → B)**: On Arc testnet the deployment remains under
> single-key authority permanently; no live handover is performed. Every acceptance scenario below
> is therefore validated by automated tests against a mock multisig rather than by a live rehearsal.
> The contract mechanics are fully proven; the *operational* procedure — signer coordination, Safe
> configuration, executing inside the 48-hour window — is not exercised, and would first be
> performed live at whatever point a production deployment happens.

**Acceptance Scenarios**:

1. **Given** a freshly deployed system whose administrative authority is a single primary key,
   **When** that key proposes a treasury rotation, **Then** the rotation is subject to the same
   full two-day waiting period and the same cancellation window as it would be under a multisig.
   The waiting period is never shortened or waived for a single-key authority.
2. **Given** a single-key authority, **When** it proposes handing administrative authority to a
   multi-signature arrangement, **Then** the handover is recorded publicly as pending with its
   effective time, and MUST NOT take effect for two days.
3. **Given** a pending handover whose two-day period has elapsed, **When** it is applied, **Then**
   the multi-signature arrangement becomes the administrative authority and the original primary
   key can no longer perform any administrative action.
4. **Given** a system now under multi-signature authority, **When** any party attempts to transfer
   administrative authority back to a single-key arrangement, **Then** the attempt is rejected.
   The transition is one-way and permanent.
5. **Given** a freshly deployed system, **When** anyone reads the system's governance state,
   **Then** it is publicly and unambiguously determinable whether authority currently rests with a
   single key or a multi-signature arrangement, so that users and auditors can assess their risk
   before topping up.
6. **Given** a single-key authority, **When** an account other than that key attempts any
   administrative action, **Then** the attempt is rejected.
7. **Given** a pending handover to a multisig, **When** the primary key cancels it before it takes
   effect, **Then** the cancellation is recorded and authority remains with the primary key — so a
   handover to a wrong or unready address can be caught during its window.

---

### User Story 5 - Pause without waiting (Priority: P2)

A compromise is suspected. Waiting two days to react is unacceptable — every top-up in the meantime
lands somewhere potentially unsafe, and none of it can be refunded. An authorized party halts
top-ups immediately, with no waiting period, using an authority deliberately easier to satisfy than
the one that moves the treasury.

**Why this priority**: Pausing is the only immediate response available, since the contract's code
is immutable and top-ups cannot be reversed. Its value depends entirely on being fast, which means
it must not be behind the same delay or the same quorum as a rotation.

**Independent Test**: An authorized pauser halts top-ups in a single action with no waiting period;
the test asserts top-ups fail immediately afterwards, and that the pauser cannot use that authority
to move the treasury.

**Acceptance Scenarios**:

1. **Given** an authorized pauser, **When** they pause top-ups, **Then** the pause takes effect
   immediately with no waiting period and all subsequent top-ups are rejected.
2. **Given** an authorized pauser, **When** they attempt to propose, approve, apply, or cancel a
   treasury rotation using only their pause authority, **Then** the attempt is rejected.
3. **Given** a paused system, **When** the authority resumes top-ups, **Then** top-ups succeed
   again and all recorded totals continue from their prior values.
4. **Given** a paused system, **When** a pending treasury rotation's waiting period elapses,
   **Then** the rotation can still be applied or cancelled; pausing top-ups does not freeze
   governance.

### Edge Cases

- **Exact boundary of the waiting period**: A rotation applied at the precise moment two days
  elapse must have an unambiguous, tested outcome. One second early MUST fail; the moment of
  expiry onward MUST succeed.
- **Chain time manipulation**: Block timestamps can be nudged by whoever produces blocks. The
  two-day period MUST remain meaningful under the maximum plausible drift, and MUST NOT be
  short-circuitable to a materially smaller wait.
- **Stale pending change**: A rotation or authority transfer approved long ago and never applied
  sits pending indefinitely. The outcome MUST be deterministic and MUST NOT allow a forgotten
  year-old approval to be executed unexpectedly.
- **Quorum becomes unreachable (accepted terminal risk)**: Enough signer keys are lost that the
  quorum can never again be met. Because the code is immutable (001 FR-018), the waiting period is
  unchangeable (FR-008), and the return to single-key authority is barred (FR-023), there is no
  fallback of any kind. Administrative capability is permanently gone: the treasury address is
  frozen forever, top-ups continue routing to it, and the system cannot be paused. Only deploying a
  replacement contract and migrating users helps. The system MUST reject any authority change that
  would knowingly produce an unsatisfiable arrangement, but it cannot prevent keys from being lost
  afterwards. This is the price of the three hardening choices and MUST be stated plainly in
  operator documentation.
- **Handover proposed to a wrong or unready multisig**: The primary key proposes a handover to an
  address that turns out to be wrong, or to a multisig not yet correctly configured. Because the
  handover waits two days and is cancellable (FR-023a), the mistake is recoverable — but only
  within that window. Once applied, an incorrect authority address is permanently in control and
  falls under the terminal risk above.
- **Signer set changes while a rotation is pending**: Approvals gathered under an old signer set
  must not silently satisfy a quorum under a new one, and the pending rotation must not gain or
  lose its waiting period as a result.
- **Rotation to a signer's own address**: Nothing structurally prevents a quorum from rotating the
  treasury to an address they personally control. This is an accepted governance risk, not a
  technical one; the two-day window and the public record are the mitigations.
- **Compromise of the single primary key before handover**: An attacker holding the primary key can
  propose a rotation to themselves, or an authority transfer to themselves. They cannot bypass the
  two days on either. If the organization retains the key it can cancel; if the attacker has
  exclusive control, the organization can pause top-ups but cannot cancel, and after two days the
  attacker controls the treasury destination permanently. Pausing stops money flowing but does not
  stop the rotation. This asymmetry MUST be explicitly documented as the defining risk of the
  single-key window, and is the reason that window should be closed as early as possible.
- **Simultaneous pause and rotation application**: A pause and a rotation landing in the same block
  must not produce a state where funds route somewhere inconsistent with the public record.
- **Repeated proposals as a denial-of-service**: A misbehaving signer repeatedly proposing and
  cancelling rotations must not be able to prevent a legitimate rotation from ever completing, nor
  cause unbounded cost.
- **Handover to an address that is not actually a multisig**: The system cannot verify that a
  destination authority is genuinely multi-signature. The organization can therefore hand authority
  to another single key, deliberately or by mistake. The system MUST make the current authority
  publicly visible so this is externally detectable, even though it cannot be prevented.

## Requirements *(mandatory)*

### Functional Requirements

**Treasury rotation authorization**

- **FR-001**: Changing the treasury destination MUST require approval from a multi-signature
  authority meeting a defined quorum. No single signer within that authority may complete a
  rotation alone.
- **FR-002**: The system MUST reject any rotation attempt from an account outside the current
  authority, and any attempt that has not met the required quorum.
- **FR-003**: The system MUST reject a rotation to an empty address and to the top-up contract's
  own address.
- **FR-004**: The system MUST NOT provide any path by which the treasury destination changes
  without satisfying the authority and the waiting period — including at deployment-time
  configuration of any bypass, emergency override, or privileged shortcut.

**The two-day waiting period**

- **FR-005**: An approved treasury rotation MUST NOT take effect until at least 2 days (48 hours)
  have elapsed since it was approved.
- **FR-006**: The system MUST publicly expose, for any pending rotation, the proposed destination
  and the exact time from which it may be applied, so that anyone can observe a rotation in
  progress without privileged access.
- **FR-007**: The waiting period MUST apply identically regardless of who holds administrative
  authority, including a single primary key. It MUST NOT be shortened, waived, or bypassed by any
  party under any circumstance.
- **FR-008**: The waiting period MUST be permanently fixed at 2 days and MUST NOT be changeable by
  any party — not lengthened, not shortened, not by any quorum, and **not by deployment
  configuration**. It MUST be a compile-time constant rather than a constructor parameter, so that
  every deployment of a given build has the identical period. The protection it provides cannot be
  removed or weakened by the same authority it constrains. Changing it requires deploying a new
  contract.
- **FR-008a**: Testnet and mainnet deployments MUST use identical bytecode with respect to the
  waiting period. Live testnet rehearsals therefore take the full 48 hours; automated tests
  simulate the passage of time and incur no such cost.
- **FR-009**: Applying a rotation MUST fail if attempted before the waiting period has fully
  elapsed, and MUST succeed from the moment of expiry onward, subject to FR-011.

**Cancellation**

- **FR-010**: The system MUST allow a pending rotation to be cancelled at any time before it is
  applied, and MUST produce a public record of the cancellation.
- **FR-011**: A cancelled rotation MUST NOT be applicable afterwards under any circumstance.
- **FR-012**: The system MUST NOT permit two pending rotations to exist such that either could be
  applied; proposing while one is pending MUST either be rejected or MUST replace the pending one
  with a fresh full waiting period.

**Changing the signing authority**

- **FR-013**: The system MUST allow the current administrative authority to transfer administrative
  authority to a different authority, without changing the contract's code.
- **FR-014**: After a transfer of authority, the previous authority MUST be unable to perform any
  administrative action.
- **FR-015**: The system MUST reject a transfer of authority to an empty address, and MUST reject
  any transfer that would leave the system with no party capable of administering it.
- **FR-016**: The system MUST produce a public record of every transfer of administrative
  authority, naming the previous and the new authority.
- **FR-017**: Transfer of administrative authority MUST be subject to the same 2-day waiting
  period as a treasury rotation, MUST be publicly visible while pending, and MUST be cancellable
  during that period. There MUST be no path by which administrative authority changes hands in
  less than 2 days, so that authority transfer cannot be used to bypass the delay protecting the
  treasury.
- **FR-018**: The current administrative authority MUST be publicly readable at all times.

**Initial single-key deployment**

- **FR-019**: The system MUST support deployment with a single primary key as the initial
  administrative authority, without requiring a multi-signature arrangement to exist at deployment
  time. For the testnet scope this is the *permanent* posture (Q2 → B): no live handover is
  performed, so the testnet deployment is expected to read `multisigEstablished == false`
  indefinitely.
- **FR-020**: A single-key authority MUST be subject to every constraint that binds a
  multi-signature authority, including the full two-day waiting period and public recording of all
  actions. The single-key posture reduces the number of approvals required; it grants no other
  privilege.
- **FR-021**: The system MUST allow the initial primary key to transfer administrative authority to
  a multi-signature arrangement, after which the primary key holds no authority.
- **FR-022**: The system MUST publicly expose whether administrative authority currently rests with
  a single key or a multi-signature arrangement, so that users and auditors can assess governance
  risk before topping up.
- **FR-023**: The system MUST NOT allow a return to single-key authority once a multi-signature
  authority has been established. The transition is one-way and permanent, so that observed
  multi-signature governance is a durable guarantee rather than a revocable claim.
- **FR-023a**: The initial handover from the primary key to a multi-signature authority MUST itself
  observe the full 2-day waiting period, and MUST be cancellable by the primary key during it.

**Separation of authority**

- **FR-024**: The authority to pause and resume top-ups MUST be separable from the authority to
  rotate the treasury, and MUST be satisfiable more easily, so that an urgent pause does not
  require a treasury-rotation quorum.
- **FR-025**: Pausing and resuming MUST take effect immediately with no waiting period.
- **FR-026**: A party holding only pause authority MUST be unable to propose, approve, apply, or
  cancel a treasury rotation, or to transfer administrative authority.
- **FR-027**: Pausing top-ups MUST NOT prevent a pending rotation from being applied or cancelled;
  governance MUST remain operable while top-ups are halted.

**Recording and observability**

- **FR-028**: The system MUST produce a public record of every governance action: proposal,
  approval, application, cancellation, transfer of authority, pause, and resume.
- **FR-029**: Governance records MUST be sufficient for an off-chain observer to reconstruct the
  complete history of who held authority and where the treasury pointed at any past moment.
- **FR-030**: The system MUST make it possible to detect a pending rotation automatically, so that
  the two-day window can be monitored rather than depending on someone happening to look.

**Preserved guarantees from feature 001**

- **FR-031**: Nothing in this feature may introduce any means for any party — signer, primary key
  holder, or administrator — to withdraw, refund, reclaim, or redirect funds already sent to the
  treasury. The no-withdrawal guarantee of 001 remains absolute.
- **FR-032**: Changing the treasury destination or the signing authority MUST NOT constitute or
  enable a change to the contract's code. Code immutability from 001 remains in force; only
  governance state is mutable.
- **FR-033**: Every attack scenario mandated by the project constitution MUST have an explicit
  failing-exploit test against these governance controls, including at minimum: rotation by a
  non-signer, rotation with a below-quorum approval set, application before the waiting period
  elapses, application of a cancelled rotation, replay of a stale approval, authority takeover by
  a single compromised signer, and any attempt to reach funds through a governance path.

### Key Entities

- **Administrative Authority**: The party currently permitted to govern the system. Initially a
  single primary key; subsequently a multi-signature arrangement. Publicly readable at all times.
- **Signer**: An individual key belonging to the multi-signature arrangement. Alone, a signer can
  do nothing to the treasury.
- **Quorum**: The number of signer approvals required for an action to be authorized.
- **Pending Rotation**: An approved but not-yet-effective change of treasury destination, carrying
  the proposed address and the time from which it may be applied. Cancellable until applied.
- **Waiting Period**: The fixed 2-day interval between approval and earliest possible effect,
  during which the change is publicly visible and cancellable.
- **Pauser**: The party holding the narrower, faster authority to halt and resume top-ups, and
  nothing more.
- **Governance Record**: The permanent public evidence of a governance action, sufficient to
  reconstruct authority and treasury history.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: No treasury rotation can take effect in less than 48 hours from its approval, under
  any authority configuration including a single primary key, demonstrated by tests at and around
  the exact boundary.
- **SC-002**: 100% of attempted treasury rotations by a non-signer, or by an approval set below
  quorum, fail with no state change.
- **SC-003**: A pending rotation is publicly detectable by an independent observer, with its
  destination and effective time, within one block of approval — no privileged access required.
- **SC-004**: An organization noticing an unauthorized pending rotation can halt all incoming
  top-ups immediately, in a single action, without waiting and without a treasury-rotation quorum.
- **SC-005**: After administrative authority is transferred, the previous authority succeeds at
  zero administrative actions, and no sequence of actions returns authority to a single key.
- **SC-005a**: No administrative authority transfer, including the initial handover from the
  primary key, takes effect in less than 48 hours, demonstrated by tests at the exact boundary.
- **SC-006**: Anyone can determine, from public data alone, whether the system is currently under
  single-key or multi-signature governance, and reconstruct the complete history of authority
  changes and treasury destinations with no gaps.
- **SC-007**: No governance action, in any sequence or combination, results in any party obtaining
  funds from the system — demonstrated by exhaustive review of every governance operation plus
  explicit extraction attempts from every role, all of which fail.
- **SC-008**: Every attack scenario in FR-033 has an explicit test that attempts the exploit and
  asserts it fails; governance code reaches at least 95% line and branch coverage, and stateful
  invariant testing confirms across randomized sequences that the treasury destination never
  changes without both a satisfied quorum and a fully elapsed waiting period.
- **SC-009**: The duration of the single-key window is measurable and reported, so the organization
  can hold itself accountable for closing it rather than leaving it open indefinitely. *Within the
  testnet scope this criterion is not exercised, since the window is deliberately never closed
  (Q2 → B); it becomes applicable to any production deployment.*
- **SC-010**: No party can cause any governance change to take effect in less than 48 hours by any
  route — rotation, authority transfer, or any combination — and no party can alter the waiting
  period, demonstrated by explicit tests attempting each bypass.

## Scope Boundary: Testnet Only

Established in Session 2026-09-04. This scope applies to feature 001 as well, since both specs
describe one contract.

**In scope**: Arc testnet (chain ID 5042002) deployment; the complete contract implementation; the
full automated test suite including every adversarial scenario the constitution mandates; static
analysis, coverage, and gas gates; source verification on the Arc testnet explorer.

**Out of scope, deferred rather than waived** — each re-activates if a production deployment is
proposed:

- **Independent external audit** (Q4 → A). Nothing on testnet holds third-party value, so the
  constitution's audit trigger is not met. The obligation attaches to the mainnet decision, not to
  this work.
- **Live handover rehearsal to a real multisig** (Q2 → B). Proven by automated tests against a
  mock; never executed live.
- **Arc mainnet parameters** — chain ID, RPC, and explorer remain unpublished
  (`TODO(ARC_MAINNET_PARAMS)` in the constitution) and are not needed for this scope.

**Explicitly NOT relaxed by the testnet scope**: the ≥95% line and branch coverage gate, the
complete `test/attack/` suite, invariant and symbolic testing, the fixed 2-day delay, and the
no-withdrawal guarantee. Testnet scope narrows *what gets deployed and rehearsed*, not how
correct the code must be — the code written here is intended to be the code that eventually
holds value, so weakening its verification would only defer the cost.

## Assumptions

- **Multi-signature arrangement**: The precise form — an external multi-signature wallet held as a
  single administrative address, or signer management built into the contract — is pending
  clarification (Q1). The requirements above are written to hold under either.
- **Waiting period**: Fixed at 2 days (48 hours) as explicitly requested. Interpreted as wall-clock
  time measured from approval, not a block count, since block production rates vary.
- **"The multisig can also be upgradable"**: Interpreted as the *signing authority* being
  changeable — signers, quorum, or the governing address may change over the deployment's life —
  and explicitly **not** as the contract's code becoming upgradeable. Feature 001's FR-018
  immutability decision (clarification Q3:C) stands: code frozen, governance mutable.
- **Testnet scope (Session 2026-09-04)**: Work is currently scoped to Arc testnet only. The
  deployed testnet contract stays under single-key authority permanently (Q2 → B), and the waiting
  period remains a hard 2-day constant identical to any future mainnet build (Q1 → A). Handover,
  multi-signature quorum behavior, and one-way latching are proven by automated tests against a
  mock multisig; they are not rehearsed live. Consequence accepted: the first live execution of the
  handover procedure would occur on a production deployment, having never been performed end to end
  against a real multisig.
- **Initial single-key deployment (Q3 → A)**: Accepted as an explicit, informed trade-off for
  launch practicality, specified as a transitional posture with a defined, one-way exit. During
  this window the two-day delay and the pause control are the only protections against a
  compromised primary key, and cancellation is unavailable if the attacker holds the key
  exclusively. Documented rather than mitigated, because the alternative — requiring a multisig at
  deployment — was explicitly declined.
- **Uniform delay (Q1 → A)**: Every governance change that could lead to the treasury — rotation
  and authority transfer alike — waits the same two days. This closes the bypass in which an
  attacker transfers authority to themselves instantly and then rotates. The cost is that
  legitimate urgent signer rotation, such as after a key loss, also waits two days; the pause
  control is the fast response in the interim.
- **Fixed delay (Q2 → A)**: The two days cannot be altered by anyone. If operational experience
  shows two days is the wrong figure, the remedy is a new deployment, not a governance action.
- **Combined consequence of Q1+Q2+Q3 and 001's immutability**: The system has deliberately no
  escape hatch. There is no emergency override, no delay reduction, no authority fallback, and no
  code patch. Every one of these was chosen for a good reason, and together they mean that
  operational error — losing quorum, handing authority to a wrong address — is unrecoverable on
  chain. Signer key custody and the correctness of the handover address therefore carry more weight
  in this design than in a conventionally governed contract.
- **Signer key custody**: Signers are assumed to hold their keys on separate hardware, under
  separate control. A multi-signature arrangement whose keys share custody provides the appearance
  of protection without the substance; this is an operational assumption the contract cannot
  enforce.
- **Monitoring**: The two-day window is only protective if someone is watching. An off-chain
  monitor alerting on pending rotations is assumed to exist operationally; it is out of scope for
  this contract, but FR-030 constrains the contract to make such monitoring possible.
- **Target chain**: Arc testnet, chain ID 5042002. Block timestamp behaviour on Arc is assumed to
  be within ordinary bounds; if Arc permits unusual timestamp drift, the waiting-period requirement
  must be re-examined against that behaviour. Arc's supported EVM version is **not** assumed: it is
  confirmed by probe deployment before any contract code is written (Q3 → A), and `evm_version` is
  then set deliberately rather than left at a toolchain default.
- **Pause authority holder**: Assumed to be a smaller, faster group than the rotation quorum — for
  instance a designated responder — chosen so that speed is achievable in an incident. The specific
  arrangement is an operational decision outside this specification.

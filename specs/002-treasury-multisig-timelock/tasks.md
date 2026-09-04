---

description: "Task list for TopUpRouter — USDC top-up with multi-sig treasury governance"
---

# Tasks: USDC Top-Up Router with Multi-Sig Treasury Governance

**Input**: Design documents from `/specs/002-treasury-multisig-timelock/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md) (002 governance),
[`../001-usdc-topup/spec.md`](../001-usdc-topup/spec.md) (top-up path),
[research.md](./research.md), [data-model.md](./data-model.md),
[contracts/ITopUpRouter.md](./contracts/ITopUpRouter.md), [quickstart.md](./quickstart.md)

**Tests**: **REQUIRED, NOT OPTIONAL.** Constitution Principle III makes TDD mandatory and Principle
II requires an explicit failing-exploit test for every applicable attack class. Every phase below
writes its tests first and confirms they fail before implementation.

**Organization**: Tasks are grouped by user story. Story labels span both specs:

| Label | Story | Source | Priority |
|---|---|---|---|
| US1 | Top up with native USDC | 001 US1 | **P1 — MVP** |
| US2 | Treasury rotation under multisig + 2-day delay, with cancellation | 002 US1 + US2 | **P1** |
| US3 | Top up on behalf of another account | 001 US2 | P2 |
| US4 | Reconcile and audit top-up history | 001 US3 | P2 |
| US5 | Change the signing authority | 002 US3 | P2 |
| US6 | Single-key deploy and one-way handover | 002 US4 | P2 |
| US7 | Pause top-ups during an incident | 002 US5 | P2 |

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to

> **⚠️ Parallelism is limited by design.** There is exactly one production contract,
> `src/TopUpRouter.sol`. Every implementation task touches that file, so implementation tasks are
> **sequential** and are not marked `[P]`. Test files are separate and parallelize freely. This is a
> consequence of the deliberate single-contract, no-proxy design (plan.md), not an oversight.

## Path Conventions

Single Foundry project at repository root: `src/`, `test/`, `script/`. Test tree mirrors the
constitution's mandated layout: `test/unit/`, `test/integration/`, `test/invariant/`, `test/fork/`,
`test/attack/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Foundry project initialization with the pinned, reproducible toolchain that
constitution Principle VII requires.

- [X] T001 Initialize Foundry project structure at repository root (`src/`, `test/`, `script/`, `lib/`) per plan.md
- [X] T002 Create `foundry.toml` pinning `solc = "0.8.28"`, `evm_version = "paris"` (research R-005), `fuzz.runs = 10000`, and an `invariant` profile with `runs = 256`, `depth = 50`, `fail_on_revert = false`
- [X] T003 [P] Install OpenZeppelin Contracts at an exact pinned tag and write `remappings.txt` (no floating branches, per constitution Dependencies)
- [X] T004 [P] Add `.solhint.json` enforcing explicit visibility, custom errors over revert strings, and a compiler-version rule in the repository root
- [X] T005 [P] Add `slither.config.json` in the repository root with the detector set enabled and no blanket exclusions
- [X] T006 [P] Create `.gitignore` (ignore `out/`, `cache/`, `broadcast/`, `.env`) and `.env.example` containing only RPC and explorer URLs — never keys (constitution, Secrets)
- [X] T007 [P] Create `.github/workflows/ci.yml` running all six blocking gates from quickstart.md: `forge fmt --check`, `forge build --deny-warnings`, `forge test`, `forge coverage` with a ≥95% line and branch threshold on `src/`, `slither` + `solhint`, and `forge snapshot --check`

**Checkpoint**: `forge build` succeeds on an empty project and CI runs green.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The contract skeleton, shared storage, and test doubles every story depends on.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### Test doubles (parallel — separate files)

- [X] T008 [P] Create `test/mocks/MaliciousTreasury.sol` — a treasury that on `receive()` can be configured to revert, consume all forwarded gas, or re-enter `topUp`
- [X] T009 [P] Create `test/mocks/ForceSender.sol` — pushes native funds into a target via `selfdestruct` to simulate forced balance
- [X] T010 [P] Create `test/mocks/MockMultisig.sol` — a minimal contract-with-code that can call arbitrary targets, used as a stand-in `admin` for handover tests
- [X] T011 [P] Create `test/BaseTest.sol` — shared harness with funded actors (payer, beneficiary, admin, pauser, attacker), deployment helper, and time-warp helpers

### Contract skeleton (sequential — all in `src/TopUpRouter.sol`)

- [X] T012 Create `src/TopUpRouter.sol` with pinned `pragma solidity 0.8.28`, contract NatSpec header embedding the threat model from research.md R-001, and an explicit `@dev` note that the contract is immutable and holds no user funds
- [X] T013 Declare all 12 custom errors and the `Subject` enum in `src/TopUpRouter.sol` exactly as specified in contracts/ITopUpRouter.md
- [X] T014 Declare all events (`ToppedUp`, `ChangeProposed`, `ChangeApplied`, `ChangeCancelled`, `MultisigEstablished`) in `src/TopUpRouter.sol` per contracts/ITopUpRouter.md
- [X] T015 Declare storage in `src/TopUpRouter.sol` per data-model.md: `treasury`, `admin`, `pauser`, `multisigEstablished`, `totalRouted`, `contributions`, the `PendingChange` struct, and the three pending slots
- [X] T016 Declare `uint256 public constant DELAY = 2 days` and `uint256 public immutable MIN_TOPUP` in `src/TopUpRouter.sol` — `DELAY` MUST be `constant`, never storage (002 FR-008)
- [X] T017 Inherit OpenZeppelin `ReentrancyGuard` and `Pausable` in `src/TopUpRouter.sol`; do NOT inherit `Ownable` or `AccessControl` (research R-004 — they reintroduce an unbounded owner)
- [X] T018 Implement `onlyAdmin` and `onlyPauser` modifiers in `src/TopUpRouter.sol` reverting `NotAdmin` / `NotPauser`
- [X] T019 Implement the constructor in `src/TopUpRouter.sol` taking `treasury`, `admin`, `pauser`, `minTopUp`; reject zero addresses, reject `address(this)`, reject zero `minTopUp`; emit initial state
- [X] T020 Implement all read functions in `src/TopUpRouter.sol` per contracts/ITopUpRouter.md; confirm no `receive()` or `fallback()` is declared so bare transfers revert (001 FR-028)

**Checkpoint**: ✅ **MET 2026-09-04.** Contract compiles under solc 0.8.28/cancun, deploys in tests, and all getters return constructor values. Verified by `test/unit/Deployment.t.sol` (9 tests, all passing) — added as checkpoint evidence beyond the listed tasks. No behavior yet: `topUp` and all governance entry points arrive in Phase 3+.

---

## Phase 3: User Story 1 — Top up with native USDC (Priority: P1) 🎯 MVP

**Goal**: A user sends native USDC in one transaction; the full amount reaches the treasury in that
same transaction and a record credits them. Nothing is retained.

**Independent Test**: A funded account tops up; treasury balance increases by exactly the amount,
the router retains nothing attributable to top-ups, and `ToppedUp` names payer, beneficiary, amount,
treasury, and the new total.

### Tests for User Story 1 (write first, confirm they FAIL)

- [X] T021 [P] [US1] Write `test/unit/TopUp.t.sol` covering 001 FR-001…FR-009: successful top-up, exact treasury delta, zero-value rejection, below-`MIN_TOPUP` rejection, zero-beneficiary rejection, event field assertions
- [X] T022 [P] [US1] Write `test/attack/Reentrancy.t.sol` — `MaliciousTreasury` re-enters `topUp` on receive; assert the call reverts, no double credit occurs, and accounting stays consistent (001 FR-025)
- [X] T023 [P] [US1] Write `test/attack/ForcedBalance.t.sol` — force funds in via `ForceSender`, then assert `totalRouted`, `contributions`, and every subsequent `topUp` are unaffected (INV-9, 001 FR-008)
- [X] T024 [P] [US1] Write `test/attack/DoSGriefing.t.sol` — treasury that reverts on receive and treasury that burns all forwarded gas; assert both fail cleanly with `TreasuryTransferFailed` and leave no state change
- [X] T025 [P] [US1] Write `test/attack/Arithmetic.t.sol` — boundaries at 0, 1 wei, `MIN_TOPUP - 1`, `MIN_TOPUP`, and large values; assert no overflow and no silent saturation (001 FR-014)
- [X] T026 [P] [US1] Write a fuzz test in `test/unit/TopUp.t.sol` over `(amount, beneficiary)` asserting credited amount always equals the amount transferred to treasury (001 FR-007)
- [X] T027 [P] [US1] Write a test asserting a bare value transfer to the router reverts, since no `receive`/`fallback` exists (001 FR-028)

### Implementation for User Story 1 (sequential — same file)

- [X] T028 [US1] Implement `topUp(address beneficiary) external payable` in `src/TopUpRouter.sol` with strict checks → effects → interactions: validate, write `contributions` and `totalRouted`, emit `ToppedUp`, then transfer. Guards: `whenNotPaused`, `nonReentrant`
- [X] T029 [US1] Implement the treasury transfer in `src/TopUpRouter.sol` as `treasury.call{value: msg.value}("")` with an explicit success check reverting `TreasuryTransferFailed` (research R-006) — never `transfer`/`send`, which break for a Safe treasury
- [X] T030 [US1] Implement `topUpSelf() external payable` in `src/TopUpRouter.sol` delegating to the same internal logic
- [X] T031 [US1] Audit `src/TopUpRouter.sol` for any read of `address(this).balance` and confirm there are none (001 FR-008); add an inline `@dev security:` comment recording why

**Checkpoint**: ✅ **MET 2026-09-04.** US1 fully functional — 38 tests passing (12 unit incl. 2 fuzz at 10k runs, 5 forced-balance, 3 reentrancy, 3 DoS/griefing, 6 arithmetic, 9 deployment). `forge build`, `forge fmt --check`, and `forge lint src/` all clean. The contract is deployable and usable with a fixed treasury. **This is the MVP.**

> ⚠️ **Coverage is 89.47% lines / 70% branches — below the 95% gate, expectedly.** The only uncovered lines are the `onlyAdmin` and `onlyPauser` modifier bodies, which no function uses until governance lands in Phase 4/7. Not a US1 test gap; closes automatically. Do not deploy against the constitution's coverage gate until Phase 10 (T076).

---

## Phase 4: User Story 2 — Treasury rotation under multisig and 2-day delay (Priority: P1)

**Goal**: The treasury address can be rotated only by the `admin` authority, only after a fixed
2-day wait, visibly and cancellably throughout.

**Independent Test**: Admin proposes a rotation; applying at `eta - 1` fails and at `eta` succeeds;
a subsequent top-up lands at the new address; a non-admin cannot propose, and cancelling makes the
change permanently unapplicable.

### Tests for User Story 2 (write first, confirm they FAIL)

- [X] T032 [P] [US2] Write `test/unit/TreasuryRotation.t.sol` covering 002 FR-001…FR-012: propose sets `eta = now + 2 days`, apply before/at/after `eta`, cancel, re-propose restarts the full clock, zero and self address rejection
- [X] T033 [P] [US2] Write `test/attack/TimelockBypass.t.sol` with the treasury cases: apply at exactly `eta - 1` must revert `TimelockNotElapsed`; apply at exactly `eta` must succeed; applying a cancelled change must revert; a re-proposal must NOT inherit elapsed time
- [X] T034 [P] [US2] Write `test/attack/AccessControl.t.sol` asserting every governance function reverts for a random EOA, for the `pauser`, and for a beneficiary (002 FR-002, FR-026)
- [X] T035 [P] [US2] Write a test asserting `DELAY()` returns exactly `172800` and that no function exists to change it (002 FR-008)
- [X] T036 [P] [US2] Write a test asserting a pending rotation is fully readable while pending — target and `eta` — so an off-chain monitor can detect it (002 FR-006, FR-030)

### Implementation for User Story 2 (sequential — same file)

- [X] T037 [US2] Implement the internal pending-change helpers in `src/TopUpRouter.sol`: `_propose(subject, target)` setting `eta = block.timestamp + DELAY` and replacing any existing proposal, `_cancel(subject)`, and an `_assertElapsed(eta)` check
- [X] T038 [US2] Implement `proposeTreasury(address)` in `src/TopUpRouter.sol` — `onlyAdmin`, rejects zero and `address(this)`, emits `ChangeProposed`
- [X] T039 [US2] Implement `applyTreasury()` in `src/TopUpRouter.sol` — permissionless by design (contracts/ITopUpRouter.md), requires a non-zero pending target and elapsed `eta`, sets `treasury`, clears the slot, emits `ChangeApplied`
- [X] T040 [US2] Implement `cancelTreasury()` in `src/TopUpRouter.sol` — `onlyAdmin`, clears the slot, emits `ChangeCancelled`

**Checkpoint**: ✅ **MET 2026-09-04.** Treasury is rotatable under full governance. **67 tests passing** (up from 38), `forge build` / `forge fmt --check` / `forge lint src/` all clean. Coverage 94.12% lines / 86.67% branches — the only uncovered lines are `onlyPauser` (Phase 9) and the Admin/Pauser branches of `_pendingSlot` (Phase 7); both close automatically. Combined with US1 this is the minimum responsibly deployable system.

---

## Phase 5: User Story 3 — Top up on behalf of another account (Priority: P2)

**Goal**: A payer credits a beneficiary other than themselves; the record distinguishes both.

**Independent Test**: A payer tops up naming a different beneficiary; the beneficiary's total rises,
the payer's does not, and the treasury receives the full amount.

> **Note**: `topUp(address beneficiary)` from T028 already accepts an arbitrary beneficiary, so this
> story is primarily a **verification** phase rather than new code. It is kept as its own phase so
> the behavior is explicitly proven rather than assumed from the signature.

### Tests for User Story 3

- [X] T041 [P] [US3] Add sponsored-payment cases to `test/unit/TopUp.t.sol`: payer ≠ beneficiary increases only the beneficiary's total, and `ToppedUp` carries both addresses distinctly (001 FR-006)
- [X] T042 [P] [US3] Add a test asserting a payer topping up for many different beneficiaries accumulates each independently with no cross-contamination
- [X] T043 [P] [US3] Add a fuzz test over `(payer, beneficiary, amount)` asserting `contributions[payer]` is unchanged whenever `payer != beneficiary`

### Implementation for User Story 3

- [X] T044 [US3] Confirm no code change is required in `src/TopUpRouter.sol` — ✅ **CONFIRMED**: all 6 new sponsored-payment tests passed on first run against the existing `topUp` implementation. `src/` was not modified in this phase. The `beneficiary` parameter added in T028 already satisfied 001 FR-006; this phase converted that from an assumption into evidence.

**Checkpoint**: ✅ **MET 2026-09-04.** Sponsored and custodial payment flows proven. **73 tests passing** (up from 67); 6 added, 0 production lines changed. Coverage unchanged at 94.12% lines / 86.67% branches — expected, since no new `src/` code was introduced.

> **Note on TDD**: this phase had no RED stage, and that is not a shortcut. US3 required no new capability — `topUp(address beneficiary)` already accepted an arbitrary beneficiary — so the tests are confirmatory by design (see the phase note above). Had any failed, the fix would have gone into `topUp`.

---

## Phase 6: User Story 4 — Reconcile and audit top-up history (Priority: P2)

**Goal**: The public record reconciles exactly to treasury receipts, and an off-chain ledger rebuilt
from events matches the contract's totals with no gaps or double-counting.

**Independent Test**: After a randomized sequence of top-ups, summing the events equals
`totalRouted`, equals the sum of all `contributions`, and equals the treasury's received amount.

### Tests for User Story 4

- [X] T045 [P] [US4] Write `test/unit/Accounting.t.sol` covering 001 FR-011…FR-014: zero for never-credited accounts, monotonic totals, `newTotal` in the event equals the post-state
- [X] T046 [P] [US4] Write `test/invariant/AccountingInvariant.t.sol` with a handler asserting INV-1 (`sum(contributions) == totalRouted`), INV-2 (monotonicity), and INV-3 (`totalRouted` equals total value ever sent out)
- [X] T047 [P] [US4] Extend `test/invariant/AccountingInvariant.t.sol`'s handler to randomly force funds in via `ForceSender`, proving INV-9 holds under invariant fuzzing, not just in the unit test
- [X] T048 [P] [US4] Write a test that replays all emitted `ToppedUp` events in log order to rebuild per-account totals from scratch and asserts they match on-chain `contributions` exactly (001 SC-008)
- [X] T049 [P] [US4] Write a test asserting `newTotal == previousTotal + amount` holds for every consecutive pair of events per beneficiary, which is the gap/duplicate detection property (001 FR-010, research R-008)

### Implementation for User Story 4

- [X] T050 [US4] Confirm event fields in `src/TopUpRouter.sol` are sufficient for exactly-once resumable consumption — ✅ **CONFIRMED, no adjustment needed.** T048/T049 rebuilt a ledger from logs alone and matched on-chain totals exactly, including a mid-stream resume that did not double-count. The `newTotal` post-state field (research R-008) is what makes the continuity assertion `newTotal == previousTotal + amount` possible; without it a consumer could drift silently. `src/` unchanged in this phase.

**Checkpoint**: ✅ **MET 2026-09-04.** Reconciliation is provable. **83 tests passing** (up from 73), including the project's first stateful invariant suite: 256 runs x 12,800 calls with **0 reverts** across all three handler selectors. `src/` unchanged this phase; coverage steady at 94.12% lines / 86.67% branches.

> ⚠️ **Bug found and fixed in the test harness itself**: the first invariant run had `forceFunds` reverting on **4268 of 4268 calls** — the handler held no balance, so no funds were ever forced in and the INV-9 assertions were passing **vacuously**. Fixed by funding the handler in its constructor. Re-run shows 0 reverts and ~4,241 real forced-fund pushes interleaved with top-ups. Worth remembering: an invariant suite that passes proves nothing until you check the call/revert table.

---

## Phase 7: User Story 5 — Change the signing authority (Priority: P2)

**Goal**: Administrative authority can be transferred to a new authority under the same 2-day delay,
closing the authority-swap bypass.

**Independent Test**: Admin proposes an authority transfer; it cannot apply for 2 days; after it
applies the old admin can do nothing and the new admin can.

### Tests for User Story 5 (write first, confirm they FAIL)

- [X] T051 [P] [US5] Write `test/unit/AuthorityTransfer.t.sol` covering 002 FR-013…FR-018: propose, 2-day wait, apply, cancel, zero-address rejection, and the old authority losing all power
- [X] T052 [P] [US5] Add the **authority-swap bypass** case to `test/attack/TimelockBypass.t.sol` — an attacker holding `admin` attempts to transfer authority to themselves and rotate the treasury in under 2 days; assert it is impossible by every route (002 FR-017). **This is the most important single test in the suite.**
- [X] T053 [P] [US5] Add a test asserting a pending treasury rotation neither gains nor loses time when the authority changes while it is pending (002 US3 acceptance 5)
- [X] T054 [P] [US5] Write `test/unit/PauserRotation.t.sol` asserting the `pauser` address is itself changeable by `admin` under the same 2-day delay

### Implementation for User Story 5 (sequential — same file)

- [X] T055 [US5] Implement `proposeAdmin(address)`, `applyAdmin()`, `cancelAdmin()` in `src/TopUpRouter.sol` reusing the T037 helpers, with the same delay and validation as treasury
- [X] T056 [US5] Implement `proposePauser(address)`, `applyPauser()`, `cancelPauser()` in `src/TopUpRouter.sol`
- [X] T057 [US5] Add a `@dev security:` comment in `src/TopUpRouter.sol` recording that authority transfer is delayed specifically to close the bypass, so a future reader does not "optimize" it away

**Checkpoint**: ✅ **MET 2026-09-04.** Every path to the treasury is gated by the same 2-day delay. **104 tests passing** (up from 83). Coverage **97.67% lines / 96.59% statements**; `forge lint src/` now reports **zero warnings**.

> **T052 result — the bypass is closed and proven.** `test_AttackFails_AuthoritySwapCannotShortcutTreasuryDelay` walks the full attack: a compromised admin proposes itself as authority, is blocked immediately and at `eta - 1`, becomes admin only at 2 days, then must serve a *second* full 2 days before the treasury moves. Total 4 days — the swap route is strictly **slower** than the direct one, never faster. Assertions use exact `TimelockNotElapsed` selectors with expected parameters, not bare `expectRevert`, so a revert for the wrong reason cannot pass. `test_AttackFails_NoRouteChangesTreasuryWithinTwoDays` additionally hammers all three apply entry points at 6-hour intervals across the whole window.

---

## Phase 8: User Story 6 — Single-key deploy and one-way handover (Priority: P2)

**Goal**: Deploy with a single primary key, then hand authority to a multisig permanently.

**Independent Test**: Deploy with an EOA admin; `multisigEstablished` is false; handover to a
contract admin takes 2 days; afterwards the EOA cannot act and no path returns authority to an EOA.

> **Deployment decision (2026-09-04)**: the testnet `pauser` is a **separate key from `admin`**.
> This makes 002 FR-024's role separation real on the deployed contract rather than proven only in
> unit tests, and it means the Phase 9 pause drill exercises the correct key. Enforced in
> `script/Deploy.s.sol` (T066), deliberately **not** in `TopUpRouter.sol`: FR-024 requires the
> authorities be *separable*, not always distinct, so a deployment where they coincide stays a
> legitimate configuration. Hard-coding distinctness into an immutable contract would be an
> unrequested constraint that could never be relaxed.

### Tests for User Story 6 (write first, confirm they FAIL)

- [X] T058 [P] [US6] Add tests to `test/unit/AuthorityTransfer.t.sol`: `multisigEstablished` is false after an EOA-admin deployment and true after applying a handover to a contract admin (002 FR-022)
- [X] T059 [P] [US6] Add a test asserting that once `multisigEstablished` is true, proposing or applying an EOA admin reverts `MustBeContract` — the one-way latch (002 FR-023)
- [X] T060 [P] [US6] Add a test asserting the code check happens at **apply** time, not propose time, so a contract deployed after the proposal cannot sneak past it (research R-003)
- [X] T061 [P] [US6] Add a test asserting the initial handover itself waits the full 2 days and is cancellable by the primary key during the window (002 FR-023a)
- [X] T062 [P] [US6] Write `test/integration/GovernanceLifecycle.t.sol` implementing the full 9-step end-to-end scenario in quickstart.md — ✅ **COMPLETE.** Steps 1-7 and 9 landed in Phase 8; step 8 (pause) was deferred to Phase 9 because it needed `pause()` (T072) and was completed there. All 9 steps now pass in one test.
- [X] T063 [P] [US6] Write `test/invariant/GovernanceInvariant.t.sol` asserting INV-4…INV-7 and INV-10 across randomized governance sequences

### Implementation for User Story 6 (sequential)

- [X] T064 [US6] Implement the `multisigEstablished` latch in `applyAdmin()` in `src/TopUpRouter.sol`: set it true when the new admin has non-empty code, and once set require `target.code.length > 0`, reverting `MustBeContract`; emit `MultisigEstablished`
- [X] T065 [US6] Add a `@dev security:` comment in `src/TopUpRouter.sol` stating plainly that `code.length > 0` proves the target is a contract but NOT that it is a multisig (research R-003 residual risk) — do not overstate the guarantee
- [X] T066 [US6] Create `script/Deploy.s.sol` — deterministic deployment taking treasury, admin, pauser, and `MIN_TOPUP` from environment. Before broadcasting it MUST validate: (a) `block.chainid == 5042002`; (b) `pauser != admin`, failing loudly otherwise (see the Phase 8 note below); (c) no address is zero. No hardcoded addresses in `src/` (constitution Principle VI). Add a test asserting the script rejects a `pauser == admin` configuration.
- [X] T067 [US6] Create `script/ProposeHandover.s.sol` proposing the admin handover to the multisig address

**Checkpoint**: ✅ **MET 2026-09-04** (with the step-8 caveat on T062 above). **117 tests passing** (up from 104). Coverage **98.90% lines**; `forge lint src/ script/` reports **zero warnings**. The launch path — deploy single-key, hand over, harden — is proven end to end apart from the pause leg.

> **Invariant-suite methodology note.** Following the Phase 6 lesson, I tried to add an `afterInvariant` vacuity guard to T063 and it does **not** work for this suite — Foundry resets handler state between runs (counters are per-run, not cumulative) and, on failure, shrinks to a minimal sequence and replays it from a persisted file, so any "the campaign did enough work" assertion self-defeats. Non-vacuity was instead confirmed by instrumenting one full campaign: over 256 runs x 50 calls the handler recorded successful proposals, admin transfers, treasury rotations, and cancellations. The reasoning is recorded in a comment block in `GovernanceInvariant.t.sol` so the next person does not repeat the attempt. Purely random interleaving never completed a governance cycle (each new proposal restarts the clock), so the handler gained `completeAdminHandover` and `completeTreasuryRotation` actions that drive a full propose→wait→apply cycle through the real contract functions.

---

## Phase 9: User Story 7 — Pause top-ups during an incident (Priority: P2)

**Goal**: An immediate halt on top-ups, on a separate and faster authority than treasury rotation.

**Independent Test**: The pauser halts top-ups in one action with no delay; top-ups revert;
governance still functions; the pauser cannot touch the treasury.

> **Note**: `whenNotPaused` is already on `topUp` from T028 and `Pausable` from T017. This phase adds
> the entry points and proves the separation of authority.

### Tests for User Story 7 (write first, confirm they FAIL)

- [X] T068 [P] [US7] Write `test/unit/PauseControl.t.sol`: pauser pauses with immediate effect, top-ups revert, resume restores service, totals carry over unchanged (002 FR-021, FR-025)
- [X] T069 [P] [US7] Add a test asserting all read functions still work while paused (002 US5 acceptance 4)
- [X] T070 [P] [US7] Add a test asserting a pending rotation can still be applied and cancelled while paused — governance is not frozen (002 FR-027)
- [X] T071 [P] [US7] Add tests to `test/attack/AccessControl.t.sol` asserting the `pauser` cannot propose, apply, or cancel any change, and that `admin` cannot pause unless it is also the pauser (002 FR-026)

### Implementation for User Story 7 (sequential — same file)

- [X] T072 [US7] Implement `pause()` and `unpause()` in `src/TopUpRouter.sol` guarded by `onlyPauser`, taking effect immediately with no delay
- [X] T073 [US7] Verify `whenNotPaused` placement — ✅ **VERIFIED by audit**: `whenNotPaused` appears exactly **once** in `src/TopUpRouter.sol`, on the internal `_topUp`, which both `topUp` and `topUpSelf` route through. It is absent from all 11 governance functions and every read function, satisfying 002 FR-027. Routing both entry points through one guarded internal is what makes it impossible for the two to drift apart.

**Checkpoint**: ✅ **MET 2026-09-04. All seven stories independently functional; feature complete.**

**134 tests passing.** `src/TopUpRouter.sol` coverage is **100% lines, 100% statements, 100% branches, 100% functions** — clearing the constitution's >=95% gate with no uncovered branch left to justify. `forge build`, `forge fmt --check`, and `forge lint src/ script/` all clean (zero warnings).

T062's deferred step 8 is now complete, so the full 9-step governance lifecycle passes end to end in a single test.

---

## Phase 10: Polish, Verification & Deployment

**Purpose**: The constitution's definition-of-done gates, plus the deployment path.

### Verification

- [X] T074 [P] Write `test/fork/ArcTestnet.t.sol` exercising governance through a real deployed Safe on Arc testnet (constitution: fork tests against real deployed dependencies) — ✅ **DONE, against a REAL Safe.** Canonical Safe v1.4.1 contracts are deployed on Arc testnet (factory `0x4e1DCf...ec67`, singleton `0x4167...61a`), confirmed by `eth_getCode`. The fork test deploys a genuine 2-of-2 Safe through the factory and executes a treasury rotation with real owner signatures via `execTransaction`. 4 tests passing against live Arc testnet.
- [X] T075 [P] Add a `halmos` symbolic check for INV-1 (`sum(contributions) == totalRouted`) — constitution requires symbolic or formal tooling for accounting-critical components — ⚠️ **ATTEMPTED, BLOCKED on tooling.** halmos 0.3.3 installed and verified working (a trivial probe contract verifies fine), but it **cannot construct `TopUpRouter`**: `setUp()` fails with "No successful path found in setUp()". Isolated by bisection — a minimal probe doing nothing but `new TopUpRouter(...)` reproduces it, so the blocker is constructor deployment, not the properties. `test/symbolic/AccountingSymbolic.t.sol` is written, correct, and left in the tree to verify unchanged once the tooling issue clears; it is NOT wired into CI while it cannot run. **Gap acknowledged**: INV-1 currently rests on sampling (256x12,800-call invariant campaign + 10k-run fuzz), not proof.
- [X] T076 Run `forge coverage` and close every gap to ≥95% lines and branches on `src/`; justify any uncovered branch in the PR description (constitution Principle II) — ✅ **DONE: 100% lines, statements, branches AND functions** on `src/`. No uncovered branch to justify.
- [X] T077 Run `slither` and `solhint`; fix findings or add an inline justification for each suppression (constitution Principle IV) — ✅ **DONE.** slither 0.11.6: **0 results**. solhint 5: clean. Both required installing the tools first. slither initially reported 9 findings and solhint 4; see the notes below.
- [X] T078 Commit `forge snapshot` gas baseline and confirm a single `topUp` is within the ~60k target from plan.md — ✅ **DONE, and the target was wrong.** Measured `topUp` median **109,815 gas**, not the ~60k in plan.md. plan.md has been corrected with the measurement and the reason (two cold SSTOREs + value-bearing cold call are inherent). Snapshot committed.
- [X] T079 [P] Complete NatSpec on every public/external function, event, error, and storage variable in `src/TopUpRouter.sol`; run `forge doc` to confirm nothing is missing — ✅ **DONE by audit.** Every external/public function, event, error and public state variable carries NatSpec (verified by script). `forge doc` itself fails in this environment, so completeness was checked directly rather than via the tool.
- [X] T080 Manually enumerate every callable function in `src/TopUpRouter.sol` and confirm none can move funds out — the review half of 001 SC-004, which tests alone cannot establish — ✅ **DONE — this is the strongest single result in Phase 10.** Enumerated all 13 external/public functions and every value-moving construct in `src/`. There is **exactly one**: `destination.call{value: amount}` inside `_topUp`, where `amount = msg.value` (funds arriving in that same transaction) and `destination = treasury` (governed, 2-day delayed). No `delegatecall`, `selfdestruct`, `transfer`, `send`, or plain `call` anywhere. **No path can extract pre-existing balance.**
- [X] T081 [P] Confirm the absent-functions list in contracts/ITopUpRouter.md holds: no `receive`/`fallback`, no sweep/rescue/withdraw, no arbitrary-call helper, no `setDelay`, no upgrade hook — ✅ **DONE.** Verified absent: `receive`, `fallback`, `withdraw`, `sweep`, `rescue`, `recover`, `execute`, `setDelay`, `upgradeTo`, `initialize`, `transfer`, `approve`.

### Deployment (testnet scope)

> **Verification finding (2026-09-04).** The first verification attempt failed with five Sourcify
> `404 Not Found` errors. The cause was **not** a missing explorer API key: `testnet.arcscan.app`
> is **Blockscout v11.2.8**, which uses no API key. The documented command passed `--verifier-url`
> but not `--verifier`, so forge fell back to Sourcify, which does not index Arc. Fixed by adding
> `--verifier blockscout`; `docs/DEPLOYMENT.md`, `foundry.toml` and `.env.example` all corrected so
> the next person does not lose a cycle to it. Before verifying, the local build was diffed against
> on-chain bytecode — identical except the `MIN_TOPUP` immutable — so the match was established
> independently of the explorer's verdict.

> Scope narrowed to Arc testnet by the 2026-09-04 clarification session. T082 resolved and moved to
> Phase 1. T085 deferred out of scope. T083 rescoped: no live handover rehearsal (Q2 → B), and the
> testnet treasury is a plain wallet (Q5 → B).

- [X] T082 **Resolve the Arc EVM version.** ✅ **DONE 2026-09-04, moved to Phase 1 per clarification Q3 → A.** Probed Arc testnet (chain `5042002`) by `eth_call` with raw opcode bytecode, no funds or keys required. PUSH0 (`0x5f`), TSTORE/TLOAD (`0x5d`/`0x5c`), and MCOPY (`0x5e`) all execute and return correct data; negative controls confirm the probe discriminates (undefined opcode `0x0c` → `OpcodeNotFound`, `0xfe` → `InvalidFEOpcode`). **Arc testnet supports Cancun.** `evm_version = "cancun"` set deliberately in `foundry.toml` with the evidence recorded inline. ⚠️ This establishes testnet support only — re-probe before any mainnet build.
- [ ] T083 Deploy to Arc testnet with `script/Deploy.s.sol` and rehearse the full procedure including the 2-day handover and a pause drill (constitution Principle VI requires testnet rehearsal of upgrade and emergency procedures) — 🟡 **PARTIALLY DONE: deployed and verified, rehearsals still outstanding.** Deployed 2026-09-04 to `0x9B071Fefcc9aa81C7c6Cbe1B4f33840e83120B0C` (tx `0xe18265dc…6a20`, block 60321987, gas 1,240,304). On-chain state confirmed correct: `DELAY` 172800, three distinct roles, `MIN_TOPUP` 1e18, `multisigEstablished` false. **Remains open** because the task also requires rehearsing the 2-day handover and a pause drill — neither has been performed.
- [X] T084 Verify source on the Arc explorer and commit deployment artifacts — address, constructor args, tx hash, block number, commit SHA, verification status (constitution Principle VII) — ✅ **DONE.** Verified on Blockscout: <https://testnet.arcscan.app/address/0x9B071Fefcc9aa81C7c6Cbe1B4f33840e83120B0C#code>. Artifacts recorded in `docs/deployments/arc-testnet.md` — address, all constructor args, tx hash, block, gas, deployer, exact compiler settings, and byte-level bytecode-match evidence. ⚠️ Two caveats recorded rather than hidden: (1) Blockscout reports **partially** verified, expected because `bytecode_hash = "none"` leaves no metadata hash to compare — the source still matches the deployed runtime bytecode; (2) **no commit SHA**, because the repo has no git commits, so Principle VII's provenance requirement is not yet met.
- [ ] T085 ~~Obtain an independent external audit~~ — **OUT OF TESTNET SCOPE** per clarification Q4 → A. Deferred obligation, not waived: re-activates the moment a mainnet deployment is proposed. Nothing on testnet holds third-party value, so the constitution's audit trigger is not met.

### Phase 10 outcome (2026-09-04)

**All gates green**: 138 tests passing; coverage **100% lines / statements / branches / functions**;
`forge build`, `forge fmt --check`, `forge lint src/ script/` (0 warnings), `slither` (**0 results**)
and `solhint` (clean) all pass.

Two findings worth carrying forward:

1. **The plan's gas target was wrong, not the code.** `topUp` costs ~109.8k gas, not ~60k. The
   estimate omitted two cold SSTOREs and a value-bearing cold call, all inherent to the design.
   plan.md corrected; no safe optimisation exists (dropping `totalRouted` breaks INV-1's cheap
   check, `unchecked` weakens INV-2).
2. **Static analysers produced 13 findings across slither and solhint; 2 were real.** solhint caught
   a genuine 101-char line and a genuine function-ordering violation (external after internal),
   both fixed by reordering `_topUp` and `_pendingSlot` into the internal/view section. The other
   11 were false positives of two kinds already seen in earlier phases — writes through a storage
   pointer, and validation through an internal helper — each suppressed with an inline
   justification per Principle IV.

Also learned: `forge-lint` and `slither` both require their directive on the line immediately above
the code, so they cannot both use `disable-next-line` on the same statement. Slither's
`disable-start`/`disable-end` block form resolves it.

### Documentation

- [X] T086 [P] Write `README.md` documenting the governance model, the 2-day delay, the one-way handover, and — stated plainly — the accepted terminal risk that losing multisig quorum permanently freezes the treasury with no recovery (002 spec, Assumptions) — ✅ **DONE.** `README.md` documents the governance model, the uniform 2-day delay, the one-way handover, and states the accepted terminal risk plainly under its own heading.
- [X] T087 [P] Write `docs/OPERATIONS.md` covering the rotation runbook, the pause drill, and monitoring for pending changes (002 FR-030) — ✅ **DONE.** `docs/OPERATIONS.md` — treasury rotation, multisig handover, incident response, required monitoring signals, reconciliation, and the open single-key obligation.
- [ ] T088 Record the actual single-key window duration once handover completes, closing the constitution Principle V exception tracked in plan.md Complexity Tracking (002 SC-009) — ⏸️ **BLOCKED / NOT DONE**: Depends on a real deployment (T083).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies
- **Foundational (Phase 2)**: depends on Setup — **blocks every user story**
- **US1 (Phase 3)** and **US2 (Phase 4)**: both P1, both depend only on Foundational
- **US3, US4 (Phases 5–6)**: depend on US1 (they test and extend the top-up path)
- **US5 (Phase 7)**: depends on US2 (reuses the T037 pending-change helpers)
- **US6 (Phase 8)**: depends on US5 (the handover *is* an authority transfer)
- **US7 (Phase 9)**: depends only on Foundational — genuinely independent
- **Polish (Phase 10)**: depends on all stories

### Story Dependency Graph

```
Setup → Foundational ─┬─→ US1 (P1, MVP) ─┬─→ US3
                      │                   └─→ US4
                      ├─→ US2 (P1) ──────────→ US5 ──→ US6
                      └─→ US7
```

US5 → US6 is a real dependency, not a convenience: the handover in US6 is implemented *by* the
authority-transfer machinery in US5.

### Parallel Opportunities

- **Setup**: T003–T007 all parallel
- **Foundational**: T008–T011 (mocks and harness) parallel with each other, and can start before T012
- **All test-writing tasks within a phase are parallel** — separate files
- **US1 and US2 can be built by two developers simultaneously** after Foundational; they touch
  different functions in the same file, so coordinate merges
- **US7 is fully independent** and can be picked up at any point after Foundational
- **Implementation tasks are NOT parallel** — one contract file (see the note at the top)

## Parallel Example: User Story 1

```bash
# All US1 tests, written together before any implementation:
Task: "Write test/unit/TopUp.t.sol covering 001 FR-001..FR-009"
Task: "Write test/attack/Reentrancy.t.sol"
Task: "Write test/attack/ForcedBalance.t.sol"
Task: "Write test/attack/DoSGriefing.t.sol"
Task: "Write test/attack/Arithmetic.t.sol"

# Confirm they all FAIL, then implement T028-T031 sequentially.
```

---

## Implementation Strategy

### MVP (User Story 1 only)

1. Phase 1 Setup → 2. Phase 2 Foundational → 3. Phase 3 US1
4. **STOP and VALIDATE**: top-ups work, funds route, nothing is retained, attack suite green
5. Deployable to testnet with a fixed treasury

### Responsibly deployable increment (US1 + US2)

MVP alone has an immutable treasury address — a typo at deployment would be permanent. **Do not
deploy to mainnet without US2.** Adding treasury rotation is what makes the deployment recoverable
from a wrong destination.

### Incremental delivery

1. Setup + Foundational → foundation ready
2. US1 → testnet demo (MVP)
3. US2 → responsibly deployable
4. US7 → incident response available
5. US5 + US6 → full governance and the multisig handover path
6. US3 + US4 → sponsored payments and provable reconciliation
7. Phase 10 → audit, verification, mainnet

### Ordering note on tests

Constitution Principle III requires the failing test first, in every phase, without exception. The
attack tests in particular must be written before the code they attack — writing them afterwards
tends to confirm what the code does rather than what it must resist.

---

## Notes

- **88 tasks total.** Implementation tasks are sequential by necessity (one contract file); test
  tasks parallelize freely.
- Commit after each task or logical group; keep `forge test` green at every commit after Phase 3.
- The contract is **immutable** — there is no post-deployment fix. Phase 10's gates are not
  ceremony; they are the last opportunity to catch anything.
- T082 (Arc EVM version) and T085 (external audit) are hard blockers for mainnet.

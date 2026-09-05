---

description: "Task list for 003-simplify-immutable-router"
---

# Tasks: Fully Immutable Top-Up Router

**Input**: Design documents from `/specs/003-simplify-immutable-router/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: REQUIRED, not optional. Constitution Principle III mandates test-first development and Principle II mandates adversarial coverage. Test tasks are therefore first-class here, not an add-on.

**Organization**: Grouped by user story. Read the note below before assuming the phases are independently shippable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Which user story the task serves (US1–US5)
- Every task names its exact file path

## Path Conventions

Single Foundry project at repository root: `src/`, `script/`, `test/`, `docs/`.

## A note on story independence

Every P1 story is an edit to the same file, `src/TopUpRouter.sol`, and Solidity compiles as a unit. A test suite that references a function removed in another story will not compile, so the stories cannot be merged to `main` one at a time the way a web feature could. In practice:

- **Phases 3–5 (US1, US2, US5) land together as one commit.** They are separated below because they are *verified* independently — each has its own tests proving its own guarantee — not because they can ship separately.
- **Phases 6–7 (US3, US4) are genuinely separable** and can be reviewed as follow-on commits.
- Test-first is preserved by writing the absence-tests before the removals (T013–T015 precede T016+), accepting that the suite is briefly red-because-uncompilable rather than red-because-failing. That is a property of the language, not a shortcut — call it out in the PR rather than pretending a clean red-green cycle.

---

## Phase 1: Setup

**Purpose**: Establish a baseline that a reviewer can diff against.

- [X] T001 Create feature branch `003-simplify-immutable-router` from `main` and confirm the working tree is clean, per constitution Principle VII (no deployment from an uncommitted tree)
- [X] T002 Record the pre-change baseline: run `forge snapshot` and commit the result as the 002 gas baseline so the Phase 8 comparison is against a committed reference
- [X] T003 [P] Run `forge test` and `forge coverage --report summary` on the unchanged tree and record the numbers in the PR description, so any coverage regression is visible rather than inferred

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The denomination fix and the test harness. Everything else depends on these.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

**Note on US4**: the 6-decimal denomination is nominally a P2 story, but `MIN_TOPUP = 1e6` is load-bearing for every test in every other phase, so the constant lands here. US4's own phase covers the documentation and verification sweep.

- [X] T004 Rewrite `test/BaseTest.sol`: remove the `admin`, `pauser` actors, the `DELAY` constant, `warpPastDelay()`, `warpToJustBeforeEta()`, and the `MockMultisig` import/helper; change `MIN_TOPUP` from `1e18` to `1e6` and `STARTING_BALANCE` from `1000e18` to `1000e6`; change `setUp()` to the single-argument constructor `new TopUpRouter(treasury)`
- [X] T005 [P] Delete `test/mocks/MockMultisig.sol` — it exists only to stand in as a contract admin, and no admin remains
- [X] T006 Delete the obsolete governance suites in one commit so the tree compiles: `test/unit/TreasuryRotation.t.sol`, `test/unit/AuthorityTransfer.t.sol`, `test/unit/PauseControl.t.sol`, `test/unit/PauserRotation.t.sol`, `test/attack/TimelockBypass.t.sol`, `test/integration/GovernanceLifecycle.t.sol`, `test/invariant/GovernanceInvariant.t.sol`, `test/invariant/handlers/GovernanceHandler.sol`
- [X] T007 [P] Rescale native-amount literals from `1e18` to `1e6` in `test/unit/TopUp.t.sol` and `test/unit/Accounting.t.sol`, treating one whole USDC as `1e6` per research R-001
- [X] T008 [P] Rescale native-amount literals from `1e18` to `1e6` in `test/attack/Reentrancy.t.sol`, `test/attack/Arithmetic.t.sol`, `test/attack/DoSGriefing.t.sol`, and `test/attack/ForcedBalance.t.sol`
- [X] T009 [P] Rescale native-amount literals and update the constructor call in `test/invariant/AccountingInvariant.t.sol` and `test/invariant/handlers/AccountingHandler.sol`
- [X] T010 [P] Rescale native-amount literals and update the constructor call in `test/symbolic/AccountingSymbolic.t.sol`, keeping the halmos symbolic bounds meaningful at the smaller scale
- [X] T011 Verify no `1e18` or `000000000000000000` literal remains in a native-amount position: `grep -rnE "1e18|000000000000000000" src/ script/ test/ .env.example` returns nothing (quickstart Step 0)

**Checkpoint**: none — and deliberately so. This phase leaves the tree uncompilable: the new harness calls a single-argument constructor that the old contract does not yet have. That is expected. The tree compiles again at the end of Phase 5, and Phases 2–5 are one commit.

---

## Phase 3: User Story 1 — Contributor tops up with a guaranteed destination (P1)

**Goal**: The treasury is fixed at deployment and no operation anywhere can change it.

**Independent test**: Deploy with a known treasury, top up from several accounts, confirm each lands at that treasury; confirm no callable path changes the destination.

### Tests first

- [X] T012 [P] [US1] Create `test/unit/Immutability.t.sol` with a raw-selector probe helper that asserts a call reverts as an *unrecognised selector* rather than with a named error, per research R-005 — this distinction is the whole point of the file
- [X] T013 [US1] In `test/unit/Immutability.t.sol`, probe the removed treasury-governance selectors: `proposeTreasury`, `applyTreasury`, `cancelTreasury`, `pendingTreasury`, `DELAY`
- [X] T013a [US1] In `test/unit/Immutability.t.sol`, probe the selectors that must NEVER exist, not merely the ones being removed (FR-015, FR-016): `withdraw`, `withdrawAll`, `sweep`, `sweepToken`, `rescue`, `rescueTokens`, `rescueERC20`, `emergencyWithdraw`, `execute`, `call`, `upgradeTo`, `upgradeToAndCall`, `initialize`, `implementation`, `proxiableUUID`. FR-015 is the contract's central guarantee — that no funds leave except to the treasury via a top-up — and it is the one claim with no test behind it otherwise
- [X] T014 [P] [US1] In `test/unit/Deployment.t.sol`, rewrite for the single-argument constructor: assert `treasury()` returns the deployed value, and assert `ZeroAddress` and `SelfAddress` reverts on the two invalid inputs

### Implementation

- [X] T015 [US1] In `src/TopUpRouter.sol`, change `address public treasury` to `address public immutable treasury`, set it in the constructor, and delete `proposeTreasury`, `applyTreasury`, `cancelTreasury`, and `pendingTreasury`
- [X] T016 [US1] In `src/TopUpRouter.sol`, delete the whole pending-change engine: the `Subject` enum, the `PendingChange` struct, `DELAY`, `pendingAdmin`, `pendingPauser`, `_propose`, `_applyPending`, `_cancel`, `_pendingSlot`, and the `ChangeProposed`/`ChangeApplied`/`ChangeCancelled` events (research R-004)
- [X] T017 [US1] In `src/TopUpRouter.sol`, delete the `admin` and `multisigEstablished` storage, the `onlyAdmin` modifier, the `MultisigEstablished` event, the `proposeAdmin`/`applyAdmin`/`cancelAdmin` functions, and the errors `NotAdmin`, `NoPendingChange`, `TimelockNotElapsed`, `MustBeContract` (FR-014)
- [X] T018 [US1] In `src/TopUpRouter.sol`, delete the three `ChangeApplied` emissions from the constructor — with an immutable public treasury there is no state an indexer can miss, so no replacement event is added (research R-004)
- [X] T019 [US1] In `src/TopUpRouter.sol`, delete the `uninitialized-state` suppressions (both slither and forge-lint) and the `unsafe-typecast` and `block-timestamp`/`timestamp` suppressions, all of which existed solely for the removed engine
- [X] T020 [US1] In `src/TopUpRouter.sol`, rewrite the `arbitrary-send-eth` suppression justification in `_topUp`: the current text reasons from a quorum-approved 2-day proposal that no longer exists; the correct justification is that `destination` is an immutable fixed at construction

**Checkpoint**: US1 is verifiable — top-ups route to a destination that provably cannot change.

---

## Phase 4: User Story 2 — Top-ups cannot be halted (P1)

**Goal**: No pause exists, and no emergency-stop role exists to hold it.

**Independent test**: Confirm no pause/unpause/paused surface exists; confirm top-ups succeed across arbitrary block times and callers.

### Tests first

- [X] T021 [P] [US2] In `test/unit/Immutability.t.sol`, probe the removed pause selectors: `pause`, `unpause`, `paused`, `pauser`, `proposePauser`, `applyPauser`, `cancelPauser`, `pendingPauser`, `multisigEstablished`, `admin`
- [X] T022 [P] [US2] Rewrite `test/attack/AccessControl.t.sol` to assert the *inverse* of what it asserts today: exercising the entire surface from an arbitrary unprivileged address produces results identical to any other caller, and no address confers privilege (SC-004a)
- [X] T023 [P] [US2] Add a test to `test/unit/TopUp.t.sol` asserting top-ups succeed at widely separated `vm.warp` timestamps, proving there is no state or time in which top-ups are refused other than the FR-006/FR-007 validation rules

### Implementation

- [X] T024 [US2] In `src/TopUpRouter.sol`, remove the `Pausable` import and base contract, the `whenNotPaused` modifier from `_topUp`, the `pause`/`unpause` functions, the `pauser` storage, the `onlyPauser` modifier, the `proposePauser`/`applyPauser`/`cancelPauser` functions, and the `NotPauser` error (research R-002)
- [X] T025 [US2] Confirm in review that removing `Pausable` did not disturb `ReentrancyGuard`: `src/TopUpRouter.sol` still inherits it and `_topUp` is still `nonReentrant`, and `test/attack/Reentrancy.t.sol` still passes. The hostile-treasury threat is unchanged by this feature, and the guard is not a governance mechanism

**Checkpoint**: US2 is verifiable — no caller can halt top-ups because no halting operation exists.

---

## Phase 5: User Story 5 — Only native USDC is accepted (P1)

**Goal**: One currency, structurally, with no token surface that could ever be extended.

**Independent test**: Confirm the contract exposes no operation naming, accepting, or transferring any token other than the chain's native currency.

### Tests first

- [X] T026 [P] [US5] Add a test to `test/unit/Immutability.t.sol` asserting the built ABI contains no function, event, or error whose signature names a token, and no `receive`/`fallback` — direct sends still revert (FR-017a/b)
- [X] T027 [P] [US5] Add a test to `test/attack/ForcedBalance.t.sol` asserting that a plain ERC-20 transferred to the router address changes no contribution, does not move `totalRouted`, and is not recoverable by any caller (FR-017c)

### Implementation

- [X] T028 [US5] In `src/TopUpRouter.sol`, rewrite the NatSpec threat-model table rather than editing rows out of it (research R-007): retain the hostile/reverting treasury, forced balance, and accounting-overflow rows; delete the governance-shaped rows; and add a row for the new accepted risk that a deployment-time treasury mistake is permanently unrecoverable. Also record why the front-running and transaction-ordering class from constitution Principle II is now inapplicable — with an immutable treasury and no governance there is no ordering-sensitive state to exploit — rather than leaving it silently absent
- [X] T029 [US5] In `src/TopUpRouter.sol`, update the contract header to state that native USDC is the only accepted currency, that no token support will ever be added, and that non-native tokens sent to the address are permanently stranded

**Checkpoint**: All three P1 stories verifiable. This is the MVP — Phases 2–5 commit together.

---

## Phase 6: User Story 3 — Operator deploys with fewer parameters (P2)

**Goal**: One deployment parameter, and a loud failure when it is missing.

**Independent test**: Deploy with the reduced parameter set; remove the required parameter and confirm refusal before broadcast.

### Tests first

- [X] T030 [P] [US3] Rewrite `test/unit/DeployScript.t.sol` for the single-parameter script: assert `validate()` passes with a good treasury, reverts `MissingParameter("TREASURY_ADDRESS")` on zero, and reverts `WrongNetwork` off Arc
- [X] T031 [P] [US3] Add a test to `test/unit/DeployScript.t.sol` asserting that leftover `MIN_TOPUP_WEI` and `PAUSER_ADDRESS` values in the environment are ignored entirely and do not reach the deployed contract (US3 scenario 2, FR-011/FR-012)

### Implementation

- [X] T032 [US3] Rewrite `script/Deploy.s.sol`: read only `TREASURY_ADDRESS`, drop the `ADMIN_ADDRESS`/`PAUSER_ADDRESS`/`MIN_TOPUP_WEI` reads, delete the `PauserMustDifferFromAdmin` error and its check, and call the single-argument constructor
- [X] T033 [US3] In `script/Deploy.s.sol`, reduce `validate()` to the network check plus the treasury zero-check, and update `_report()` to log only the router address and treasury — removing the "handover takes 2 days" next-step line, which no longer describes anything
- [X] T034 [US3] Add a prominent warning to `script/Deploy.s.sol`'s NatSpec that the treasury is permanent and a treasury that reverts on receipt bricks every future top-up
- [X] T035 [P] [US3] Delete `script/ProposeHandover.s.sol` — with no admin the script has no meaning, and leaving it invites an operator to run a script that reverts (plan, decision 6)
- [X] T036 [P] [US3] Rewrite `.env.example`: keep `ARC_TESTNET_RPC`, `ARC_EXPLORER_KEY`, `TREASURY_ADDRESS`, and the signer block; delete `ADMIN_ADDRESS`, `PAUSER_ADDRESS`, `MIN_TOPUP_WEI`, `ADMIN_ACCOUNT`, `PAUSER_ACCOUNT`, and `ANY_FUNDED_ACCOUNT`, and rewrite the header comments that describe a changeable treasury and a 2-day delay

**Checkpoint**: US3 verifiable — deployment takes one address and refuses cleanly without it.

---

## Phase 7: User Story 4 — Amounts read and reported in 6 decimal places (P2)

**Goal**: Every figure a human reads is 6-decimal, with no 18-decimal residue anywhere.

**Independent test**: Top up one whole USDC and confirm every published figure, record, and document expresses it as 1,000,000 base units.

### Tests first

- [X] T037 [P] [US4] Add a test to `test/unit/TopUp.t.sol` asserting that a top-up of exactly `1e6` succeeds at the minimum boundary, `1e6 - 1` reverts `BelowMinimum`, and the emitted `amount` and `newTotal` are both `1e6`

### Implementation

- [X] T038 [US4] In `src/TopUpRouter.sol`, replace `uint256 public immutable MIN_TOPUP` with `uint256 public constant MIN_TOPUP = 1e6`, remove it from the constructor and remove the `minTopUp == 0` check, and delete the now-unnecessary `slither-disable-next-line naming-convention` suppression (research R-003)
- [X] T039 [US4] In `src/TopUpRouter.sol`, document `MIN_TOPUP`'s unit and provenance in NatSpec — one whole USDC at Arc's 6-decimal native denomination, permanent and unchangeable — satisfying Principle IV's no-magic-numbers rule
- [X] T040 [US4] Rewrite `test/fork/ArcTestnet.t.sol` for the single-argument constructor and the `1e6` scale, and tie at least one amount to a faucet-funded balance rather than a literal, so the chain's own denomination participates in the assertion (research R-001 — this is the check that would have caught the 002 defect)

**Checkpoint**: US4 verifiable — the denomination is correct in code, tests, and against the live chain.

---

## Phase 8: Polish & Cross-Cutting Concerns

### Documentation

- [X] T041 [P] Rewrite `README.md`: state the permanent treasury, no pause, no roles, and the one-USDC minimum; remove governance and handover material; add the warning that non-native tokens sent to the contract are permanently unrecoverable (FR-017c, FR-018)
- [X] T042 [P] Rewrite `docs/DEPLOYMENT.md` for the one-parameter deployment: remove the admin, pauser, `MIN_TOPUP_WEI`, and multisig-handover sections, and add the treasury-is-permanent warning
- [X] T043 [P] Reduce `docs/OPERATIONS.md` to what remains — there are no privileged operations left, so this is mostly deletion; state plainly that incident response is limited to ceasing to advertise the address and deploying a replacement
- [X] T044 [P] Update `docs/LINT-EXCEPTIONS.md`: remove the `not-rely-on-time` row (no time-dependent code remains) and re-check `.solhint.json` so the disabled-rule list matches the code that is actually there
- [X] T045 Run the documentation sweep from quickstart Step 10 and confirm no hits outside `docs/deployments/arc-testnet.md`

### Quality gates (constitution Principles II, IV, VII)

- [X] T046 Run `forge build` (warnings are errors) and `forge fmt --check`; both must be clean
- [X] T047 Run `forge test` and confirm green, with the seven deleted suites absent and all surviving suites passing
- [X] T048 Run `forge coverage --report summary` and confirm ≥ 95% lines and branches on `src/`, justifying any uncovered branch in the PR description
- [X] T048a Review NatSpec completeness against constitution Principle IV: every public and external function, event, error, and storage variable in `src/TopUpRouter.sol` carries `@notice`, `@param`, `@return`, and `@dev` as applicable. The rewrite touches all of them and `forge build` does not check this
- [~] T049 [P] Run `slither .`, `solhint 'src/**/*.sol'`, and `forge lint src/`; all must be clean, with fewer suppressions than before rather than the same set carried forward. **PARTIAL: `forge lint src/` is clean (only the pre-justified `low-level-calls` note). `slither` and `solhint` are NOT INSTALLED in the implementation environment — must be run in CI or locally before merge.**
- [ ] T050 [P] Run `halmos` against `test/symbolic/AccountingSymbolic.t.sol` and confirm the accounting invariants still hold at the new scale. **BLOCKED: `halmos` is not installed in the implementation environment.**
- [X] T051 Run `forge snapshot` and confirm `topUp` is cheaper than the T002 baseline; commit the new snapshot and include the diff in the PR (Principle IV)
- [X] T052 Verify the built ABI matches `specs/003-simplify-immutable-router/contracts/TopUpRouter.abi.md` exactly via `forge inspect TopUpRouter abi`; any extra entry is a spec violation, not a review comment (SC-002)

### Deployment (constitution Principles VI, VII)

- [ ] T053 Run the fork rehearsal against Arc testnet per quickstart Step 7, before any broadcast
- [ ] T054 Sanity-check the denomination against a faucet-funded balance per quickstart Step 0; a result near `10^18` contradicts the documentation and must stop the deployment
- [ ] T055 Validate the intended treasury address independently and confirm it accepts a plain transfer — it can never be changed, and a treasury that reverts on receipt bricks the contract permanently
- [ ] T056 Deploy to Arc testnet with `--verify --verifier blockscout` per quickstart Step 8, from a clean tree at a tagged commit
- [ ] T057 Run the post-deployment confirmation calls from quickstart Step 9: `treasury()` and `MIN_TOPUP()` return the expected values; `paused()` and `admin()` fail against the live contract
- [ ] T058 Commit the deployment record to `docs/deployments/arc-testnet-v2.md` — address, constructor args, tx hash, block number, commit SHA, verification status (Principle VII)

### Fallout from R-001 — the 002 deployment

These are not part of the contract change but must ship with it. See research R-001.

- [X] T059 [P] Append a dated erratum to `docs/deployments/arc-testnet.md`: the "1 USDC, 18 decimals" annotation is wrong; at Arc's true 6-decimal scale that router's `MIN_TOPUP` of `1e18` is one trillion USDC, so it can accept no reachable top-up and is non-functional. Append only — do not rewrite the historical record
- [X] T060 [P] Add a forward-pointer from `docs/deployments/arc-testnet.md` to `arc-testnet-v2.md`
- [X] T061 Confirm the 002 router address is not presented as usable anywhere in `README.md` or `docs/`
- [ ] T062 Decide whether to pause the 002 router so the dead address fails loudly rather than silently — an operational call for the maintainers, and the last time the option exists, since the new router can never be paused

### Governance

- [ ] T063 Confirm the constitution amendment to 1.1.0 (Principle VI, 6 decimals) is included in this PR, and that the PR description states the version bump and migration impact as the amendment procedure requires
- [ ] T064 In the PR description, explicitly ask reviewers to acknowledge the two accepted trade-offs from plan.md Complexity Tracking: the contract has zero incident response, and mis-sent ERC-20s are unrecoverable. Principle V review requires these be acknowledged, not passed over silently
- [ ] T065 Obtain two approvals — this changes value-handling logic and access control, so Principle IV's review rule requires two, with explicit confirmation that adversarial tests cover the changed surface

---

## Dependencies & Execution Order

```
Phase 1 (Setup)
    ↓
Phase 2 (Foundational) ──── blocks everything
    ↓
Phase 3 (US1) ─┐
Phase 4 (US2) ─┼── one commit; same file, must compile together
Phase 5 (US5) ─┘
    ↓
Phase 6 (US3) [P with Phase 7]
Phase 7 (US4) [P with Phase 6]
    ↓
Phase 8 (Polish, deployment, 002 fallout, governance)
```

**Story dependencies**: US1, US2, and US5 all edit `src/TopUpRouter.sol` and are verified independently but delivered together. US3 (scripts and env) and US4 (denomination and docs) touch disjoint files and can proceed in parallel once the contract is settled.

**Critical path**: T004 → T006 → T015–T017 → T024 → T038 → T047 → T056.

**Task count**: 67 (T001–T065 plus T013a, T048a).

## Parallel Execution Opportunities

- **Phase 2**: T007, T008, T009, T010 are four disjoint test-file rescales — parallel after T004.
- **Phase 3–5 tests**: T012, T014, T021, T022, T023, T026, T027 touch different files; only the `Immutability.t.sol` tasks (T012, T013, T013a, T021, T026) must serialize against each other.
- **Phase 6**: T035 and T036 are independent of T032–T034.
- **Phase 8 docs**: T041, T042, T043, T044 are four separate files — fully parallel.
- **Phase 8 gates**: T049 and T050 run in parallel; T046–T048 serialize on the build.
- **Phase 8 fallout**: T059 and T060 touch the same file and must serialize; T061 is independent.

## Implementation Strategy

**MVP scope**: Phases 1–5. That delivers the three P1 stories — a permanent destination, unstoppable top-ups, and a single currency — which together are the entire guarantee this feature exists to make. It is a working, deployable contract without Phases 6–8.

**Incremental delivery**:

1. Phases 1–5 as one commit and one review — the contract rewrite.
2. Phase 6 — scripts and environment.
3. Phase 7 — denomination sweep and fork test.
4. Phase 8 — docs, gates, deployment, and the 002 fallout.

**Do not deploy before Phase 8.** T054 and T055 are the last cheap moments to catch a permanent error. Everything about this contract that could be wrong is wrong forever.

# Implementation Plan: Fully Immutable Top-Up Router

**Branch**: `003-simplify-immutable-router` | **Date**: 2026-09-05 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/003-simplify-immutable-router/spec.md`

## Summary

Replace `TopUpRouter` with a governance-free successor. Every privileged surface is deleted: the treasury becomes `immutable`, the pauser role and `Pausable` inheritance go away, and the entire timelocked pending-change engine — `DELAY`, `Subject`, `PendingChange`, `_propose`/`_applyPending`/`_cancel`, `pendingTreasury`/`pendingAdmin`/`pendingPauser`, and the `admin` and `multisigEstablished` state — is removed. `MIN_TOPUP` stops being a constructor argument and becomes a compile-time `constant`. The constructor takes one argument. What remains is a payable forwarder: validate, credit, emit, transfer.

The contract shrinks from 584 lines and 15 external functions to roughly 120 lines with 2 state-changing functions (plus four view getters). That shrinkage is the deliverable — it is what makes an ungoverned immutable contract defensible.

**Decimals resolved**: Arc's native USDC has **6 decimals**, confirmed 2026-09-05 against Arc documentation naming the matching chain ID `5042002` (R-001). Constitution Principle VI, which asserted 18, was factually wrong and has been amended (1.0.0 → 1.1.0). `MIN_TOPUP` is therefore `1e6` — one whole USDC.

**Spillover finding**: the already-deployed 002 router carries `MIN_TOPUP = 1e18` base units = one trillion USDC. It can accept no reachable top-up and is non-functional. Its minimum is immutable, so this redeployment is the only remedy. Handled as tasks, not as a scope change — see R-001.

## Technical Context

**Language/Version**: Solidity 0.8.28 (pinned, `foundry.toml`)

**Primary Dependencies**: OpenZeppelin `ReentrancyGuard` only. `Pausable` is dropped by this feature.

**Storage**: On-chain contract state — `totalRouted` (uint256) and `contributions` (mapping). No pending-change slots, no role addresses.

**Testing**: Foundry — `forge test` (unit, integration, invariant, fork, attack), `halmos` for symbolic accounting, `slither` + `solhint` + `forge lint src/` static analysis, `forge coverage` ≥ 95% lines and branches.

**Target Platform**: Arc Testnet, chain ID 5042002. Mainnet parameters remain unpublished (constitution TODO(ARC_MAINNET_PARAMS)).

**Project Type**: Single Foundry smart-contract project.

**Performance Goals**: `topUp` gas at or below the current implementation's snapshot. Removing `whenNotPaused` (one SLOAD) and making `MIN_TOPUP` a `constant` rather than `immutable` should both reduce it; a snapshot regression is a CI failure.

**Constraints**: Immutable, non-upgradeable, no proxy. No privileged caller of any kind. No withdrawal, sweep, or rescue path. Payment is native USDC via `msg.value` only — no ERC-20 surface anywhere.

**Scale/Scope**: One contract in `src/`, one deployment script, ~10 test files to delete or rewrite, 4 documentation files, 1 environment template.

**Denomination**: Native USDC, 6 decimals. One whole USDC = `1e6` base units. `MIN_TOPUP = 1e6`. No conversion constant is needed anywhere, since native and bridged USDC now share one scale.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Security-First Design | ⚠️ Conditional | Threat model must be rewritten, not edited. Removing the pause deletes the only fast incident response for an immutable contract; the spec accepts this explicitly. Checks-effects-interactions and the hostile-treasury assumption are unchanged. See Complexity Tracking. |
| II. Adversarial Test Coverage | ✅ Pass by construction | The attack surface shrinks to a strict subset. Access-control and timelock-bypass tests are deleted along with the features they attack; reentrancy, arithmetic, DoS/griefing, and forced-balance tests all remain and must stay green. New negative tests assert the *absence* of the removed surface. |
| III. Test-First Development | ✅ Pass | Tests asserting the removed functions are gone (by ABI inspection) are written before the deletions. |
| IV. Code Quality | ✅ Pass, improved | Most of the existing lint suppressions exist to serve the pending-change engine (`uninitialized-state` on three slots, `unsafe-typecast` on the eta, `block-timestamp`) and disappear with it. `docs/LINT-EXCEPTIONS.md` must shrink correspondingly. |
| V. Explicit Upgradeability & Access Control | ✅ Pass vacuously — **flag for review** | "No single unbounded owner" is satisfied absolutely: there is no owner. But the principle's requirement that "pause and emergency-withdrawal powers MUST be narrowly scoped, documented, and tested from both sides" now has no subject. This is a deliberate reading, not an oversight; recorded below. |
| VI. Arc Chain Deployment Discipline | ✅ **Pass** (was a gate failure) | Resolved: Arc is 6-decimal, the constitution was wrong, and Principle VI has been amended to match (1.1.0). FR-010 stands as written. No chain IDs or addresses are hardcoded in `src/`; `evm_version` is unchanged. |
| VII. Reproducible, Auditable Releases | ✅ Pass | New deployment, new address, new artifacts under `docs/deployments/`. The existing testnet record stays as history and must not be edited. |

### Resolved — Principle VI, decimals

The spec and the constitution disagreed: FR-010 required 6 decimals, Principle VI asserted 18. The constitution was wrong. Arc's documentation states USDC is the native gas token with 6 decimals, "not 18 like most EVM chains", and names the testnet chain ID `5042002` this project targets. Principle VI has been amended (MINOR, 1.0.0 → 1.1.0) with the rationale and migration impact recorded in its Sync Impact Report.

`MIN_TOPUP` is `1e6` base units — one whole USDC, as FR-006 intends.

**This disagreement uncovered a live defect.** The deployed 002 router was built on the 18-decimal assumption and carries `MIN_TOPUP = 1e18` = one trillion USDC. It accepts nothing, permanently. The test suite did not catch it because every test used `1e18` for both the minimum and the amounts — arithmetic that is internally consistent at the wrong scale passes every assertion. Three follow-ups fall out of this and are tracked in R-001: an erratum on the historical deployment record, rescaling the fork-test literals, and ensuring the dead address is not advertised as usable.

## Project Structure

### Documentation (this feature)

```text
specs/003-simplify-immutable-router/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   └── TopUpRouter.abi.md
├── checklists/
│   └── requirements.md
├── spec.md
└── tasks.md             # Phase 2 (/speckit-tasks — not created here)
```

### Source Code (repository root)

```text
src/
└── TopUpRouter.sol            # rewritten: governance removed, treasury immutable

script/
├── Deploy.s.sol               # rewritten: one env var, one constructor arg
└── ProposeHandover.s.sol      # DELETED — no admin exists to hand over

test/
├── BaseTest.sol               # rewritten: no role fixtures
├── unit/
│   ├── TopUp.t.sol            # kept, adjusted for constant minimum
│   ├── Accounting.t.sol       # kept
│   ├── Deployment.t.sol       # rewritten: single-arg constructor
│   ├── DeployScript.t.sol     # rewritten
│   ├── Immutability.t.sol     # NEW: asserts removed surface is absent
│   ├── TreasuryRotation.t.sol # DELETED
│   ├── AuthorityTransfer.t.sol# DELETED
│   ├── PauseControl.t.sol     # DELETED
│   └── PauserRotation.t.sol   # DELETED
├── attack/
│   ├── Reentrancy.t.sol       # kept
│   ├── Arithmetic.t.sol       # kept
│   ├── DoSGriefing.t.sol      # kept
│   ├── ForcedBalance.t.sol    # kept
│   ├── AccessControl.t.sol    # rewritten: asserts no privilege exists
│   └── TimelockBypass.t.sol   # DELETED
├── integration/
│   └── GovernanceLifecycle.t.sol  # DELETED (nothing left to govern)
├── invariant/
│   ├── AccountingInvariant.t.sol  # kept
│   ├── GovernanceInvariant.t.sol  # DELETED
│   └── handlers/
│       ├── AccountingHandler.sol   # kept
│       └── GovernanceHandler.sol   # DELETED
├── symbolic/AccountingSymbolic.t.sol  # kept
├── fork/ArcTestnet.t.sol      # rewritten: new constructor, decimals per R-001
└── mocks/
    ├── MaliciousTreasury.sol  # kept
    ├── ForceSender.sol        # kept
    └── MockMultisig.sol       # DELETED

docs/
├── DEPLOYMENT.md              # rewritten: one parameter, no handover
├── OPERATIONS.md              # largely deleted: no operations remain
├── LINT-EXCEPTIONS.md         # shrinks with the removed suppressions
└── deployments/
    ├── arc-testnet.md         # UNCHANGED — historical record of 002
    └── arc-testnet-v2.md      # NEW, after redeployment

.env.example                   # rewritten: TREASURY_ADDRESS + signer only
README.md                      # rewritten guarantees section
```

**Structure Decision**: The existing single-project Foundry layout is kept exactly as the constitution's Security & Testing Requirements mandate (`test/unit`, `test/integration`, `test/invariant`, `test/fork`, `test/attack`). This feature changes what is in those directories, not the directories themselves. `test/attack/` remains non-empty, as required for any value-moving contract.

## Key design decisions

1. **Rewrite `src/TopUpRouter.sol` in place rather than adding a v2 contract.** The repository deploys one contract; git history is the version record, and `docs/deployments/` distinguishes the deployed instances by address. A second source file would invite the mistake of deploying the wrong one.

2. **`MIN_TOPUP` becomes `constant`, not `immutable`.** FR-006 fixes the value in the contract; a `constant` makes it identical across every build and removes it from the constructor, which is precisely what the spec asks for. Its value is pending R-001.

3. **The treasury becomes `immutable`, and the `destination` cache in `_topUp` stays.** The cache exists in the current code to guard against a rotation landing mid-block. That risk is gone, but reading an immutable into a local is free and keeps the event-emission code identical, so the diff stays reviewable.

4. **`_requireValidAddress` survives, constructor-only.** The zero-address and self-address checks still matter for the one remaining constructor argument — an immutable treasury set to zero would be an unfixable brick.

5. **No `receive`/`fallback` is added, and none is removed.** Direct sends still revert. This stays true and stays tested.

6. **Deleting `ProposeHandover.s.sol` is deliberate and total.** With no admin, the handover script has no meaning. Deleting it prevents an operator from running a script that reverts against a contract that no longer has the function.

## Complexity Tracking

> Violations of the Constitution Check that are being carried deliberately.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|--------------------------------------|
| Principle V: no pause power exists to be "narrowly scoped and tested from both sides" | FR-004; a pause is a key holder changing behaviour, which the immutability guarantee forbids | Keeping a pause-only role was rejected by the spec author (Q2 → Option A). The consequence is accepted in writing: incident response is limited to ceasing to advertise the address and deploying a replacement. |
| Principle I: an immutable contract with zero incident response | Same as above | The mitigation is that the remaining attack surface is ~120 lines with no state-changing path other than a validated forward — small enough to be exhaustively reviewed and formally checked. Simplicity substitutes for recoverability, which is only defensible *because* the contract shrank this far. |
| No rescue path for mis-sent ERC-20 tokens (FR-017c) | FR-015 forbids any non-treasury outflow; a rescue function is a privileged outflow | A token-rescue helper was rejected: it needs an owner, which reintroduces the role the feature exists to delete. Mitigated by documentation warnings only (FR-018), and the loss falls on the sender, not on other contributors. |

## Post-Design Constitution Re-Check

Re-evaluated after Phase 1 (`research.md`, `data-model.md`, `contracts/`, `quickstart.md`).

| Principle | Status after design | Change from initial check |
|-----------|--------------------|---------------------------|
| I. Security-First | ⚠️ Conditional, unchanged | R-007 rewrites the threat model; the unrecoverable-treasury risk is now stated explicitly in the contract header rather than implied. |
| II. Adversarial Coverage | ✅ Pass, strengthened | R-005 adds selector-probing so "MUST NOT expose" is tested as absence, not as a guarded revert. `test/attack/` stays non-empty. |
| III. Test-First | ✅ Pass | Quickstart Step 3 precedes the deletions in task order. |
| IV. Code Quality | ✅ Pass, improved | R-004 identifies four lint suppressions that must be *deleted* with the engine, and one (`arbitrary-send-eth`) whose justification must be rewritten because it currently reasons from a timelock that will no longer exist. |
| V. Access Control | ✅ Pass vacuously | Unchanged. Recorded in Complexity Tracking; needs a reviewer's explicit acknowledgement, not silent acceptance. |
| VI. Arc Discipline | ✅ **Resolved** | R-001 closed with a cited source; constitution amended to 1.1.0. `⟨UNIT⟩` resolves to `1e6` everywhere it appears in `data-model.md` and `contracts/`. |
| VII. Reproducible Releases | ✅ Pass | R-008 keeps the 002 record as history and adds `arc-testnet-v2.md`. |

**Gate verdict**: all gates pass. Two items remain as recorded, accepted trade-offs rather than open questions: the contract will have no incident response (Principle V has no subject), and mis-sent ERC-20s are unrecoverable. Both need a reviewer's explicit acknowledgement at PR time, not further specification work.

`/speckit-tasks` may proceed, and implementation is unblocked. The task list must include the three R-001 follow-ups on the 002 deployment alongside the 003 work itself.

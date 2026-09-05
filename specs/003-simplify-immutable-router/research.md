# Phase 0 Research: Fully Immutable Top-Up Router

**Feature**: `003-simplify-immutable-router` | **Date**: 2026-09-05

---

## R-001: Native USDC decimals on Arc — RESOLVED: 6 decimals

**Question**: Does one whole USDC equal `1e6` or `1e18` base units in `msg.value` on Arc?

**Decision**: **`1e6`. Arc's native USDC has 6 decimals.**

**Evidence** (verified 2026-09-05, `https://docs.getblock.io/api-reference/arc`):

> "Arc uses USDC as its native gas token, with **6 decimals** (not 18 like most EVM chains)."

The same document names this "the single most common integration mistake when porting an existing EVM dApp to Arc", instructs that raw values be divided by 10^6 rather than 10^18 for balances, gas prices, and transaction value fields, and states the testnet chain ID as `5042002` — matching this project's target exactly, so the source is describing the same network the contract deploys to.

**Rationale**: This is a documented property of the chain from a source describing the correct chain ID, not an inference. It also matches USDC's canonical denomination on every other chain, which makes the prior and the evidence agree.

**Consequence — the constitution was wrong**: Principle VI asserted 18 decimals. It has been amended to 6 (version 1.0.0 → 1.1.0, MINOR, per its own versioning policy), with the migration impact recorded in its Sync Impact Report. `FR-006`'s 1,000,000-unit floor is therefore exactly one whole USDC, as intended.

**Consequence — the deployed 002 router is non-functional**: it carries `MIN_TOPUP = 1e18` base units, annotated in `docs/deployments/arc-testnet.md:57` as "1 USDC, 18 decimals". At the correct scale that is 1,000,000,000,000 USDC. No reachable top-up can clear it. The router accepts nothing and never will — `MIN_TOPUP` is immutable, so there is no fix short of this feature's redeployment.

This is a live defect in a deployed contract, discovered by this planning work rather than by the test suite, and it is worth understanding why the suite missed it: every test, including the fork test, used `1e18` consistently for both the minimum and the top-up amounts. Internally consistent arithmetic at the wrong scale passes every assertion. The lesson for 003's tests is that at least one fork-test amount should be tied to a faucet-funded balance rather than to a literal, so the chain's own denomination participates in the assertion.

**Actions required**:

1. ✅ Constitution Principle VI amended to 6 decimals (done, 1.1.0).
2. Add a dated erratum to `docs/deployments/arc-testnet.md` noting the "18 decimals" annotation is wrong and the deployment is unusable. Do not rewrite the historical record.
3. Rescale `test/fork/ArcTestnet.t.sol` literals from `1e18` to `1e6`.
4. Ensure the 002 router address is not advertised anywhere as usable.

**Alternatives considered**: Proceeding on the constitution's 18-decimal claim would have bricked the new contract identically to the old one. The disagreement between spec and constitution was the signal that surfaced the existing bug — worth noting that resolving it by deferring to the ratified document would have propagated the defect.

---

## R-002: Removing `Pausable` — inheritance and storage consequences

**Decision**: Drop the `Pausable` import and base contract entirely; keep `ReentrancyGuard`.

**Rationale**: `whenNotPaused` is the only use of `Pausable` in the contract. Removing it deletes one SLOAD from the hot `_topUp` path and removes `paused()`, `Paused`, and `Unpaused` from the ABI, which is what FR-004 requires — the surface must be absent, not merely unreachable. `ReentrancyGuard` stays: the treasury is still an arbitrary address called with full gas, so the hostile-treasury threat is unchanged.

**Alternatives considered**: Keeping `Pausable` inherited but never callable was rejected — it leaves `paused()` in the ABI, which contradicts FR-004's "MUST NOT expose", and leaves a storage slot whose purpose no reader can explain.

**Consequence for gas**: `topUp` should get cheaper. `forge snapshot --check` is a blocking CI gate; the improvement must be committed as a new snapshot with the diff shown in the PR (Principle IV).

---

## R-003: `constant` versus `immutable` for the minimum

**Decision**: `uint256 public constant MIN_TOPUP`.

**Rationale**: FR-006 fixes the value in the contract and FR-011 forbids it as deployment configuration. `constant` satisfies both and is strictly stronger than `immutable`: the value is identical in every build of a given commit, so testnet and mainnet bytecode cannot diverge on it, and it is verifiable by reading the source alone without inspecting constructor calldata. It also costs no runtime read.

The existing `slither-disable-next-line naming-convention` suppression on `MIN_TOPUP` can be dropped — SCREAMING_SNAKE_CASE is the expected convention for a `constant`, so the finding disappears rather than being suppressed. `docs/LINT-EXCEPTIONS.md` must be updated.

**Alternatives considered**: Retaining `immutable` with a hardcoded constructor default was rejected as strictly worse — same permanence, but the value moves out of the source and into deployment calldata, which is harder to audit.

---

## R-004: Deleting the pending-change engine — what else falls away

**Decision**: Remove `Subject`, `PendingChange`, `DELAY`, `pendingTreasury`/`pendingAdmin`/`pendingPauser`, `_propose`, `_applyPending`, `_cancel`, `_pendingSlot`, and the `ChangeProposed`/`ChangeApplied`/`ChangeCancelled`/`MultisigEstablished` events, plus `admin`, `pauser`, `multisigEstablished`, `onlyAdmin`, `onlyPauser`, and the errors `NotAdmin`, `NotPauser`, `NoPendingChange`, `TimelockNotElapsed`, `MustBeContract`.

**Rationale**: FR-014a requires the mechanism gone, not disabled. Note the constructor currently emits three `ChangeApplied` events at deployment so an indexer can reconstruct state from block zero. With the treasury immutable and readable, that reconstruction need disappears — the value is in the deployment transaction and in a public getter that can never change. No replacement event is needed.

**Static-analysis dividend**: the following suppressions exist solely to serve this engine and must be deleted along with it, not carried forward — `uninitialized-state` (slither and forge-lint, on the three pending slots), `unsafe-typecast` (the `uint64` eta), `block-timestamp`/`timestamp` (the eta comparison). The `arbitrary-send-eth` justification in `_topUp` must be *rewritten*: its current text argues the destination is safe because it "only changes through a quorum-approved proposal that has served a full 2-day delay". That reasoning no longer exists. The new, stronger justification is that `destination` is an `immutable` fixed at construction and cannot change at all.

**Alternatives considered**: Keeping the engine with only the admin subject was rejected by the spec author (Q2 → Option A).

---

## R-005: Proving absence, not just non-function

**Decision**: Add `test/unit/Immutability.t.sol` asserting the removed surface is genuinely gone, by checking that a raw `call` with each removed function's selector reverts as an unrecognised selector, and by asserting no `receive`/`fallback` accepts it.

**Rationale**: FR-001, FR-004, and FR-014 are all "MUST NOT expose" requirements. A test that a call reverts is insufficient on its own — a function could exist and revert for a different reason. Probing by selector against a contract with no fallback distinguishes "absent" from "present but guarded", which is the property the spec actually claims. Selectors to probe: `proposeTreasury`, `applyTreasury`, `cancelTreasury`, `proposeAdmin`, `applyAdmin`, `cancelAdmin`, `proposePauser`, `applyPauser`, `cancelPauser`, `pause`, `unpause`, `paused`, `admin`, `pauser`, `DELAY`, `multisigEstablished`.

Complementing this, the ABI in `contracts/TopUpRouter.abi.md` is the reviewable statement of the full external surface; a CI check that the built ABI matches it would make FR-014 and SC-002 mechanically enforced rather than review-enforced.

**Alternatives considered**: Relying on code review alone was rejected — SC-002 claims *zero* such operations exist, which is a testable claim and should be tested.

---

## R-006: Single-currency enforcement (FR-017a/b/c)

**Decision**: No code is added. The property is enforced by absence: the contract holds no token address, imports no token interface, and has no function taking a token argument. It is asserted in tests and documented for contributors.

**Rationale**: The contract is already native-only — `_topUp` reads `msg.value` and nothing else. FR-017a/b/c ratify existing behaviour and, more importantly, forbid ever adding token support. Since there is now no admin, an allowlist could not be maintained even if one existed, so single-currency is not merely a choice but a structural consequence of the no-roles decision.

**Consequence to document, not to fix**: ERC-20 tokens sent to the address are permanently unrecoverable (FR-017c). A rescue function would require a privileged caller and a non-treasury outflow, violating FR-014 and FR-015 simultaneously. `README.md` and `docs/DEPLOYMENT.md` must carry an explicit warning; this is the only available mitigation and it should be stated plainly rather than buried.

---

## R-007: What the threat model becomes

**Decision**: Rewrite the NatSpec threat-model table rather than editing rows out of it.

**Rationale**: The current table's mitigations are mostly governance-shaped ("delay bypass via parameter change → `DELAY` is a constant"). With governance gone, most rows describe threats that no longer have a surface, and a table of struck-through rows is harder to audit than a short accurate one. The surviving threats are: a hostile or reverting treasury (mitigated by checks-effects-interactions plus `nonReentrant`, and now permanent — a bad treasury cannot be rotated away from, only redeployed around); forced balance via SELFDESTRUCT (mitigated by never reading `address(this).balance`); accounting overflow (mitigated by 0.8 checked arithmetic, verified symbolically); and the new, deliberately accepted risk that a deployment-time treasury mistake is unrecoverable.

That last row is the honest cost of this feature and belongs in the contract header where a reader meets it first.

---

## R-008: Migration from the existing deployment

**Decision**: Out of scope for the contract; in scope for documentation. New address, new deployment record at `docs/deployments/arc-testnet-v2.md`. The existing `docs/deployments/arc-testnet.md` is history and must not be edited except to add a forward-pointer.

**Rationale**: Principle VII requires deployment artifacts be committed and reproducible per tagged commit. The 002 router is immutable and unaffected by this work; it keeps running unless its pauser stops it. Deciding whether to pause the old router after cutover is an operational call for the spec author — worth noting that the old router *can* be paused and the new one never can, which is the clearest possible illustration of what this feature trades away.

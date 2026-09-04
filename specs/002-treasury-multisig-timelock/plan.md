# Implementation Plan: USDC Top-Up Router with Multi-Sig Treasury Governance

**Branch**: `002-treasury-multisig-timelock` | **Date**: 2026-09-04 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specifications from `specs/002-treasury-multisig-timelock/spec.md` (governance)
and `specs/001-usdc-topup/spec.md` (top-up path). These two specs describe **one contract**, and
are planned together. 002 governs where the two differ.

## Summary

A single immutable contract, `TopUpRouter`, that accepts native USDC on Arc via `msg.value`,
forwards the full amount to a treasury address in the same call, and records the payment against a
beneficiary — with no withdrawal path of any kind. The treasury address and the governing authority
are the only mutable state, each changeable only through a two-step propose/apply flow gated by a
fixed, unalterable 2-day delay. Pausing is separated onto its own faster authority.

The technical approach is deliberately minimal: **no proxy, no in-contract signature verification,
no token handling, no balance reads**. Multi-signature authorization is delegated to an external
multisig contract (e.g. a Safe) held as the `admin` address, which reduces the bespoke security
surface to the timelock and the payment path — the two things that genuinely must be custom. The
contract is immutable (001 FR-018), so the entire design optimizes for auditability over
flexibility.

## Technical Context

**Language/Version**: Solidity `0.8.28`, pinned exactly (no floating pragma) per constitution
Principle I.

**Primary Dependencies**: OpenZeppelin Contracts (pinned tag), used only for `ReentrancyGuard` and
`Pausable`. No proxy, no `AccessControl`, no `SafeERC20` — none are needed, and each would add
surface. Rationale in [research.md](./research.md) R-004.

**Storage**: On-chain contract storage only. Six slots: `treasury`, `admin`, `pauser`,
`totalRouted`, the `contributions` mapping, and one packed `pendingChange` struct. No external
storage, no indexer dependency in-contract (001 FR-010 is satisfied by event design).

**Testing**: Foundry — `forge test` with unit, integration, fuzz, invariant, and attack suites;
`forge coverage` ≥95% lines and branches; `slither` and `solhint`; `halmos` for the accounting
identity. Layout per constitution: `test/unit/`, `test/integration/`, `test/invariant/`,
`test/fork/`, `test/attack/`.

**Target Platform**: Arc chain. Testnet chain ID `5042002`, RPC `https://rpc.testnet.arc.io`,
explorer `https://testnet.arcscan.app`. Native gas token is **USDC with 18 decimals**. Mainnet
parameters unpublished — tracked as `TODO(ARC_MAINNET_PARAMS)` in the constitution.

**Project Type**: Single Foundry smart-contract project. One production contract plus test doubles.

**Performance Goals**: Not throughput-bound. The relevant cost is gas for `topUp`, since on Arc the
user pays gas in the same asset they are topping up with.

**MEASURED 2026-09-04 (T078), target revised**: `topUp` costs ~109.8k gas (median), not the ~60k
this plan originally estimated. The original figure was wrong, not the implementation: it did not
account for two cold SSTOREs (`contributions` and `totalRouted`, ~22.1k each), a value-bearing call
to a cold account (~11.6k), plus the event. Those are inherent to the design — the two totals are
required by FR-011/FR-012 and the transfer is the feature.

No safe optimisation is available. Dropping `totalRouted` would save ~22k but breaks the cheap
INV-1 reconciliation check and its public getter; `unchecked` arithmetic would weaken INV-2. Per
constitution Principle IV, optimisation must not reduce clarity or safety, so ~110k is accepted as
the floor for this design. Tracked by `forge snapshot` to catch regressions from here.

**Constraints**:
- Immutable code — no upgrade path, so a defect is unfixable in place (001 FR-018).
- The contract MUST NOT read `address(this).balance` anywhere (001 FR-008). Funds can be forced in
  and must never affect accounting.
- The 2-day delay MUST be a compile-time constant, unalterable by any party (002 FR-008).
- Gas token == payment token, so `topUp` must fail cleanly when a user cannot cover both.

**Scale/Scope**: One contract, ~200 lines of production Solidity. Expected on the order of
thousands of top-ups; per-account totals must not overflow `uint256` (they cannot, given a finite
token supply, but this is asserted rather than assumed).

## Constitution Check

*GATE: evaluated before Phase 0, re-evaluated after Phase 1 design.*

| Principle | Gate | Status |
|---|---|---|
| I. Security-First Design | Threat model documented; CEI ordering; pinned pragma; no `tx.origin`, no `delegatecall`, no unchecked low-level calls | **PASS** — threat model in research.md R-001; single external call is the treasury transfer, made last, with an explicit success check |
| II. Adversarial Test Coverage | Every applicable attack class has an explicit failing-exploit test; fuzz ≥10k runs; stateful invariants; ≥95% coverage | **PASS (planned)** — `test/attack/` enumerated in quickstart.md; ERC-20 classes are N/A (no tokens), replaced by native-transfer and forced-balance classes |
| III. Test-First Development | Tests precede implementation | **PASS (process)** — enforced during `/speckit-tasks` ordering |
| IV. Code Quality | `forge fmt`, full NatSpec, custom errors, clean slither/solhint, no magic numbers | **PASS (planned)** — interface in `contracts/` carries full NatSpec and named errors |
| V. Upgradeability & Access Control | Immutability declared; role-based least privilege; no unbounded owner; multisig + timelock on privileged actions | **PARTIAL — see Complexity Tracking** — immutability and role separation satisfied; the initial single-key window is a documented, time-limited deviation |
| VI. Arc Deployment Discipline | USDC-as-gas at 18 decimals honored; no hardcoded chain IDs/addresses in `src/`; `evm_version` verified; testnet rehearsal | **PASS with one open item** — Arc's supported EVM version is unverified; research.md R-005 sets a conservative default and a verification task |
| VII. Reproducible Releases | Pinned solc and deps, deterministic script, committed artifacts, explorer verification | **PASS (planned)** — `foundry.toml` and `script/` defined below |

**Gate result: PASS**, with one justified deviation (Principle V) recorded in Complexity Tracking
and one open verification item (Arc EVM version) that must close before mainnet deployment.

### Post-Phase-1 re-evaluation

Re-checked after the design in `data-model.md` and `contracts/` was fixed. No new violations. Two
design decisions were made *because* of the gates and are worth recording:

- **Principle I / 001 FR-008** ruled out any use of `address(this).balance`, which in turn ruled
  out a "sweep stranded funds" convenience function. Forced-in funds stay stranded, as specified.
- **Principle V** ruled out OpenZeppelin `AccessControl`: its `DEFAULT_ADMIN_ROLE` can grant itself
  every other role, which is precisely the "single unbounded owner" the principle forbids. Two
  explicit address slots (`admin`, `pauser`) are used instead. See research.md R-004.

## Project Structure

### Documentation (this feature)

```text
specs/002-treasury-multisig-timelock/
├── plan.md              # This file
├── research.md          # Phase 0 — decisions R-001..R-008
├── data-model.md        # Phase 1 — state, transitions, invariants
├── quickstart.md        # Phase 1 — build, test, deploy, verify
├── contracts/
│   └── ITopUpRouter.md  # Phase 1 — external interface, events, errors
└── tasks.md             # Phase 2 — created by /speckit-tasks, not here
```

### Source Code (repository root)

```text
foundry.toml             # pinned solc 0.8.28, evm_version, fuzz/invariant config
remappings.txt
.env.example             # RPC + explorer vars; never keys (constitution)

src/
└── TopUpRouter.sol      # the single production contract

script/
├── Deploy.s.sol         # deterministic deployment, single primary key as admin
└── ProposeHandover.s.sol # propose admin handover to the multisig

test/
├── unit/
│   ├── TopUp.t.sol             # 001 FR-001..FR-008
│   ├── Accounting.t.sol        # 001 FR-009..FR-014
│   ├── TreasuryRotation.t.sol  # 002 FR-001..FR-012
│   ├── AuthorityTransfer.t.sol # 002 FR-013..FR-023a
│   └── PauseControl.t.sol      # 002 FR-024..FR-027
├── integration/
│   └── GovernanceLifecycle.t.sol # deploy → handover → rotate → pause, end to end
├── invariant/
│   ├── AccountingInvariant.t.sol # sum(contributions) == totalRouted
│   └── GovernanceInvariant.t.sol # treasury never changes without quorum + elapsed delay
├── fork/
│   └── ArcTestnet.t.sol        # against a real deployed Safe on Arc testnet
├── attack/
│   ├── Reentrancy.t.sol        # malicious treasury re-entering topUp
│   ├── AccessControl.t.sol     # every privileged fn from every wrong role
│   ├── TimelockBypass.t.sol    # early apply, cancelled apply, stale replay, authority-swap bypass
│   ├── ForcedBalance.t.sol     # selfdestruct-forced funds must not affect accounting
│   ├── DoSGriefing.t.sol       # reverting / gas-hungry treasury
│   └── Arithmetic.t.sol        # boundary and overflow on totals
└── mocks/
    ├── MaliciousTreasury.sol   # reverts, re-enters, or burns gas on receive
    ├── ForceSender.sol         # pushes native funds into the router
    └── MockMultisig.sol        # minimal contract-with-code admin for handover tests
```

**Structure Decision**: Standard single-project Foundry layout. The test tree mirrors the
constitution's mandated directories exactly, with `test/attack/` non-empty as Principle II
requires for a value-moving contract. There is one production contract; no `src/` subdirectories
are warranted at this size and adding them would only obscure the audit surface.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| **Constitution Principle V**: privileged actions are initially controlled by a single primary key rather than a multisig | Explicitly requested (002 spec, Q3 clarification) so that launch is not blocked on provisioning a multisig. The window is transitional, one-way, and publicly visible. | Requiring a multisig at deployment was the simpler and safer alternative and was explicitly declined by the user. The deviation is narrowed as far as the design allows: the single key gets **no** privilege beyond needing fewer approvals — it is bound by the same fixed 2-day delay on every action including its own handover (002 FR-017, FR-023a), it cannot alter the delay (FR-008), and the transition away is one-way (FR-023). |
| **Time-boxing of that deviation is not enforced on-chain** | The constitution requires exceptions be time-boxed and tracked to resolution. Nothing in the contract forces the handover to happen. | An on-chain deadline (halt top-ups if handover has not completed within N days) was offered as option C during clarification and not selected. Recorded here as an **open governance obligation**, not a technical one: the handover must be tracked off-chain to closure. 002 SC-009 makes the window's duration measurable so it cannot be quietly left open. |

No other complexity is introduced: no proxy, no custom cryptography, no external integrations, and
no dependency beyond two OpenZeppelin base contracts.

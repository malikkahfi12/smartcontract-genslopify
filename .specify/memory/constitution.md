<!--
SYNC IMPACT REPORT
Version change: [CONSTITUTION_VERSION] (unratified template) -> 1.0.0
Rationale: Initial ratification. All placeholder tokens replaced with concrete,
testable governance for a Foundry-based smart contract project deployed on Arc.

Modified principles (template placeholder -> ratified name):
- [PRINCIPLE_1_NAME] -> I. Security-First Design (NON-NEGOTIABLE)
- [PRINCIPLE_2_NAME] -> II. Adversarial Test Coverage (NON-NEGOTIABLE)
- [PRINCIPLE_3_NAME] -> III. Test-First Development
- [PRINCIPLE_4_NAME] -> IV. Code Quality & Readability Standards
- [PRINCIPLE_5_NAME] -> V. Explicit Upgradeability & Access Control
- (added) VI. Arc Chain Deployment Discipline
- (added) VII. Reproducible, Auditable Releases

Added sections:
- Security & Testing Requirements (replaces [SECTION_2_NAME])
- Development Workflow & Quality Gates (replaces [SECTION_3_NAME])

Removed sections: none

Deferred items / TODOs:
- TODO(ARC_MAINNET_PARAMS): Arc mainnet chain ID, RPC, and explorer are not yet
  published in the referenced docs; only Arc Testnet (chain ID 5042002) is fixed
  below. Amend this constitution when mainnet parameters are announced.
-->

# Forgeify Smart Contract Constitution

## Core Principles

### I. Security-First Design (NON-NEGOTIABLE)

Security outranks features, deadlines, and gas optimization. Every contract MUST be written
against a documented threat model that names the assets at risk, the trusted roles, and the
assumed adversary capabilities. The checks-effects-interactions ordering MUST be followed in
every state-changing function, and every external call MUST be treated as hostile and
reentrant. Contracts MUST use a pinned, audited Solidity version (no floating pragma) and
MUST NOT use `delegatecall` to unvalidated targets, unchecked low-level calls, `tx.origin`
for authorization, or arbitrary user-supplied calldata forwarded to third-party contracts.
Reentrancy guards, pull-over-push payment patterns, and safe ERC-20 wrappers are the default;
any deviation MUST carry an inline `@dev security:` comment justifying it.

**Rationale**: Deployed bytecode is immutable and adversaries are permanently funded to attack
it. A bug that would be a ticket in a web service is an irreversible loss of user funds here.

### II. Adversarial Test Coverage (NON-NEGOTIABLE)

It is not enough to prove the contract works; the test suite MUST prove that known attacks
fail. For every contract, the suite MUST include explicit negative tests — each written as a
malicious actor attempting an exploit and asserting the revert — covering at minimum, where
applicable to the contract's surface:

- Reentrancy (single-function and cross-function) via a dedicated attacker contract
- Access-control bypass: every privileged function called by an unauthorized address
- Integer boundary and precision abuse: zero, `type(uint256).max`, rounding-to-zero, dust
- Price/oracle manipulation and flash-loan-funded single-block state manipulation
- Front-running, sandwiching, and transaction-ordering dependence
- Denial of service: unbounded loops, gas griefing, reverting recipients, forced-ether balances
- ERC-20 non-standard behavior: fee-on-transfer, rebasing, missing return values, double-entry tokens
- Signature abuse: replay across chains and contracts, malleability, missing nonce/deadline

Fuzz testing (`forge test` with fuzz runs configured, minimum 10,000 runs on invariant-bearing
functions) and at least one stateful invariant suite (`forge` invariant testing) are REQUIRED
for any contract holding value. Line and branch coverage from `forge coverage` MUST be >= 95%
for `src/`, and every uncovered branch MUST be justified in the PR description. A vulnerability
class that cannot be tested MUST be documented in the threat model with its mitigation argument.

**Rationale**: Happy-path tests measure intent; adversarial tests measure safety. The exploits
that drain protocols are all in the list above, and each one is cheap to test and expensive to miss.

### III. Test-First Development

Tests are written before implementation. For a new feature the order is: write the failing test
(including its adversarial cases per Principle II), confirm it fails for the right reason,
implement, then refactor under green tests. Every bug fix MUST begin with a regression test that
reproduces the bug and fails on the unfixed code; the fix is not complete without it. Every
finding from an audit, a security review, or a public disclosure MUST be encoded as a permanent
test case.

**Rationale**: A test written after the code tends to confirm what the code does rather than what
it must do, and post-hoc tests systematically miss the adversarial paths.

### IV. Code Quality & Readability Standards

Auditability is a functional requirement. All Solidity MUST satisfy:

- `forge fmt --check` passes; no formatting diffs are merged
- Complete NatSpec (`@notice`, `@param`, `@return`, `@dev`) on every public and external
  function, event, error, and storage variable
- Custom errors instead of revert strings; named events for every state change that affects
  user funds or permissions
- Functions kept small and single-purpose; deep nesting and long parameter lists are refactored,
  not commented around
- Explicit visibility and mutability on every function and variable; `immutable`/`constant` used
  wherever a value never changes after construction
- No magic numbers: named constants with a documented unit and provenance
- `slither` and `solhint` run clean; any suppressed finding carries an inline justification
- Gas optimization is permitted only when it does not reduce clarity or safety, and only with a
  `forge snapshot` diff in the PR demonstrating the gain

**Rationale**: The reviewer and the auditor are the last line of defense before immutability.
Code that is hard to read is code whose bugs will not be found in time.

### V. Explicit Upgradeability & Access Control

Every contract MUST declare, in its NatSpec header, whether it is immutable or upgradeable and
why. Upgradeable contracts MUST use a well-known proxy standard (UUPS or Transparent), MUST
reserve storage gaps, MUST disable initializers on the implementation, and MUST have upgrade
authorization tested for bypass. Storage-layout compatibility MUST be verified mechanically
before any upgrade is deployed.

Privileges MUST be role-based and least-privilege — no single unbounded `owner` for a
value-holding contract. Every privileged action that can affect user funds MUST be behind a
multisig and, where it changes economic parameters or upgrades code, a timelock. Pause and
emergency-withdrawal powers MUST be narrowly scoped, documented, and tested from both the
authorized and unauthorized side.

**Rationale**: Most large losses are not exotic math bugs; they are a compromised key attached
to an unbounded privilege.

### VI. Arc Chain Deployment Discipline

The deployment target is the Arc chain, whose properties MUST be respected in code and tests:

- **Arc Testnet**: chain ID `5042002`, RPC `https://rpc.testnet.arc.io`, explorer
  `https://testnet.arcscan.app`, faucet `https://faucet.circle.com`.
- **Native gas token is USDC with 18 decimals**, not ETH. Any code, script, or UI assumption
  that the native token is ETH, or that gas is denominated in a valueless token, is a defect.
  Code that mixes native-token amounts with 6-decimal bridged USDC amounts MUST convert
  explicitly through a named constant, and the conversion MUST have a dedicated test.
- Contracts MUST NOT hardcode chain IDs, RPC URLs, or addresses in `src/`; these belong in
  deployment configuration and MUST be validated at deploy time against the expected network.
- Signature-verifying contracts MUST bind the Arc chain ID into the EIP-712 domain separator and
  MUST recompute it if the chain ID changes, with a cross-chain replay test proving it.
- Before any mainnet deployment, the exact commit MUST be deployed and exercised on Arc Testnet,
  including a rehearsal of the upgrade and emergency procedures.
- Solidity `evm_version` in `foundry.toml` MUST be set to a value Arc supports and MUST NOT be
  left at the toolchain default without verification against Arc's published EVM support.

**Rationale**: A USDC-denominated gas token changes the economics of griefing and the meaning of
every `msg.value` and decimal assumption. Chain-specific assumptions that are implicit become
production incidents.

### VII. Reproducible, Auditable Releases

Every deployment MUST be reproducible from a tagged commit: pinned `foundry.toml` solc version,
committed `foundry.lock`/submodule pins, and a deterministic `forge script` under `script/`.
Deployment artifacts — addresses, constructor arguments, transaction hashes, block numbers, the
deploying commit SHA, and verification status on the Arc explorer — MUST be committed to the
repository. Source verification on the block explorer is REQUIRED before a contract is announced
or handed any real value. No deployment is performed from an uncommitted working tree.

**Rationale**: An unverified contract of unknown provenance cannot be reviewed by anyone, which
forfeits the only meaningful security property a public chain offers.

## Security & Testing Requirements

**Toolchain (REQUIRED)**: Foundry (`forge`, `cast`, `anvil`) is the canonical build and test
toolchain. `slither` and `solhint` are required static analysis. Symbolic or formal tooling
(`halmos`, `certora`, or `forge`'s symbolic features) is REQUIRED for arithmetic-critical
components such as accounting, share/price math, and reward accrual.

**Test layout**: `test/unit/` for isolated behavior, `test/integration/` for multi-contract
flows, `test/invariant/` for stateful invariants, `test/fork/` for forked-Arc-testnet tests
against real deployed dependencies, and `test/attack/` for the adversarial scenarios of
Principle II. The `test/attack/` directory MUST NOT be empty for any contract that holds or
moves value.

**Definition of done for a contract**: threat model documented; unit, integration, fuzz,
invariant, and attack suites green; `forge coverage` >= 95% lines and branches; `slither` and
`solhint` clean or justified; `forge fmt --check` clean; gas snapshot committed; NatSpec
complete; deployment script and testnet rehearsal completed.

**External audit**: Any contract intended to hold third-party funds on Arc mainnet MUST undergo
an independent external audit, and every finding MUST be either fixed with a regression test or
formally accepted in writing with a documented rationale, before mainnet deployment.

**Dependencies**: Prefer audited, widely used libraries (OpenZeppelin, Solady) over bespoke
implementations of standard primitives. Dependencies MUST be pinned to an exact version or
commit; no floating branches. Adding a dependency requires a note in the PR on why a standard
library does not suffice.

**Secrets**: Private keys, mnemonics, and RPC API keys MUST NEVER be committed. Deployment keys
MUST come from a hardware wallet or an external signer; `--private-key` with a literal key is
prohibited outside local `anvil`.

## Development Workflow & Quality Gates

**Branching**: Work happens on feature branches. Direct pushes to the default branch are
prohibited. Every change reaches the default branch through a reviewed pull request.

**CI gates (blocking, no merge on failure)**:
1. `forge build` with warnings treated as errors
2. `forge fmt --check`
3. `forge test` including fuzz and invariant suites
4. `forge coverage` threshold check (>= 95% lines and branches on `src/`)
5. `slither` and `solhint`
6. `forge snapshot --check` — unexplained gas regressions block the merge

**Review**: At least one reviewer other than the author MUST approve. For any change to
value-handling logic, access control, or upgrade paths, at least two approvals are REQUIRED and
the review MUST explicitly confirm that the adversarial tests of Principle II cover the changed
surface. Reviewers verify constitutional compliance, not just correctness.

**Deployment approval**: Arc mainnet deployment requires a passing CI run on the exact tagged
commit, a completed testnet rehearsal, explorer verification, and multisig sign-off. Emergency
hotfixes may compress review but MUST NOT skip the regression test or the post-incident
retrospective.

## Governance

This constitution supersedes all other development practices, conventions, and preferences in
this repository. Where any other document, habit, or expedient conflicts with it, this document
governs.

**Amendment procedure**: Amendments are proposed as a pull request modifying this file. The PR
MUST state the rationale, the version bump and its justification, and the migration impact on
existing contracts and tests. Amendments require approval from the project maintainers and MUST
update the Sync Impact Report comment at the top of this file.

**Versioning policy**: This constitution follows semantic versioning.
- **MAJOR**: A principle is removed or redefined in a backward-incompatible way, or a governance
  rule is relaxed.
- **MINOR**: A principle or section is added, or existing guidance is materially expanded.
- **PATCH**: Clarifications, wording, and typo fixes that do not change obligations.

**Compliance review**: Every pull request is checked against this constitution during review, and
the maintainers conduct a full compliance review before each mainnet deployment. Any exception
MUST be time-boxed, recorded in the PR with an explicit rationale, and tracked to resolution;
undocumented exceptions are defects. Complexity that violates a principle MUST be justified in
writing or removed — "it was faster" is not a justification.

**Runtime guidance**: Agent- and contributor-facing operational guidance lives in `CLAUDE.md` at
the repository root; it MUST remain consistent with this constitution, which prevails on conflict.

**Version**: 1.0.0 | **Ratified**: 2026-09-03 | **Last Amended**: 2026-09-03

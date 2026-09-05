# Feature Specification: Fully Immutable Top-Up Router

**Feature Branch**: `003-simplify-immutable-router`

**Created**: 2026-09-05

**Status**: Draft

**Input**: User description: "Remove the feature that allows the treasury address to be changed. Remove the top-up pause functionality, change the decimals to 6, remove the need for MIN_TOPUP_WEI in the environment variables, and remove the 2-day delay for transferring the treasury address."

**Amended 2026-09-05**: "also just support native usdc no need another tokens for topup"

## Overview

The top-up router today is a mostly-immutable payment forwarder wrapped in a governance layer: a treasury address that can be re-pointed through a 2-day timelocked proposal, an emergency pauser that can halt top-ups, and a minimum top-up amount supplied at deployment time. This feature strips that governance layer away entirely. The destination of funds is fixed for the life of the deployment, top-ups can never be halted, no privileged role of any kind remains, and the deployment takes a single address. Amounts are expressed with 6 decimal places, matching how USDC is denominated everywhere else in the product.

The router accepts exactly one form of payment: native USDC, the chain's own currency, sent directly with the transaction. There is no support for any other token, and none will be added — a contributor holding some other asset converts it before topping up, outside this system.

The result is a contract whose entire behaviour is knowable from its deployment transaction: one currency in, one address out, forever, and no key holder can change either.

## Clarifications

### Session 2026-09-05

- Q: With `MIN_TOPUP_WEI` removed from deployment configuration, what happens to the minimum top-up rule itself? → A: Hardcode a fixed minimum permanently in the contract (Option A).
- Q: With treasury changes and the pauser both removed, does any privileged role survive? → A: No roles at all — the contract is fully immutable and ungoverned (Option A). No admin, no pauser, no timelock.
- Q: Is Arc's native USDC denominated with 6 decimals or 18? → A: 6. Confirmed 2026-09-05 against Arc documentation (`https://docs.getblock.io/api-reference/arc`), which states USDC is the native gas token with 6 decimals, "not 18 like most EVM chains", alongside the matching testnet chain ID `5042002`. Constitution Principle VI was factually wrong and has been amended (1.0.0 → 1.1.0).

### Session 2026-09-05 (post-analysis consistency pass)

- Q: Should FR-015 (no withdraw/sweep/rescue) and FR-016 (no upgrade path) be verified by test, or left to code review? → A: Verified by test. `/speckit-analyze` found FR-015 — the contract's central guarantee — was the only requirement with no test behind it. Task T013a added to probe withdraw/sweep/rescue/upgrade selectors.
- Q: Which vocabulary is canonical for amounts? → A: "whole USDC" and "base units". User Story 4 previously used "whole currency unit" and "smallest unit"; normalized.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Contributor tops up with a guaranteed destination (Priority: P1)

A contributor sends a top-up on behalf of themselves or another beneficiary. The funds are forwarded, in the same transaction, to the one treasury address that was fixed when the contract was deployed. The contributor can verify that destination before paying and knows it cannot be changed afterwards by anyone.

**Why this priority**: This is the product. Every other story exists only to support this one, and the removal of the treasury-change path is what makes the guarantee real.

**Independent Test**: Deploy with a known treasury, send top-ups from several accounts, and confirm each one lands at that treasury and is recorded against the correct beneficiary. Confirm no callable path exists that changes the destination.

**Acceptance Scenarios**:

1. **Given** a deployed router with treasury T, **When** a contributor sends a top-up of any accepted amount, **Then** the full amount arrives at T within the same transaction and a record naming payer, beneficiary, and amount is emitted.
2. **Given** a deployed router, **When** any account — including the deployer or any privileged role — attempts to change the treasury destination, **Then** no such operation exists and the destination remains T.
3. **Given** a deployed router with treasury T, **When** an observer reads the contract's published state at any point in its life, **Then** the treasury reads as T and matches the value in the deployment transaction.

---

### User Story 2 - Top-ups cannot be halted (Priority: P1)

Contributors can top up at any time for the life of the contract. No key holder can stop them, and there is no emergency-stop role to compromise, lose, or misuse.

**Why this priority**: Removing the pause is a change to the contract's core availability guarantee and is inseparable from the immutability promise in Story 1 — a pause is a de-facto change of behaviour by a key holder.

**Independent Test**: Confirm no pause, unpause, or paused-state surface exists; confirm top-ups succeed continuously across arbitrary block times and callers.

**Acceptance Scenarios**:

1. **Given** a deployed router, **When** any account attempts to halt or resume top-ups, **Then** no such operation exists and top-ups continue to be accepted.
2. **Given** a deployed router, **When** a contributor tops up at any time after deployment, **Then** the top-up is accepted on the same terms as the first one ever made.
3. **Given** a deployment, **When** the deployer supplies deployment parameters, **Then** no emergency-stop role is named or stored.

---

### User Story 3 - Operator deploys with fewer parameters (Priority: P2)

An operator deploying the router supplies only the parameters that still matter. The minimum-top-up amount and the emergency-stop role are no longer deployment inputs, and the deployment fails loudly if a required parameter is missing rather than deploying something subtly wrong.

**Why this priority**: Fewer parameters means fewer ways to misconfigure an immutable contract, but it delivers value only once Stories 1 and 2 define what the contract does.

**Independent Test**: Run a deployment with the reduced parameter set and confirm it succeeds; remove each required parameter in turn and confirm deployment is refused with a clear message.

**Acceptance Scenarios**:

1. **Given** deployment configuration containing only the still-required parameters, **When** the operator deploys, **Then** deployment succeeds and the deployed contract reports the configured treasury.
2. **Given** deployment configuration that still contains a now-removed parameter, **When** the operator deploys, **Then** the extra value is ignored and does not affect the deployed contract.
3. **Given** deployment configuration missing a required address, **When** the operator deploys, **Then** deployment is refused before any transaction is broadcast, with a message naming the missing parameter.

---

### User Story 4 - Amounts are read and reported in 6 decimal places (Priority: P2)

Everyone reading a top-up — a contributor checking a receipt, an operator reconciling the off-chain ledger, an auditor reading the running total — interprets amounts with 6 decimal places, so one whole USDC is one million base units.

**Why this priority**: A decimals mismatch silently misstates every amount by a factor of a trillion. It must be settled before any figure is trusted, but it changes interpretation and documentation rather than the flow of funds.

**Independent Test**: Top up an amount equal to one whole USDC and confirm every published figure, record, and document expresses it as 1,000,000 base units.

**Acceptance Scenarios**:

1. **Given** the 6-decimal denomination, **When** a contributor tops up one whole USDC, **Then** the recorded amount and the running total both reflect 1,000,000 base units.
2. **Given** operator-facing documentation and deployment configuration, **When** an operator reads any amount, **Then** it is stated in 6-decimal terms with no reference to an 18-decimal denomination.

---

### User Story 5 - Only native USDC is accepted (Priority: P1)

A contributor pays in native USDC and nothing else. The router has no concept of any other token: no token address is ever named, chosen, or configured, and no other asset can be routed, credited, or recorded. A contributor holding a different asset converts it to native USDC first, outside this system.

**Why this priority**: Single-currency is what keeps the contract small enough to be trustworthy without governance. Every multi-token mechanism — allowlists, per-token decimals, per-token minimums — would need an owner to maintain it, which Story 1 and the no-roles decision have deliberately removed.

**Independent Test**: Confirm the contract exposes no operation that names, accepts, or transfers any token other than the chain's native currency, and that the entire accepted-payment surface is the value attached to a top-up transaction.

**Acceptance Scenarios**:

1. **Given** a deployed router, **When** a contributor attaches native USDC to a top-up, **Then** it is accepted, credited, and forwarded under the existing rules.
2. **Given** a deployed router, **When** any party attempts to top up with, register, allowlist, or configure any token other than the native currency, **Then** no such operation exists and the attempt cannot be expressed against the contract.
3. **Given** a deployed router, **When** some other token is sent to the contract address directly by that token's own transfer mechanism, **Then** no contribution is recorded, no total is affected, and the contract's behaviour is unchanged — those tokens are permanently stranded, which is an accepted consequence.
4. **Given** operator documentation and deployment configuration, **When** an operator reads them, **Then** no token address parameter appears and native USDC is named as the only accepted currency.

---

### Edge Cases

- What happens when a top-up of zero is sent? It is rejected; the contract never records an empty contribution.
- What happens when the beneficiary is unspecified or empty? It is rejected rather than crediting a null party.
- What happens when the fixed treasury is a contract that refuses to accept the transfer? The top-up fails as a whole and the contributor keeps their funds; no partial credit is recorded. Because the treasury can no longer be changed, this condition is permanent, which raises the stakes on validating the treasury before deployment.
- What happens when a very small (dust) top-up is sent? It is rejected against the permanent 1,000,000-unit floor. Because that floor can never be changed, a future collapse or surge in the currency's value cannot be responded to except by deploying a replacement.
- What happens when a contributor sends some non-native token to the contract address? Nothing is credited and nothing can be recovered — there is no rescue operation, by design (FR-015). Documentation must warn contributors about this clearly, since the loss is permanent.
- What happens when funds are forced into the contract by means other than a top-up? They are not credited to anyone and no operation exists to retrieve them; the running total continues to reflect only routed top-ups.
- What happens if the treasury key is lost or compromised after deployment? There is no recovery path in the contract, and with no privileged roles there is no party who could intervene even in principle. The response is to stop directing contributors to this deployment and to deploy a replacement — this is an accepted consequence of the immutability guarantee.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST fix the treasury destination at deployment and MUST NOT expose any operation, callable by any party in any role, that changes it.
- **FR-002**: The system MUST remove the proposal, application, and cancellation flow for treasury changes, including its 2-day waiting period, so that no pending treasury change can exist.
- **FR-003**: The system MUST publish the fixed treasury address for public inspection at any time.
- **FR-004**: The system MUST NOT expose any operation that halts, suspends, or resumes top-ups, and MUST NOT define or store an emergency-stop role.
- **FR-005**: The system MUST accept top-ups on identical terms for the entire life of the deployment, with no state in which top-ups are refused for reasons other than the validation rules in FR-006 and FR-007.
- **FR-006**: The system MUST enforce a minimum accepted top-up of 1,000,000 base units — one whole USDC at Arc's confirmed 6-decimal native denomination — written permanently into the contract rather than supplied as deployment configuration, and MUST reject any top-up below it.
- **FR-007**: The system MUST reject a top-up whose amount is zero or whose beneficiary is unspecified, and MUST reject any top-up whose forwarding to the treasury does not fully succeed.
- **FR-008**: The system MUST forward the entire value of every accepted top-up to the treasury within the same transaction, retaining nothing.
- **FR-009**: The system MUST record, for every accepted top-up, the paying party, the credited beneficiary, and the amount, and MUST maintain a cumulative total of all amounts routed.
- **FR-010**: The system MUST express and document every amount using 6 decimal places, such that one whole USDC equals 1,000,000 base units. This is Arc's confirmed native denomination, not a product choice.
- **FR-011**: The system MUST NOT require a minimum-top-up value in deployment configuration, and deployment MUST succeed when that value is absent.
- **FR-012**: The system MUST NOT require any role address (administrator or emergency-stop) in deployment configuration, and deployment MUST succeed when those values are absent.
- **FR-013**: Deployment MUST be refused, before anything is broadcast, when a still-required address is missing or is the empty/zero address.
- **FR-014**: The system MUST define no privileged roles whatsoever. There is no administrator, no emergency-stop holder, and no party whose address grants any capability the general public does not have.
- **FR-014a**: The system MUST remove the entire timelocked-change mechanism — every propose, apply, and cancel operation, the pending-change records, and the 2-day waiting period itself — leaving no operation that waits on time.
- **FR-014b**: Deployment MUST require exactly one address, the treasury, and MUST NOT accept or store any role address.
- **FR-015**: The system MUST continue to expose no operation that withdraws, sweeps, rescues, or otherwise moves funds out of the contract to any party other than the fixed treasury via a top-up.
- **FR-016**: The system MUST remain immutable and non-upgradeable, with no proxy and no upgrade path.
- **FR-017a**: The system MUST accept payment only as native USDC — the value carried by the top-up transaction itself — and MUST NOT expose any operation that accepts, names, allowlists, configures, or transfers any other token.
- **FR-017b**: The system MUST NOT store, accept as configuration, or reference any token contract address for any purpose.
- **FR-017c**: Non-native tokens sent to the contract MUST have no effect on any recorded contribution or on the routed total, and MUST NOT be recoverable by any party, consistent with FR-015.
- **FR-018**: Operator-facing documentation and deployment configuration MUST be updated to remove every reference to changing the treasury, to the waiting period for that change, to the emergency-stop role, to the minimum-top-up deployment parameter, and to an 18-decimal denomination.

### Key Entities

- **Top-up**: A single payment in native USDC. Names a paying party, a credited beneficiary, and an amount in 6-decimal units. Immutable once recorded; forwarded in full at the moment it is accepted.
- **Treasury**: The single, permanent destination for every top-up. Fixed at deployment, publicly readable, never reassignable.
- **Routed total**: The cumulative sum of all accepted top-up amounts of native USDC, in 6-decimal units. Only ever increases.
- **Native USDC**: The chain's own currency and the sole accepted means of payment. Denominated with 6 decimal places. Not represented by any stored address or configuration value.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of accepted top-ups reach the deployment-time treasury address, with zero value retained by the router.
- **SC-002**: Zero operations exist, across every role and caller, that change the top-up destination or halt top-ups — verified by exhaustive review of the contract's callable surface.
- **SC-003**: A contributor or auditor can confirm the permanent destination of funds from published contract state in a single read, with no knowledge of pending proposals required.
- **SC-004**: The contract's callable surface and the deployment parameter list are both strictly smaller than the previous version, with no capability added.
- **SC-004a**: Zero addresses stored by the contract confer any privilege: every callable operation behaves identically no matter who calls it, verified by exercising the full surface from an arbitrary unprivileged account.
- **SC-005**: Every amount shown in contract records, published totals, and operator documentation is consistent with 6-decimal denomination — zero remaining references to an 18-decimal denomination in operator-facing material.
- **SC-006**: Deployment succeeds with the reduced configuration on the first attempt for an operator following the documentation, and is refused with an actionable message for every missing required value.
- **SC-007**: Adversarial testing confirms that no sequence of calls by any party, at any time, results in a changed destination, a halted top-up, or value leaving the contract to a non-treasury address.
- **SC-008**: Exactly one currency is accepted: a review of the contract's full callable surface finds zero operations that reference any token other than the native currency, and zero token addresses among stored state or deployment parameters.

## Assumptions

- The existing top-up flow — per-beneficiary crediting, same-transaction forwarding, and the running total — is retained unchanged apart from the denomination of amounts.
- The change is delivered as a new deployment of a new contract. The currently deployed router is immutable and unaffected; migration of contributors to the new address is an operational task outside this specification.
- The 6-decimal denomination matches native USDC on the target chain, so native and bridged USDC share one scale and no conversion or scaling is introduced by this feature.
- Native USDC is the chain's gas currency as well as the payment currency, so a contributor able to send a transaction already holds the only asset needed to top up.
- Supporting additional tokens is permanently out of scope for this deployment, not deferred. Should it ever be wanted, it is a different contract at a different address.
- Removing the emergency stop is a deliberate, accepted trade-off: incident response for this deployment is limited to ceasing to direct contributors to it and deploying a replacement.
- The treasury address is validated off-chain before deployment, since an incorrect value is permanent and unrecoverable.
- The permanent minimum of one whole USDC (1,000,000 base units) was chosen for this specification rather than supplied by the requester, and is unchangeable after deployment. The requester was informed and did not revise it.
- Arc's 6-decimal native denomination is confirmed, not assumed (see Clarifications). A consequence outside this feature's scope: the already-deployed 002 router carries a minimum of `1e18` base units — one trillion USDC — so it can accept no reachable top-up and is non-functional. It must not be advertised or handed value, and its minimum is immutable, so the 003 redeployment is the only remedy.
- Existing recorded contribution data and its off-chain ledger integration keep their current shape; only the interpretation of amount magnitudes changes.

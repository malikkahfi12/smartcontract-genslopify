# Specification Quality Checklist: Treasury Multi-Sig Governance with 2-Day Timelock

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-09-04
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

**Status: 16/16 PASS — ready for `/speckit-plan`.**

## Notes

**Iteration 1 (2026-09-04)** — fixes applied during validation:

- An early draft named a specific multi-signature wallet product as the assumed authority. Removed;
  the spec now describes the authority by its properties, and the choice of form is Q1.
- "Timelock" was used as a requirement term in several places. Replaced with "waiting period"
  throughout the requirements and scenarios so the spec reads for non-technical stakeholders; the
  term survives only in the feature title, where it is the recognised name for the control.
- Initial draft treated the 2-day delay as applying only to treasury rotation. Added FR-017 and
  Q1 after noting the gap: if transferring administrative authority is *not* also delayed, an
  attacker who compromises the authority can transfer it to themselves instantly and then rotate
  the treasury, and the two-day protection on rotation is worth nothing. This is the single most
  consequential open question in the spec.
- Added FR-008 and Q2 for the same class of reason — a delay that administrators can shorten does
  not constrain administrators.
- Added the "quorum becomes unreachable" edge case and FR-015 after tracing the consequence of
  immutable code (001 FR-018): losing quorum permanently freezes the treasury address with no
  recovery.
- SC-009 added to make the single-key window measurable rather than an open-ended intention.

**Iteration 2 (2026-09-04)** — clarifications Q1:A, Q2:A, Q3:A resolved; all markers removed.
The user selected the strictest option on all three. Consequences propagated:

- *Q1 (uniform 2-day delay on authority transfer)*: This changed User Story 4 materially. The
  initial handover from the primary key to the multisig is itself an authority transfer, so it now
  waits two days like everything else — it is not a one-time exemption. Added FR-023a and two
  acceptance scenarios covering the pending handover and its cancellation, plus SC-005a and SC-010
  asserting no route produces a sub-48-hour effect. Added an edge case for a handover proposed to a
  wrong or unready multisig, which is recoverable only inside that window.
- *Q2 (permanently fixed delay)*: FR-008 now forbids changing the period in either direction, not
  merely shortening it. Stated that altering it requires redeployment.
- *Q3 (one-way single-key exit)*: FR-023 states the transition is permanent; SC-005 extended to
  assert no sequence restores single-key authority.
- *Combined consequence — flagged deliberately*: Q1+Q2+Q3 together with 001's code immutability
  leave the system with no escape hatch of any kind. The "quorum becomes unreachable" edge case was
  rewritten from a general caution into an explicit **accepted terminal risk**: if quorum is lost,
  the treasury address freezes forever, top-ups keep routing to it, and the system cannot even be
  paused. Each choice is individually sound; their combination shifts risk decisively onto signer
  key custody and the correctness of the handover address. Recorded in Assumptions so it is a
  decision on record rather than a discovery made later.

**Relationship to 001**: This spec supersedes 001's FR-019, FR-020, FR-022, and FR-023. Feature
001 remains authoritative for everything else; FR-031 and FR-032 here restate its no-withdrawal
and code-immutability guarantees as explicit constraints on this feature so that governance work
cannot erode them. Once Q1–Q3 are resolved, 001's superseded requirements should be updated to
reference this spec — that reconciliation is tracked as a follow-up, not done silently.

Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`.

**Iteration 3 (2026-09-04)** — `/speckit-clarify` session, scope narrowed to Arc testnet. Five
questions asked and integrated. Re-validated all 16 items against the updated spec: **16/16 still
pass, no regressions.** Notable effects:

- FR-008 strengthened and FR-008a added: the delay must be a compile-time constant, not a
  constructor parameter, so testnet and mainnet share identical bytecode (Q1 → A). This closed a
  loophole the earlier wording left open — "cannot be changed by any party" did not explicitly
  exclude *deployment configuration*.
- New "Scope Boundary: Testnet Only" section records what is deferred (external audit, live
  handover rehearsal, mainnet parameters) versus what is explicitly not relaxed (coverage gate,
  full attack suite, invariants, fixed delay, no-withdrawal). Keeps "testnet scope" from silently
  becoming "lower bar".
- Three residual gaps are now recorded rather than implicit, each the accepted consequence of a
  deliberate choice: no live handover rehearsal (Q2 → B), no live contract-recipient treasury path
  (Q5 → B), and no external audit in scope (Q4 → A). All three remain covered by automated tests;
  what they lack is live exercise.
- "Scope is clearly bounded" moved from passing-by-inference to explicitly documented.

**Downstream artifacts now stale** — not edited by this command, listed for follow-up: `plan.md`
(Technical Context, Constitution Check, Complexity Tracking), `tasks.md` (T082 should move to
Phase 1; T083–T085 need rescoping), `research.md` (R-005 verification timing), `quickstart.md`
(open item and deployment sections).

# Static analysis exceptions

Constitution Principle IV requires every suppressed finding to carry a justification. JSON config
files cannot hold comments, so the rules disabled in `.solhint.json` are recorded here.

| Rule | State | Justification |
|---|---|---|
| `avoid-low-level-calls` | off | The treasury payout MUST use `treasury.call{value: ...}("")`. `transfer`/`send` forward only 2300 gas and break for a contract treasury — including a Safe, which is the intended production treasury (research R-006). The reentrancy risk is closed by CEI ordering plus `nonReentrant`, not by starving the callee of gas. The return value IS checked (`check-send-result` stays on). |
| `avoid-call-value` | off | Same rationale as `avoid-low-level-calls`; this is the payment path itself, not an incidental call. |
| `reason-string` | off | Superseded by `custom-errors: error`, which is strictly stronger — the codebase uses custom errors exclusively. |

| `import-path-check` | off | Cannot resolve Foundry remappings (`@openzeppelin/contracts/=lib/...`), so it reports every remapped import as missing. `forge build` resolves them correctly, which is the authoritative check. |
| `custom-errors` | removed | The rule does not exist in solhint 5 (it warns "Rule 'custom-errors' doesn't exist"). The intent — custom errors instead of revert strings — is enforced by review and holds in practice: `src/TopUpRouter.sol` declares 6 custom errors and contains zero `require`/`revert` strings. |

Rules deliberately kept ON that are worth noting: `custom-errors`, `check-send-result`,
`avoid-tx-origin`, `reentrancy`, `no-inline-assembly`, `state-visibility`, `one-contract-per-file`.

`slither.config.json` sets `fail_on: medium` and excludes no severity level. `exclude_dependencies`
is true because OpenZeppelin v5.1.0 is audited upstream and its findings are not actionable here;
our own code is not excluded.

## Removed in spec 003

`not-rely-on-time` was turned back **on**. It was disabled for the 2-day timelock, which measured
elapsed time with `block.timestamp`. Spec 003 removed the timelock entirely, so no code in `src/`
reads the clock and the rule has nothing left to fire on. Leaving it disabled would have left a
standing permission for time-dependent code to be added later without review.

Suppressions deleted from `src/TopUpRouter.sol` along with the governance engine, for the same
reason — the findings no longer exist rather than being silenced:

| Suppression | Was for |
|---|---|
| `uninitialized-state` (slither + forge-lint) | The three pending-change storage slots |
| `unsafe-typecast` (forge-lint) | The `uint64` cast on a proposal's eta |
| `block-timestamp` / `timestamp` | The eta comparison in `_applyPending` |
| `naming-convention` (slither) | `MIN_TOPUP` as an immutable; it is a `constant` now, which is the convention the rule expects |

One suppression was **added**: `screaming-snake-case-immutable` / `naming-convention` on
`treasury`, which became `immutable` in spec 003. The linters want `TREASURY`. Rejected, and the
reasoning differs from the `MIN_TOPUP` case above: `treasury` is part of the published interface.
It generates the `treasury()` getter that integrators, the explorer, and the off-chain ledger
already call, and it matches the `treasury` field of the `ToppedUp` event. Renaming it would break
every consumer to satisfy a style rule about a storage classification they cannot observe.

`forge lint src/` is otherwise clean apart from the informational `low-level-calls` note on the
payment path, which carries the same justification as the `avoid-low-level-calls` row above.

One suppression was **rewritten rather than removed**: `arbitrary-send-eth` in `_topUp`. Its old
justification argued the destination was safe because it could only change through a
quorum-approved proposal serving a 2-day delay. That reasoning no longer exists. The replacement
is stronger: `treasury` is `immutable` and has no setter at any visibility, so the destination
cannot change at all.

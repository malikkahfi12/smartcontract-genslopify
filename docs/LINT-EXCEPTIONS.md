# Static analysis exceptions

Constitution Principle IV requires every suppressed finding to carry a justification. JSON config
files cannot hold comments, so the rules disabled in `.solhint.json` are recorded here.

| Rule | State | Justification |
|---|---|---|
| `avoid-low-level-calls` | off | The treasury payout MUST use `treasury.call{value: ...}("")`. `transfer`/`send` forward only 2300 gas and break for a contract treasury — including a Safe, which is the intended production treasury (research R-006). The reentrancy risk is closed by CEI ordering plus `nonReentrant`, not by starving the callee of gas. The return value IS checked (`check-send-result` stays on). |
| `not-rely-on-time` | off | The 2-day waiting period is measured with `block.timestamp` by design. Timestamps are manipulable by roughly seconds; against a 172,800-second delay that is immaterial. A block-count delay was rejected because Arc's block time is not guaranteed stable, so it would not reliably mean two days (research R-007). |
| `avoid-call-value` | off | Same rationale as `avoid-low-level-calls`; this is the payment path itself, not an incidental call. |
| `reason-string` | off | Superseded by `custom-errors: error`, which is strictly stronger — the codebase uses custom errors exclusively (contracts/ITopUpRouter.md). |

| `import-path-check` | off | Cannot resolve Foundry remappings (`@openzeppelin/contracts/=lib/...`), so it reports every remapped import as missing. `forge build` resolves them correctly, which is the authoritative check. |
| `custom-errors` | removed | The rule does not exist in solhint 5 (it warns "Rule 'custom-errors' doesn't exist"). The intent — custom errors instead of revert strings — is enforced by review and holds in practice: `src/TopUpRouter.sol` declares 11 custom errors and contains zero `require`/`revert` strings. |

Rules deliberately kept ON that are worth noting: `custom-errors`, `check-send-result`,
`avoid-tx-origin`, `reentrancy`, `no-inline-assembly`, `state-visibility`, `one-contract-per-file`.

`slither.config.json` sets `fail_on: medium` and excludes no severity level. `exclude_dependencies`
is true because OpenZeppelin v5.1.0 is audited upstream and its findings are not actionable here;
our own code is not excluded.

# Quickstart & Validation Guide: TopUpRouter

**Date**: 2026-09-04 | **Plan**: [plan.md](./plan.md)

How to build, validate, deploy, and hand over. Every gate below is blocking per constitution
"Development Workflow & Quality Gates".

## Prerequisites

- Foundry (`forge`, `cast`, `anvil`) — pinned via `foundry.toml`
- `slither` and `solhint`
- `halmos` (for the accounting identity in R-001/INV-1)
- A funded Arc testnet account — faucet: <https://faucet.circle.com>
- A hardware wallet or external signer for any deployment. **Never** `--private-key` with a literal
  key outside local `anvil` (constitution, Secrets).

## Setup

```bash
forge install
forge build
```

`foundry.toml` must pin `solc = "0.8.28"`, set `evm_version = "paris"` (see the open item below),
and configure `fuzz.runs = 10000` and an `invariant` profile, per constitution Principle II.

## Validation gates

Run in order; each is blocking.

```bash
forge fmt --check                 # 1. formatting
forge build --deny-warnings       # 2. warnings are errors
forge test                        # 3. all suites incl. fuzz + invariant
forge coverage --report summary   # 4. must be >=95% lines AND branches on src/
slither . && solhint 'src/**/*.sol'  # 5. static analysis clean or justified inline
forge snapshot --check            # 6. no unexplained gas regression
```

### Targeted runs

```bash
forge test --match-path 'test/attack/*'          # the adversarial suite
forge test --match-path 'test/invariant/*' -vvv  # stateful invariants
halmos --function check_accounting               # symbolic proof of INV-1
```

## What the attack suite must prove

Each file asserts that an exploit **fails**. This is the constitution Principle II gate; a passing
run means every scenario below was attempted and rejected.

| File | Scenarios |
|---|---|
| `Reentrancy.t.sol` | Malicious treasury re-enters `topUp` on receive; asserts the guard holds, no double credit, and accounting stays consistent |
| `AccessControl.t.sol` | Every governance function called by: a random EOA, the `pauser`, the *previous* admin after handover, and the beneficiary. All revert. |
| `TimelockBypass.t.sol` | Apply at `eta - 1` (must fail) and at exactly `eta` (must succeed); apply a cancelled change; re-propose and confirm the clock **restarts** rather than inheriting elapsed time; **the authority-swap bypass** — compromise `admin`, attempt to transfer authority and rotate treasury in under 2 days |
| `ForcedBalance.t.sol` | `selfdestruct` funds into the router, then assert `totalRouted`, `contributions`, and every subsequent `topUp` are unaffected (INV-9) |
| `DoSGriefing.t.sol` | Treasury that reverts on receive; treasury that burns all forwarded gas; repeated propose/cancel churn. Asserts failures are clean and no state is corrupted. |
| `Arithmetic.t.sol` | `msg.value` of 0, 1 wei, `MIN_TOPUP - 1`, `MIN_TOPUP`, `type(uint256).max` boundaries on totals |

`TimelockBypass.t.sol`'s authority-swap case is the single most important test in the suite — it is
the attack that motivated 002 FR-017. If the 2-day delay did not also cover authority transfer, an
attacker with `admin` would bypass it entirely.

**Not applicable (documented, not skipped)**: ERC-20 classes — fee-on-transfer, rebasing, missing
return values, double-entry tokens — cannot occur because the payment asset is native (001 FR-031,
research R-002). Signature classes — replay, malleability — cannot occur because the contract
verifies no signatures (research R-002). Their absence is a design property, recorded here so a
reviewer can confirm the omission is reasoned rather than forgotten.

## End-to-end validation (`test/integration/GovernanceLifecycle.t.sol`)

Proves the full intended operational path in one test:

1. Deploy with a single primary key as `admin` → assert `multisigEstablished == false`
2. A user tops up → treasury receives the exact amount, event carries the right `newTotal`
3. Primary key proposes handover to a multisig → assert it is **not** effective yet
4. Warp 2 days − 1 s → apply must revert
5. Warp to `eta` → apply succeeds; `multisigEstablished == true`; the **primary key can no longer
   act**
6. Attempt to transfer authority back to an EOA → must revert (one-way)
7. Multisig proposes a treasury rotation → visible as pending for 2 days, cancellable
8. `pauser` pauses immediately → top-ups revert, governance still works
9. Assert INV-1 and INV-8 hold throughout

## Deployment (Arc testnet)

```bash
forge script script/Deploy.s.sol \
  --rpc-url https://rpc.testnet.arc.io \
  --broadcast --verify --verifier-url https://testnet.arcscan.app/api
```

Constructor takes `treasury`, `admin` (the primary key), `pauser`, and `MIN_TOPUP`. No chain IDs or
addresses are hardcoded in `src/` (constitution Principle VI); the script validates it is on chain
`5042002` before broadcasting.

**Post-deploy, before announcing or accepting real value:**
- Verify source on the explorer — required by Principle VII
- Commit deployment artifacts: address, constructor args, tx hash, block number, commit SHA
- Confirm `DELAY() == 172800` and `treasury()` on-chain
- Sanity-check a small top-up end to end and confirm the event decodes correctly

## Handover to the multisig

Because authority transfer is itself timelocked (002 FR-017), the handover takes 2 days. Plan for
it:

```bash
forge script script/ProposeHandover.s.sol --rpc-url <arc> --broadcast   # day 0
# wait 2 days (172,800 s) — the pending change is publicly visible throughout
cast send <router> "applyAdmin()" --rpc-url <arc>                       # day 2, anyone may call
cast call <router> "multisigEstablished()(bool)" --rpc-url <arc>        # must return true
```

**During those two days the contract is under single-key control.** That is the deviation recorded
in plan.md Complexity Tracking. Close it promptly and record the actual window duration
(002 SC-009).

## Open item before mainnet

**Arc's supported EVM version is unverified.** The Arc docs publish chain ID, RPC, explorer, and the
USDC gas token, but not the EVM version. `evm_version = "paris"` is set as a conservative default
(research R-005). Before mainnet, confirm Arc's support — by documentation or by deploying a probe
to testnet — and either keep `paris` deliberately or raise it deliberately. Constitution Principle
VI forbids leaving this to a toolchain default. This is a blocking pre-mainnet task, and it is the
only unresolved technical unknown in the plan.

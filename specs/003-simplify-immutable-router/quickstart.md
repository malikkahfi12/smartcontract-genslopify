# Quickstart & Validation: Fully Immutable Top-Up Router

**Feature**: `003-simplify-immutable-router` | **Date**: 2026-09-05

How to prove this feature is correct and complete. Run in order.

## Prerequisites

- Foundry (`forge`, `cast`) with solc 0.8.28 per `foundry.toml`
- `halmos` for the symbolic accounting suite
- `slither` and `solhint`
- `.env` with `ARC_TESTNET_RPC` set; a keystore account imported via `cast wallet import`

## Step 0 — Decimals (RESOLVED — sanity check only)

Arc's native USDC has **6 decimals**: one whole USDC = `1e6` base units, confirmed against Arc documentation (R-001). `MIN_TOPUP` is `1e6`. Constitution Principle VI has been amended to match (1.1.0).

A one-command sanity check before deploying, since the value is permanent:

```bash
# Fund a fresh address from https://faucet.circle.com, noting the whole-USDC amount granted.
cast balance <funded-address> --rpc-url $ARC_TESTNET_RPC
```

**Expected**: base units ≈ whole USDC × 10^6. A result near 10^18 would contradict the documentation and must stop the deployment.

**Guard against the 002 defect recurring**: the old router's `MIN_TOPUP = 1e18` passed every test because the tests used `1e18` for both the minimum and the amounts — internally consistent at the wrong scale. Tie at least one fork-test amount to a faucet-funded balance rather than a literal, so the chain's own denomination participates in the assertion.

```bash
grep -rnE "1e18|000000000000000000" src/ script/ test/ .env.example
```

**Expected after implementation**: no hits in a native-amount position.

## Step 1 — Build and format

```bash
forge build          # warnings are errors (foundry.toml deny = "warnings")
forge fmt --check
```

**Expected**: clean. The build should also surface fewer lint suppressions than before — several disappear with the pending-change engine (R-004).

## Step 2 — The full suite

```bash
forge test
```

**Expected**: green, with these suites gone entirely — `TreasuryRotation`, `AuthorityTransfer`, `PauseControl`, `PauserRotation`, `TimelockBypass`, `GovernanceLifecycle`, `GovernanceInvariant`. Their absence is correct; they test features that no longer exist.

Surviving suites must pass unmodified in substance: `Reentrancy`, `Arithmetic`, `DoSGriefing`, `ForcedBalance`, `Accounting`, `TopUp`, `AccountingInvariant`, `AccountingSymbolic`.

## Step 3 — Prove the removed surface is absent

```bash
forge test --match-path test/unit/Immutability.t.sol -vv
```

**Expected**: every probed selector reverts as unrecognised — not "reverts with `NotAdmin`", which would mean the function still exists. Selectors listed in `contracts/TopUpRouter.abi.md` under "Absent by design".

```bash
forge inspect TopUpRouter abi | jq -r '.[].name' | sort
```

**Expected**: exactly `topUp`, `topUpSelf`, `treasury`, `MIN_TOPUP`, `totalRouted`, `contributions`, `ToppedUp`, the six declared errors, and the inherited `ReentrancyGuardReentrantCall`. Nothing else. Compare against `contracts/TopUpRouter.abi.md`; any extra entry is a spec violation (SC-002).

## Step 4 — Prove no caller is privileged

```bash
forge test --match-path test/attack/AccessControl.t.sol -vv
```

**Expected**: exercising the entire surface from an arbitrary unprivileged address produces results identical to any other caller (SC-004a). There is no address whose behaviour differs.

## Step 5 — Coverage and static analysis

```bash
forge coverage --report summary    # >= 95% lines and branches on src/
slither . && solhint 'src/**/*.sol' && forge lint src/
```

**Expected**: clean, and with a shorter `docs/LINT-EXCEPTIONS.md` than before. Suppressions removed with the governance engine must be deleted from that file, not left stale. The `arbitrary-send-eth` justification in `_topUp` must be rewritten — its current text reasons from the 2-day timelock, which no longer exists (R-004).

## Step 6 — Gas

```bash
forge snapshot --check
```

**Expected**: `topUp` cheaper than the 002 baseline — one fewer SLOAD from `whenNotPaused`, and `MIN_TOPUP` read from bytecode rather than an immutable slot. Commit the new snapshot with the diff in the PR (Principle IV).

## Step 7 — Fork rehearsal on Arc testnet

```bash
forge test --match-path test/fork/ArcTestnet.t.sol --fork-url $ARC_TESTNET_RPC -vv
```

**Expected**: a top-up routes end-to-end against the live chain at the `1e6` scale. All `1e18` literals in this file must be rescaled to `1e6` as part of the change.

## Step 8 — Deployment

```bash
forge script script/Deploy.s.sol \
  --rpc-url $ARC_TESTNET_RPC \
  --account arc-deployer --sender $DEPLOYER_ADDRESS \
  --broadcast --verify --verifier blockscout
```

**Expected**: succeeds with `TREASURY_ADDRESS` as the only parameter. Verify these negative cases first, before broadcasting anything:

- `TREASURY_ADDRESS` unset or zero → refused pre-broadcast, naming the parameter (FR-013)
- Wrong network → `WrongNetwork`
- `MIN_TOPUP_WEI` and `PAUSER_ADDRESS` still present in `.env` → ignored entirely, no effect on the deployed contract (FR-011, FR-012, US3 scenario 2)

**Validate the treasury address with extreme care.** It can never be changed, by anyone, and a treasury that reverts on receipt makes every future top-up fail permanently. Send a test top-up and confirm receipt before announcing the address.

## Step 9 — Post-deployment confirmation

```bash
cast call <router> "treasury()(address)"    --rpc-url $ARC_TESTNET_RPC
cast call <router> "MIN_TOPUP()(uint256)"   --rpc-url $ARC_TESTNET_RPC
cast call <router> "paused()(bool)"         --rpc-url $ARC_TESTNET_RPC  # MUST fail
cast call <router> "admin()(address)"       --rpc-url $ARC_TESTNET_RPC  # MUST fail
```

**Expected**: the first two return the deployed values; the last two fail against the live contract, confirming on-chain what Step 3 proved locally.

Then commit the deployment record to `docs/deployments/arc-testnet-v2.md` — address, constructor args, tx hash, block, commit SHA, verification status (Principle VII). Leave `docs/deployments/arc-testnet.md` intact as history; add only a forward-pointer.

## Step 10 — Documentation

Confirm no operator-facing file still references a changeable treasury, the 2-day delay, the pauser, `MIN_TOPUP_WEI`, or an 18-decimal denomination (FR-018) — and that `README.md` and `docs/DEPLOYMENT.md` both warn that non-native tokens sent to the contract are permanently unrecoverable (FR-017c).

```bash
grep -rniE "pauser|MIN_TOPUP_WEI|2 days|2-day|18 decimal|proposeTreasury|handover" \
  README.md docs/DEPLOYMENT.md docs/OPERATIONS.md .env.example
```

**Expected**: no hits outside `docs/deployments/arc-testnet.md`, which is history and stays as-is.

## Step 11 — Retire the 002 deployment

Fallout from R-001, not part of the contract change but shipping with it:

1. Add a dated erratum to `docs/deployments/arc-testnet.md`: its "1 USDC, 18 decimals" annotation is wrong, and at the true 6-decimal scale that router's `MIN_TOPUP` of `1e18` is one trillion USDC, so it can accept no reachable top-up. Append the erratum; do not rewrite the record.
2. Point it forward to `arc-testnet-v2.md`.
3. Confirm the 002 address is not advertised as usable anywhere in `README.md` or the docs.

The old router still has a working pauser, so it can be paused if you want the dead address to fail loudly rather than silently. That is an operational call — and the last time this option will be available, since the new router can never be paused.

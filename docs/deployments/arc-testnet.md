# Deployment record — Arc testnet

> **Current deployment: `0xd1040c76f7834863c0e971446016e3ad219e5cb0`** (block 60333969).
> The first deployment at `0x9B071Fefcc9aa81C7c6Cbe1B4f33840e83120B0C` is **superseded** — kept
> below for history. Both were verified; both carry identical bytecode. The redeploy changed only
> the constructor's `initialAdmin`.

Constitution Principle VII: every deployment must be reproducible from a tagged commit, with
artifacts committed. This is that record.

## Current deployment (2026-09-04, supersedes the one below)

| Field | Value |
|---|---|
| Address | [`0xd1040c76f7834863c0e971446016e3ad219e5cb0`](https://testnet.arcscan.app/address/0xd1040c76f7834863c0e971446016e3ad219e5cb0) |
| Block | `60333969` |
| Verified | yes, Blockscout |
| `admin` | `0xcB33f21889B2939363F4B39eC0e461B3C776F157` — **the deployer key**, held in the `arc-deployer` keystore |
| `pauser` | `0x76d0e18b3d94A86c6476eAE3103Eb5278E5128B9` |
| `treasury` | `0x7f78be80203bcEcF4d0897c5fFa782d02BEC3ACC` |
| `MIN_TOPUP` | `1000000000000000000` |
| `multisigEstablished` | `false` |
| `totalRouted` | `0` |

Bytecode is byte-for-byte identical to the superseded deployment, confirmed by comparing
`eth_getCode` on both — so the code, including the admin-handover functions, is unchanged. Only
`initialAdmin` differs.

**Why this matters operationally**: admin is now a key in the Foundry keystore rather than an
external wallet, so `docs/OPERATIONS.md` governance commands can be run with
`--account arc-deployer`. `admin != pauser` still holds, so the deploy script's guardrail passed.

Broadcast receipt: `broadcast/Deploy.s.sol/5042002/run-1788485256699.json`.

## Superseded deployment (first attempt)

| Field | Value |
|---|---|
| Contract | `TopUpRouter` |
| Address | [`0x9B071Fefcc9aa81C7c6Cbe1B4f33840e83120B0C`](https://testnet.arcscan.app/address/0x9B071Fefcc9aa81C7c6Cbe1B4f33840e83120B0C) |
| Network | Arc testnet, chain id `5042002` |
| Tx hash | `0xe18265dcde5a58b334dcc3c0690730291559a7c5d41dee9dd76131394a906a20` |
| Block | `60321987` |
| Gas used | `1,240,304` |
| Status | success (`0x1`) |
| Deployer | `0xcb33f21889b2939363f4b39ec0e461b3c776f157` |
| Date | 2026-09-04 |
| Commit SHA | **not recorded — see "Open gap" below** |

## Constructor arguments

| Parameter | Value |
|---|---|
| `initialTreasury` | `0x7f78be80203bcEcF4d0897c5fFa782d02BEC3ACC` |
| `initialAdmin` | `0xbeDF36Ba55790c9a7B4205469cD81F41360904ea` |
| `initialPauser` | `0x76d0e18b3d94A86c6476eAE3103Eb5278E5128B9` |
| `minTopUp` | `1000000000000000000` (1 USDC, 18 decimals) |

ABI-encoded:

```
0x0000000000000000000000007f78be80203bcecf4d0897c5ffa782d02bec3acc
  000000000000000000000000bedf36ba55790c9a7b4205469cd81f41360904ea
  00000000000000000000000076d0e18b3d94a86c6476eae3103eb5278e5128b9
  0000000000000000000000000000000000000000000000000de0b6b3a7640000
```

Note the deployer is a **different key** from `initialAdmin`. That is deliberate and preferable:
the deployer only pays gas and holds no authority over the contract afterwards.

## Compiler settings actually used

| Setting | Value |
|---|---|
| solc | `0.8.28+commit.7893614a` |
| `evm_version` | `cancun` (confirmed supported on Arc testnet by opcode probe, T082) |
| optimizer | enabled, `10000` runs |
| `via_ir` | false |
| `bytecode_hash` | `none` |
| `cbor_metadata` | false |

## Bytecode match evidence

Before verifying, the locally compiled `deployedBytecode` was diffed against the on-chain code:

- Both 5,036 bytes.
- **30 differing nibbles**, every one inside the three `immutableReferences` windows
  (bytes 1280, 3375, 3460 — 32 bytes each).
- The differing value is `0xde0b6b3a7640000` = `1e18` = the `MIN_TOPUP` immutable, which is baked
  into deployed bytecode but a zero placeholder in the artifact.

So the committed source reproduces the deployed contract exactly, modulo an immutable.

## Verification

**Verified on Blockscout**, 2026-09-04:
<https://testnet.arcscan.app/address/0x9B071Fefcc9aa81C7c6Cbe1B4f33840e83120B0C#code>

```bash
forge verify-contract 0x9B071Fefcc9aa81C7c6Cbe1B4f33840e83120B0C \
  src/TopUpRouter.sol:TopUpRouter \
  --verifier blockscout \
  --verifier-url https://testnet.arcscan.app/api \
  --chain-id 5042002 \
  --constructor-args <encoded args above> \
  --watch
```

### Partial vs full verification — read this

Blockscout reports `is_verified: true` but **`is_partially_verified: true`, not fully verified**.

That is expected and not a defect. Full verification requires the compiler metadata hash appended
to the bytecode to match. `foundry.toml` sets `bytecode_hash = "none"` and `cbor_metadata = false`
deliberately, for reproducible builds — so there is no metadata hash to compare, and Blockscout
can only assert a partial match.

What partial verification still gives you, which is what actually matters here: the source is
published, and it compiles to the deployed runtime bytecode. The stronger evidence is the byte-level
diff above, which anyone can reproduce with `forge build` and `eth_getCode`.

Changing `bytecode_hash` to get a "full" badge would make builds less reproducible. Not worth it.

## Post-deployment state (read from chain)

| Getter | Value |
|---|---|
| `DELAY()` | `172800` (2 days) |
| `treasury()` | `0x7f78be80203bcEcF4d0897c5fFa782d02BEC3ACC` |
| `admin()` | `0xbeDF36Ba55790c9a7B4205469cD81F41360904ea` |
| `pauser()` | `0x76d0e18b3d94A86c6476eAE3103Eb5278E5128B9` |
| `MIN_TOPUP()` | `1000000000000000000` |
| `multisigEstablished()` | `false` |
| `totalRouted()` | `0` |

`admin != pauser`, confirming the deploy script's guardrail held.

## Open gap — commit SHA not recorded

The repository has **no git commits** (`git rev-parse HEAD` fails), so this deployment cannot be
tied to a commit SHA as Principle VII requires. The working tree that produced it is the one
present at the time of writing, but that is not a durable reference.

**To close this**: commit the tree and tag it, then add the SHA to the table above. Until then,
reproducibility rests on the bytecode-match evidence rather than on provenance.

## Outstanding

`multisigEstablished()` is `false`. The contract is under **single-key governance**, which is the
system's weakest state — that key can redirect every future top-up after a 2-day delay. Closing the
window is Runbook 2 in `docs/OPERATIONS.md` and itself takes 2 days.

Record the window duration when it closes (spec 002 SC-009, task T088).

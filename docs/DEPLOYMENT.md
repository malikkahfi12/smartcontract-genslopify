# Deploying TopUpRouter to Arc testnet

From an empty machine to a verified contract. Every command here has been checked against the
installed Foundry version.

## How signing actually works here

**The wallet is not configured in `.env`.** `script/Deploy.s.sol` calls `vm.startBroadcast()` with
no argument, which means "sign with whatever signer the CLI provides". So:

- `.env` holds the **constructor parameter** — the treasury address. That is the only one.
- The **wallet** comes from a command-line flag (or its equivalent environment variable).

Key material never goes in `.env`. What goes there is the *name* of a keystore account and the
address it corresponds to — neither is a secret.

### Why not just put the private key in `.env`

The constitution's Secrets rule prohibits `--private-key` with a literal key outside local `anvil`.
Beyond the rule: this key becomes `admin` on the deployed contract, and `admin` controls where
every future top-up goes. A key that sits in plaintext on disk, in your shell history, and in every
process's environment is not a good custodian for that.

`.gitignore` already excludes `.env`, `.env.*`, `*.key` and `keystore/`, but that only stops
accidental commits — it does not make a plaintext key safe.

---

## 1. Create the deployer keystore

`cast wallet import` encrypts the key with a password and stores it in `~/.foundry/keystores`.

```bash
cast wallet import arc-deployer --interactive
# Paste the private key when prompted, then choose a password.

cast wallet list                                  # confirm it exists
cast wallet address --account arc-deployer        # note this address
```

Nothing readable is written to the repo. Each broadcast will prompt for the password.

> **Don't have a key yet?** `cast wallet new` generates one. Treat it as testnet-only.

## 2. (Removed)

This step used to create a separate pauser keystore, because the old contract needed a pauser key
distinct from the admin. The deployed contract has neither role, so there is no second key to
create, fund, or safeguard — and no operational key whose loss could freeze anything.

## 3. Fund the deployer

Arc testnet faucet: <https://faucet.circle.com>

On Arc the native gas token **is USDC with 6 DECIMALS** — one whole USDC is `1000000` base units,
not `1e18`. This single balance covers both the deployment gas and any test top-up you make
afterwards.

Note the balance the faucet gives you. It is a direct check on the denomination: a grant of a few
USDC reads as a few million base units. If it reads as some multiple of `1e18`, stop — the
6-decimal assumption this whole deployment rests on would be wrong. (`ARC_FUNDED_ACCOUNT` in
`.env` wires this address into the fork test's strict check.)

```bash
cast balance $(cast wallet address --account arc-deployer) \
  --rpc-url https://rpc.testnet.arc.io
```

## 4. Fill in `.env`

```bash
cp .env.example .env
```

Then set:

| Variable | Value |
|---|---|
| `TREASURY_ADDRESS` | Where every top-up lands, permanently. See the warning below. |
| `DEPLOYER_ACCOUNT` | `arc-deployer` |
| `DEPLOYER_ADDRESS` | The deployer address from step 1. |

That is the whole list. There is no `ADMIN_ADDRESS`, no `PAUSER_ADDRESS`, and no `MIN_TOPUP_WEI`
any more — the contract has no roles, and its minimum is a compile-time constant of `1e6`
(1.000000 USDC). If those variables are still in your local `.env` from a previous deployment,
they are ignored entirely and cannot reach the contract.

The deployer holds **no authority** over the contract once deployed, because there is no authority
to hold. It only pays gas.

### `TREASURY_ADDRESS` is permanent — verify it twice

This is the one irreversible decision in the entire process. The deployed contract has no function
that changes the treasury: not by admin, not after a delay, not by anyone. Two failure modes, and
neither has a remedy:

1. **A wrong address** routes every future top-up to it, irreversibly.
2. **A contract treasury that reverts on receipt** makes every top-up fail, permanently, bricking
   the deployment from block one.

The script rejects the zero address and the router's own address. It cannot catch a typo that
happens to be a valid address, and it cannot tell you whether the destination will accept funds.
Check the address against an independent source, and send one real top-up (step 8) before
announcing the router to anyone.

## 5. Dry run — always do this first

No `--broadcast`, no `--account`. Nothing is signed and nothing is sent. This runs the script's
`validate()` checks against the real chain.

```bash
source .env
forge script script/Deploy.s.sol \
  --rpc-url $ARC_TESTNET_RPC \
  --sender $DEPLOYER_ADDRESS
```

It verifies, before anything irreversible happens:

- `block.chainid == 5042002` (you are on Arc testnet, not somewhere else)
- `TREASURY_ADDRESS` is set and is not the zero address

A failure here costs nothing. A wrong value discovered after broadcast costs a redeployment —
the contract is immutable.

## 6. Broadcast

```bash
source .env
forge script script/Deploy.s.sol \
  --rpc-url $ARC_TESTNET_RPC \
  --account $DEPLOYER_ACCOUNT \
  --sender $DEPLOYER_ADDRESS \
  --broadcast \
  --verify --verifier blockscout --verifier-url https://testnet.arcscan.app/api
```

You will be prompted for the keystore password.

> **`--verifier blockscout` is required.** Arc's explorer is Blockscout. Without this flag forge
> falls back to Sourcify, which does not index Arc, and you get a run of `404 Not Found` warnings
> after an otherwise successful deployment. Blockscout needs **no API key** — `ARC_EXPLORER_KEY`
> can stay empty.

### If the deploy succeeded but verification failed

This is common and does **not** require redeploying. Verify the existing contract on its own:

```bash
source .env
forge verify-contract <DEPLOYED_ADDRESS> src/TopUpRouter.sol:TopUpRouter \
  --verifier blockscout \
  --verifier-url https://testnet.arcscan.app/api \
  --chain-id 5042002 \
  --constructor-args $(cast abi-encode "constructor(address)" $TREASURY_ADDRESS) \
  --watch
```

Take the constructor arguments from `broadcast/Deploy.s.sol/5042002/run-latest.json` rather than
retyping them — a mistyped argument produces a mismatch that looks like a compiler problem.

**Expect "partially verified", not "fully verified".** `foundry.toml` sets
`bytecode_hash = "none"` for reproducible builds, so there is no metadata hash for Blockscout to
compare. The source is published and matches the deployed runtime bytecode; that is what matters.
See `docs/deployments/arc-testnet.md` for the byte-level match evidence.

### Dropping the `--account` flag

`--account` reads the environment variable `ETH_KEYSTORE_ACCOUNT`, so this in `.env`:

```bash
ETH_KEYSTORE_ACCOUNT=arc-deployer
```

lets you shorten the command to:

```bash
forge script script/Deploy.s.sol --rpc-url $ARC_TESTNET_RPC \
  --sender $DEPLOYER_ADDRESS --broadcast
```

`--sender` has **no** environment-variable equivalent in this Foundry version (verified against
`forge script --help`), so keep passing it explicitly. The account name is not secret; the
password is still prompted for interactively.

## 7. Confirm the deployment

```bash
export ROUTER=<deployed address>

cast call $ROUTER "treasury()(address)"             --rpc-url $ARC_TESTNET_RPC
cast call $ROUTER "MIN_TOPUP()(uint256)"            --rpc-url $ARC_TESTNET_RPC  # 1000000
cast call $ROUTER "totalRouted()(uint256)"          --rpc-url $ARC_TESTNET_RPC  # 0
```

Then confirm on-chain what the test suite proves locally — that the governance surface is
**absent**, not merely guarded. Each of these must FAIL:

```bash
cast call $ROUTER "admin()(address)"  --rpc-url $ARC_TESTNET_RPC   # must fail
cast call $ROUTER "pauser()(address)" --rpc-url $ARC_TESTNET_RPC   # must fail
cast call $ROUTER "paused()(bool)"    --rpc-url $ARC_TESTNET_RPC   # must fail
cast call $ROUTER "DELAY()(uint256)"  --rpc-url $ARC_TESTNET_RPC   # must fail
```

If any of them returns a value, you deployed the wrong bytecode. Stop and investigate.

## 8. Commit the deployment artifacts

Constitution Principle VII requires a deployment be reproducible from a tagged commit. Record:

- deployed address
- constructor arguments as passed
- transaction hash and block number
- the commit SHA that was deployed
- explorer verification status

`broadcast/Deploy.s.sol/5042002/run-latest.json` holds most of this. Commit it, and confirm the
source is verified on <https://testnet.arcscan.app> before treating the contract as usable.

## 9. Confirm the treasury actually accepts funds

Before announcing the address, send one real top-up and confirm it lands:

```bash
source .env
cast send $ROUTER "topUpSelf()" --value 1000000 \
  --account arc-deployer --rpc-url $ARC_TESTNET_RPC

cast balance $TREASURY_ADDRESS --rpc-url $ARC_TESTNET_RPC   # should have increased by 1000000
```

`1000000` is exactly the minimum: one whole USDC at 6 decimals.

If this transfer fails, the treasury cannot receive and **the deployment is unusable**. There is no
way to repoint it. Deploy again with a corrected address and abandon this one.

There is no step 10. There is no multisig handover, because there is no authority to hand over.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `WrongNetwork(1, 5042002)` | `--rpc-url` missing or pointing elsewhere. |
| `MissingParameter("...")` | That variable is empty in `.env`, or you forgot `source .env`. |
| `insufficient funds` | Deployer is unfunded — step 3. Gas is USDC on Arc, at 6 decimals. |
| `ZeroAddress` / `SelfAddress` | `TREASURY_ADDRESS` is empty or is the router itself. |
| `BelowMinimum(sent, 1000000)` on a test top-up | You sent less than 1 whole USDC. Note the minimum is `1e6`, not `1e18`. |
| Password prompt loops | Wrong password. `cast wallet list` confirms the account exists; there is no recovery for a forgotten keystore password. |
| `Sourcify verification ... 404 Not Found` (x5) | `--verifier blockscout` was omitted. The deployment itself succeeded — verify separately, see the section above. Not an API-key problem. |
| Explorer shows "partially verified" | Expected: `bytecode_hash = "none"` removes the metadata hash. Source still matches deployed bytecode. |

# Deploying TopUpRouter to Arc testnet

From an empty machine to a verified contract. Every command here has been checked against the
installed Foundry version.

## How signing actually works here

**The wallet is not configured in `.env`.** `script/Deploy.s.sol` calls `vm.startBroadcast()` with
no argument, which means "sign with whatever signer the CLI provides". So:

- `.env` holds the **constructor parameters** — treasury, admin, pauser, minimum top-up.
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

## 2. Create the pauser keystore

The deploy script **refuses to broadcast if `pauser == admin`** (`validate()` in
`script/Deploy.s.sol`), so you need a second key.

```bash
cast wallet import arc-pauser --interactive
cast wallet address --account arc-pauser          # note this address too
```

The pauser never needs funding — it only sends `pause()`/`unpause()`, and only during an incident.
Keep it somewhere you can reach quickly; it is the only fast lever the system has.

## 3. Fund the deployer

Arc testnet faucet: <https://faucet.circle.com>

On Arc the native gas token **is USDC (18 decimals)**, so this single balance covers both the
deployment gas and any test top-up you make afterwards.

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
| `TREASURY_ADDRESS` | Where every top-up lands. A plain wallet you control. |
| `ADMIN_ADDRESS` | The deployer address from step 1. |
| `PAUSER_ADDRESS` | The pauser address from step 2. **Must differ from admin.** |
| `MIN_TOPUP_WEI` | Smallest accepted top-up. `1000000000000000000` = 1 USDC. **Fixed forever.** |
| `DEPLOYER_ACCOUNT` | `arc-deployer` |
| `DEPLOYER_ADDRESS` | The deployer address from step 1. |

The deployer does **not** have to be `ADMIN_ADDRESS`, and preferably is not: the deployer only pays
gas and holds no authority over the contract once deployed. Keeping them separate means the key you
expose during deployment is not the key that governs the treasury.

`MIN_TOPUP_WEI` cannot be changed after deployment — changing it requires deploying a new
contract. Choose it deliberately.

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
- `pauser != admin`
- no zero addresses, non-zero minimum

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
  --constructor-args $(cast abi-encode "constructor(address,address,address,uint256)" \
      $TREASURY_ADDRESS $ADMIN_ADDRESS $PAUSER_ADDRESS $MIN_TOPUP_WEI) \
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

cast call $ROUTER "DELAY()(uint256)"                --rpc-url $ARC_TESTNET_RPC  # 172800
cast call $ROUTER "treasury()(address)"             --rpc-url $ARC_TESTNET_RPC
cast call $ROUTER "admin()(address)"                --rpc-url $ARC_TESTNET_RPC
cast call $ROUTER "pauser()(address)"               --rpc-url $ARC_TESTNET_RPC
cast call $ROUTER "MIN_TOPUP()(uint256)"            --rpc-url $ARC_TESTNET_RPC
cast call $ROUTER "multisigEstablished()(bool)"     --rpc-url $ARC_TESTNET_RPC  # false
```

`multisigEstablished` is `false` because you deployed with a single key. That is expected, and it
is the system's weakest state — see step 9.

## 8. Commit the deployment artifacts

Constitution Principle VII requires a deployment be reproducible from a tagged commit. Record:

- deployed address
- constructor arguments as passed
- transaction hash and block number
- the commit SHA that was deployed
- explorer verification status

`broadcast/Deploy.s.sol/5042002/run-latest.json` holds most of this. Commit it, and confirm the
source is verified on <https://testnet.arcscan.app> before treating the contract as usable.

## 9. Then hand over to a multisig

Deploying leaves a single key controlling `admin`. That key can redirect every future top-up —
after a 2-day delay, but it can. Closing that window is the next step, and it also takes 2 days
because the handover is itself timelocked.

See `docs/OPERATIONS.md`, Runbook 2.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `WrongNetwork(1, 5042002)` | `--rpc-url` missing or pointing elsewhere. |
| `PauserMustDifferFromAdmin` | `PAUSER_ADDRESS` equals `ADMIN_ADDRESS`. Use the step-2 key. |
| `MissingParameter("...")` | That variable is empty in `.env`, or you forgot `source .env`. |
| `insufficient funds` | Deployer is unfunded — step 3. Remember gas is USDC on Arc. |
| Password prompt loops | Wrong password. `cast wallet list` confirms the account exists; there is no recovery for a forgotten keystore password. |
| `Sourcify verification ... 404 Not Found` (x5) | `--verifier blockscout` was omitted. The deployment itself succeeded — verify separately, see the section above. Not an API-key problem. |
| Explorer shows "partially verified" | Expected: `bytecode_hash = "none"` removes the metadata hash. Source still matches deployed bytecode. |

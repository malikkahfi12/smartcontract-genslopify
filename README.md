# TopUpRouter

A single immutable contract that accepts native USDC top-ups on the Arc chain, forwards every
payment straight to a treasury address, and records who paid and who was credited.

**There is no way to get funds back out. That is the point, not an omission.**

## What it does

A user sends USDC as transaction value. In the same transaction the full amount is forwarded to
the treasury and a `ToppedUp` event credits a beneficiary — who may be the payer or anyone else.
The contract holds no user funds between transactions.

Credit is consumed by an off-chain ledger. The on-chain totals (`contributions`, `totalRouted`)
are a reconciliation aid, not a spendable balance: funds leave immediately and no withdrawal
exists, so a redeemable on-chain balance could not exist.

## Governance model

| Control | Who | Delay |
|---|---|---|
| Rotate treasury | `admin` | **2 days** |
| Transfer authority | `admin` | **2 days** |
| Change pauser | `admin` | **2 days** |
| Pause / resume top-ups | `pauser` | **immediate** |
| Move funds | **nobody** | — |

Three properties are worth understanding before you rely on this contract:

**The 2-day delay covers every route to the treasury.** Authority transfer is delayed too. If it
were not, an attacker holding `admin` would transfer authority to themselves and rotate the
treasury in one transaction, and the delay would be worth nothing. Making themselves admin first
takes 4 days total — strictly slower than the direct route.

**The delay cannot be changed by anyone.** `DELAY` is a compile-time constant, not a constructor
parameter, so every deployment of a given build has the same 2 days. Changing it requires a new
contract.

**Single-key governance is one-way.** The contract may be deployed with a single primary key for
launch practicality. Once authority moves to a contract, it can never return to a plain key.

## Accepted terminal risk — read this

The design deliberately has **no escape hatch**. Code is immutable, the delay is fixed, authority
cannot fall back to a single key, and no function moves funds.

**If multisig quorum is ever lost, the treasury address freezes permanently.** Top-ups keep
routing to whatever address is set, the system cannot be paused, and no one can change anything.
The only remedy is deploying a replacement contract and migrating users.

Each of those choices is individually sound. Together they shift decisive weight onto **signer key
custody** and **the correctness of the handover address**. Treat both accordingly.

Two smaller consequences of the same posture:

- **Funds sent directly to the contract are permanently stranded.** Native funds can be forced in
  via `SELFDESTRUCT`, which no code can refuse. They credit nobody and cannot be recovered — any
  recovery path would be a withdrawal path.
- **Erroneous or duplicate top-ups cannot be reversed on-chain.** Remediation is an off-chain
  business process against the treasury.

## Chain specifics

Arc testnet, chain ID `5042002`. The native gas token is **USDC with 18 decimals**, not ETH.
Because gas and payment are the same asset, a user cannot top up their entire balance — the
attempt fails cleanly rather than being compensated for.

Arc testnet supports **Cancun**, confirmed by opcode probe (`PUSH0`, `TSTORE`/`TLOAD`, `MCOPY` all
execute; an undefined opcode returns `OpcodeNotFound`). `evm_version` is set deliberately in
`foundry.toml`. **Mainnet EVM support is not established — re-probe before any mainnet build.**

## Build and test

```bash
forge build
forge test                    # 138 tests
forge coverage                # 100% lines / statements / branches / functions on src/
forge lint src/ script/       # zero warnings
slither . --config-file slither.config.json   # zero results
npx solhint 'src/**/*.sol'    # clean
```

To deploy, see **`docs/DEPLOYMENT.md`** — signing uses an encrypted keystore, not a key in `.env`.

**Deployed on Arc testnet**:
[`0xd1040c76f7834863c0e971446016e3ad219e5cb0`](https://testnet.arcscan.app/address/0xd1040c76f7834863c0e971446016e3ad219e5cb0)
(verified). An earlier deployment at `0x9B07…0B0C` is superseded. Full record in
`docs/deployments/arc-testnet.md`. Currently under **single-key governance** —
`multisigEstablished()` is `false`.

The suite includes adversarial tests (`test/attack/`) that each attempt an exploit and assert it
fails, two stateful invariant campaigns, and a fork test that exercises governance through a real
Safe deployed on Arc testnet.

## Scope

Currently scoped to **Arc testnet**. Deferred, not waived: an independent external audit, and a
live rehearsal of the multisig handover. Both re-activate if a production deployment is proposed.

See `docs/OPERATIONS.md` for runbooks, `specs/` for the specifications this was built from, and
`.specify/memory/constitution.md` for the engineering principles it is held to.

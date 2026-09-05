# TopUpRouter

A single immutable contract that accepts native USDC top-ups on the Arc chain, forwards every
payment straight to a fixed treasury address, and records who paid and who was credited.

**There is no way to get funds back out, and no way to change where they go. That is the point,
not an omission.**

## What it does

A user sends native USDC as transaction value. In the same transaction the full amount is
forwarded to the treasury and a `ToppedUp` event credits a beneficiary — who may be the payer or
anyone else. The contract holds no user funds between transactions.

Credit is consumed by an off-chain ledger. The on-chain totals (`contributions`, `totalRouted`)
are a reconciliation aid, not a spendable balance: funds leave immediately and no withdrawal
exists, so a redeemable on-chain balance could not exist.

## Governance model

There isn't one.

| Control | Who | How |
|---|---|---|
| Change the treasury | **nobody** | no such function exists |
| Pause or resume top-ups | **nobody** | no such function exists |
| Change the minimum | **nobody** | compile-time constant |
| Upgrade the code | **nobody** | no proxy, no upgrade hook |
| Move funds out | **nobody** | no withdrawal path of any kind |

The contract stores no privileged address. There is no admin, no pauser, no owner, and no
timelock — nothing to compromise, nothing to lose, and nothing whose loss could freeze the
system. Every function behaves identically no matter who calls it.

The entire external surface is two payable functions and four getters. You can read all of it in
one sitting, which is the property that makes an ungoverned immutable contract defensible.

## Denomination — read this before writing any integration

**Native USDC on Arc has 6 decimals, not 18.** One whole USDC is `1e6` base units of `msg.value`.
Arc's own documentation calls this the most common mistake when porting an EVM application, and
an earlier deployment of this contract was rendered permanently unusable by getting it wrong.

The minimum top-up is `1e6` — exactly 1.000000 USDC — fixed in the code forever.

## Accepted terminal risks — read this too

The design deliberately has **no escape hatch**, and the costs are real:

**A wrong treasury address is permanent.** It cannot be corrected by anyone, at any time. If the
treasury is a contract that reverts on receipt, every top-up fails forever and the deployment is
bricked. Validation before deployment is the only defence that exists.

**There is no incident response.** A defect cannot be patched and top-ups cannot be halted. The
only available response to anything going wrong is to stop directing contributors to the address
and deploy a replacement.

**ERC-20 tokens sent to this address are lost permanently.** Native USDC is the only accepted
payment. There is no token-rescue function, because a rescue would need a privileged caller and a
non-treasury outflow — the two things this contract exists to forbid. Send only native USDC.

## Reading the contract state

```bash
cast call $ROUTER "treasury()(address)"            --rpc-url $ARC_TESTNET_RPC
cast call $ROUTER "MIN_TOPUP()(uint256)"           --rpc-url $ARC_TESTNET_RPC
cast call $ROUTER "totalRouted()(uint256)"         --rpc-url $ARC_TESTNET_RPC
cast call $ROUTER "contributions(address)(uint256)" $ACCOUNT --rpc-url $ARC_TESTNET_RPC
```

## Development

```bash
forge build && forge test        # 82 tests: unit, attack, invariant, symbolic, fork
forge coverage --report summary  # 100% lines/branches on src/
```

Governance rules and quality gates: `.specify/memory/constitution.md`.
Deployment walkthrough: `docs/DEPLOYMENT.md`.

# Operations runbook — TopUpRouter

**There are no operations.**

That is not a placeholder. The deployed contract has no administrator, no pauser, no owner, and
no timelock. No key holder can change the treasury, halt top-ups, adjust the minimum, upgrade the
code, or move funds. There is no privileged call for this runbook to document, and no operational
key that needs to be funded, rotated, or guarded.

Everything that used to live here — proposing a treasury rotation, waiting out the 2-day delay,
handing authority to a multisig, pausing during an incident — describes a contract that no longer
exists. See git history if you need it for the earlier deployment.

## What you can still do

Read state. That is the whole list.

```bash
source .env
cast call $ROUTER "treasury()(address)"             --rpc-url $ARC_TESTNET_RPC
cast call $ROUTER "MIN_TOPUP()(uint256)"            --rpc-url $ARC_TESTNET_RPC
cast call $ROUTER "totalRouted()(uint256)"          --rpc-url $ARC_TESTNET_RPC
cast call $ROUTER "contributions(address)(uint256)" $ACCOUNT --rpc-url $ARC_TESTNET_RPC
```

Amounts are in base units of native USDC, which has **6 decimals** on Arc. Divide by `1_000_000`
for whole USDC. Do not divide by `1e18`.

## Incident response

There is one procedure, and it is the same regardless of what went wrong:

1. **Stop directing contributors to the address.** Update the application, the docs, and any
   published reference. This is the only lever that exists.
2. **Deploy a replacement** per `docs/DEPLOYMENT.md`, at a new address.
3. **Migrate** contributors to the new address.

You cannot pause the contract while you do this. Top-ups already sent are irreversible and cannot
be recovered. Funds continue routing to the treasury for as long as anyone keeps calling it, which
may be indefinitely — an address on a public chain does not stop working because you stopped
advertising it.

This is a deliberate trade, accepted when the contract was specified: no privileged function means
no privileged function to be compromised, and the surface is small enough to review exhaustively
instead. It is worth being clear-eyed that the cost is a real one, paid at the worst possible
moment.

## Things people will ask for that cannot be done

| Request | Answer |
|---|---|
| "Point the treasury at a new Safe" | Not possible. Redeploy. |
| "Pause while we investigate" | Not possible. No pause exists. |
| "Someone sent USDT/ETH-bridged tokens, get them back" | Not possible. Permanently stranded. |
| "Lower the minimum, it's too high" | Not possible. Compile-time constant. Redeploy. |
| "Someone overpaid, refund them" | Not possible. Funds are at the treasury; refund from there. |
| "Upgrade to fix a bug" | Not possible. No proxy. Redeploy. |

For the last row in particular: a redeploy is a new address with a new contribution history. The
off-chain ledger must be told about both.

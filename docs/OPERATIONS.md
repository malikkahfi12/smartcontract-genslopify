# Operations runbook — TopUpRouter

Everything here assumes the contract is **immutable**. There is no patch. Pausing and redeploying
are the only responses to a defect.

## Before you start

Signing uses an encrypted keystore, not a key in `.env`. See `docs/DEPLOYMENT.md` steps 1-2 if you
have not set one up.

**Each command below uses the key for the role it needs. They are not interchangeable — sending an
admin-only call from the deployer key reverts `NotAdmin`.**

| Placeholder | Role | Used for |
|---|---|---|
| `$ADMIN_ACCOUNT` | admin | propose / cancel any governance change |
| `$PAUSER_ACCOUNT` | pauser | `pause()` / `unpause()` only |
| `$ANY_FUNDED_ACCOUNT` | none | `apply*()` — permissionless, any funded key works |

```bash
source .env
cast wallet list                                    # accounts available to sign
cast call $ROUTER "admin()(address)"  --rpc-url $ARC # must match $ADMIN_ACCOUNT's address
cast call $ROUTER "pauser()(address)" --rpc-url $ARC # must match $PAUSER_ACCOUNT's address
```

**Every signing key needs USDC.** Gas on Arc is paid in USDC, so an unfunded admin cannot govern
and an unfunded pauser cannot stop an incident. Check before you need them:

```bash
cast balance $ADMIN_ADDRESS  --rpc-url $ARC
cast balance $PAUSER_ADDRESS --rpc-url $ARC
```

Never pass a literal private key outside local `anvil` (constitution, Secrets).

`applyTreasury()`, `applyAdmin()` and `applyPauser()` are **permissionless** — once a proposal
matures, anyone may execute it. This is deliberate: authorization happened at proposal time and
the delay is the protection. It means you do not need signer availability to complete a change.

---

## Runbook 1 — Rotate the treasury

**Takes 2 days. Plan for it.**

```bash
# Day 0 — propose (admin only)
cast send $ROUTER "proposeTreasury(address)" $NEW_TREASURY --rpc-url $ARC --account $ADMIN_ACCOUNT

# Confirm it is pending and note the effective time
cast call $ROUTER "pendingTreasury()(address,uint64)" --rpc-url $ARC

# Day 2 — apply (anyone may call)
cast send $ROUTER "applyTreasury()" --rpc-url $ARC --account $ANY_FUNDED_ACCOUNT
cast call $ROUTER "treasury()(address)" --rpc-url $ARC   # verify
```

**If the proposal is wrong**, cancel it before it matures:

```bash
cast send $ROUTER "cancelTreasury()" --rpc-url $ARC --account $ADMIN_ACCOUNT
```

A cancelled proposal can never be applied. Re-proposing restarts the full 2 days — it never
inherits elapsed time.

---

## Runbook 2 — Hand over to a multisig

**This is one-way. Once complete, authority can never return to a plain key.**

```bash
# Day 0
ROUTER_ADDRESS=$ROUTER MULTISIG_ADDRESS=$SAFE \
  forge script script/ProposeHandover.s.sol --rpc-url $ARC --broadcast \
    --account $ADMIN_ACCOUNT --sender $ADMIN_ADDRESS

# Day 2
cast send $ROUTER "applyAdmin()" --rpc-url $ARC --account $ANY_FUNDED_ACCOUNT
cast call $ROUTER "multisigEstablished()(bool)" --rpc-url $ARC   # must be true
```

**Check the target address carefully.** It is recoverable only inside the 2-day window
(`cancelAdmin()`). After that, an incorrect authority address is permanently in control.

The contract verifies the target is a contract, not that it is a multisig. `code.length > 0` would
also pass for a contract forwarding to a single key. Verify the Safe's owners and threshold
yourself before proposing.

---

## Runbook 3 — Incident response

**Pausing is the only fast lever.** It is immediate and sits on `pauser`, deliberately separate
from and easier to satisfy than the treasury quorum.

```bash
# 1. STOP THE BLEEDING — immediate, no delay, pauser only
cast send $ROUTER "pause()" --rpc-url $ARC --account $PAUSER_ACCOUNT

# 2. Assess. Governance still works while paused, by design.
cast call $ROUTER "treasury()(address)" --rpc-url $ARC
cast call $ROUTER "pendingTreasury()(address,uint64)" --rpc-url $ARC
cast call $ROUTER "admin()(address)" --rpc-url $ARC

# 3. If the treasury is compromised, start a rotation — still 2 days
cast send $ROUTER "proposeTreasury(address)" $SAFE_TREASURY --rpc-url $ARC --account $ADMIN_ACCOUNT

# 4. Resume once safe
cast send $ROUTER "unpause()" --rpc-url $ARC --account $PAUSER_ACCOUNT
```

**What pausing does not do:** it does not stop a pending governance change from maturing, and it
does not recover funds already sent. If an attacker holds `admin` and you do not, you can pause
but you **cannot cancel** their pending rotation. Pausing stops money flowing; it does not stop
the rotation.

---

## Monitoring (required, not optional)

The 2-day window only protects you if someone is watching it. Alert on:

| Signal | Why |
|---|---|
| `pendingTreasury()` target becomes non-zero | A rotation is in progress — you have 2 days |
| `pendingAdmin()` target becomes non-zero | An authority transfer is in progress |
| `ChangeProposed` event | Same signals, push rather than poll |
| `multisigEstablished()` flips to true | Handover completed |
| `Paused` / `Unpaused` events | Someone used the emergency lever |

An unexpected `ChangeProposed` is the single highest-priority alert this system produces. It means
someone is 2 days away from redirecting all incoming funds.

---

## Reconciliation

`ToppedUp` carries `newTotal` — the beneficiary's post-state total, not just the delta. An indexer
should assert `newTotal == previousTotal + amount` for each beneficiary. A mismatch means a missed
or duplicated event, caught immediately rather than drifting silently.

Reconciliation identity: the sum of all `contributions` equals `totalRouted` equals the total this
contract has sent to treasuries. This holds regardless of funds forced into the contract, because
the contract never reads its own balance.

---

## Open governance obligation

If deployed with a single primary key, that window is the system's weakest state and nothing
on-chain forces it to close. Track the handover to completion and record how long the window
stayed open (spec 002 SC-009). It is a documented, time-boxed exception to constitution
Principle V — undocumented exceptions are defects.

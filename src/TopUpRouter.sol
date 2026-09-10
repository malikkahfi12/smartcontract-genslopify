// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TopUpRouter
/// @author Forgeify
/// @notice Accepts native USDC top-ups on Arc and forwards them straight to a fixed treasury
///         address, recording who paid and who was credited. There is no way to get funds back
///         out, and no way to change where they go.
///
/// @dev ## Immutability and the absence of governance
///      This contract is IMMUTABLE, NON-UPGRADEABLE, and UNGOVERNED (spec 003 FR-014/FR-016).
///      There is no proxy, no upgrade hook, no administrator, no pauser, and no timelock. No
///      address stored here confers any privilege: every function behaves identically no matter
///      who calls it (003 FR-014, SC-004a).
///
///      That is a deliberate trade, and an expensive one. It means there is NO incident response.
///      A defect cannot be patched, top-ups cannot be halted, and a mistaken treasury cannot be
///      corrected. The only available response to anything going wrong is to stop directing
///      contributors here and deploy a replacement.
///
///      What buys that back is size. This contract is small enough to read in full in one sitting,
///      and it has exactly one state-changing path. Simplicity substitutes for recoverability,
///      which is only defensible because the contract stayed this small. Anything added here
///      erodes the trade — treat every line as permanent, and every addition as suspect.
///
/// @dev ## No withdrawal - the central guarantee
///      No function moves funds out of this contract to anyone but the treasury, and the only way
///      to reach the treasury is by paying into it (003 FR-015). The contract holds no user funds
///      between transactions: each top-up forwards its full value within the same call. There is
///      deliberately no `receive`/`fallback`, no sweep/rescue/withdraw, and no arbitrary-call
///      helper. Adding any of them would break the contract's reason for existing, and there is no
///      role that could be trusted with one anyway.
///
/// @dev ## Payment asset - native USDC only
///      The payment asset is NATIVE USDC on Arc, 18 DECIMALS: one whole USDC is `1e18` base units
///      of `msg.value`, the same scale every other EVM chain uses for its native currency.
///      The denomination is the single most consequential constant in this contract: an earlier
///      deployment was rendered permanently unusable by carrying a minimum at the wrong scale, so
///      every native-amount literal in source, scripts, and tests must use the `1e18` scale, and a
///      bare `1e6` in a native-amount position is a defect on sight.
///
///      Native USDC is the ONLY accepted payment and no other token will ever be supported (003
///      FR-017a/b). This contract stores no token address, imports no token interface, and has no
///      function that names a token. Since there is no administrator, a token allowlist could not
///      be maintained even if one existed — single-currency is structural here, not a policy.
///
///      Consequence for contributors: ERC-20 tokens transferred to this address are PERMANENTLY
///      LOST (003 FR-017c). Nothing is credited and no rescue exists, because a rescue would need
///      a privileged caller and a non-treasury outflow — the two things this contract forbids.
///
///      Native USDC is also the gas token, so a user cannot top up their entire balance.
///
/// @dev ## Threat model
///      Assets at risk: (1) funds in flight during a single `topUp`; (2) the integrity of the
///      contribution record, which the off-chain ledger trusts. Note what is NOT on this list: the
///      future stream of top-ups is no longer an asset an attacker can capture, because no key
///      controls the destination.
///
///      Assumed adversary: can call anything with any arguments; can deploy hostile contracts and
///      make them the caller; can force native funds in via SELFDESTRUCT; can reorder and
///      front-run within a block; may compromise any key, to no effect.
///
///      | Threat                              | Mitigation                                        |
///      |-------------------------------------|---------------------------------------------------|
///      | Reentrancy via hostile treasury     | CEI ordering + `nonReentrant`; transfer is last   |
///      | Credit without payment              | Amount is `msg.value` only; state written first   |
///      | Forced-balance accounting corruption| `address(this).balance` is NEVER read             |
///      | Treasury redirection                | `treasury` is immutable; no setter exists         |
///      | Privilege escalation                | No privileged function exists to escalate into    |
///      | Griefing by reverting treasury      | Success checked; whole tx reverts, funds safe     |
///      | Accounting overflow                 | Checked arithmetic; no `unchecked` in this path   |
///
///      Front-running and transaction-ordering dependence (constitution Principle II) are NOT
///      applicable to this surface. Ordering mattered in the previous version because a treasury
///      rotation could land between a contributor's decision and their payment. With an immutable
///      destination and no governance, there is no ordering-sensitive state left to exploit: a
///      top-up's outcome depends only on its own `msg.value` and beneficiary.
///
///      ACCEPTED, UNMITIGATED: a wrong treasury address at deployment is permanent and
///      unrecoverable, and a treasury contract that reverts on receipt bricks every future top-up
///      with no way to repoint. Validation before deployment is the only defense that exists.
contract TopUpRouter is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                          CONSTANTS & IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Smallest accepted top-up: one whole USDC, permanently (003 FR-006).
    /// @dev Unit and provenance, per constitution Principle IV's no-magic-numbers rule: native
    ///      USDC on Arc has 18 decimals, so `1e18` base units is exactly one whole USDC
    ///      (1.000000000000000000).
    ///
    ///      `constant`, not `immutable` and not a constructor argument (003 FR-011, research
    ///      R-003). A constant is identical in every build of a given commit, so testnet and
    ///      mainnet bytecode cannot diverge on it, and an auditor can confirm the floor by reading
    ///      this line rather than decoding deployment calldata.
    ///
    ///      It can never change. If Arc's USDC price behaviour ever makes this floor wrong, the
    ///      response is a new deployment, not a parameter update.
    uint256 public constant MIN_TOPUP = 1e18;

    /// @notice Destination receiving every top-up. Fixed at deployment, forever (003 FR-001).
    /// @dev `immutable`: there is no setter at any visibility, no proposal record, and no role
    ///      that could call one. A contributor can read this before paying and rely on it for the
    ///      life of the contract.
    ///
    ///      Justification for the suppressions below (constitution Principle IV): the linters want
    ///      SCREAMING_SNAKE_CASE for an immutable, i.e. `TREASURY`. Rejected. Unlike `MIN_TOPUP`,
    ///      this name is part of the published interface: it generates the `treasury()` getter that
    ///      integrators, the block explorer, and the off-chain ledger already call, and it matches
    ///      the `treasury` field of `ToppedUp`. Renaming it would break every consumer to satisfy a
    ///      style rule about a storage classification they cannot observe. The value's permanence
    ///      is communicated by `immutable` and by this NatSpec, not by its capitalisation.
    // solhint-disable immutable-vars-naming
    // slither-disable-next-line naming-convention
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable treasury;
    // solhint-enable immutable-vars-naming

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice System-wide lifetime total routed to the treasury. Monotonically non-decreasing.
    uint256 public totalRouted;

    /// @notice Per-beneficiary lifetime total credited. Zero for accounts never credited.
    mapping(address account => uint256 total) public contributions;

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted for every successful top-up. The sole input to the off-chain credit ledger.
    /// @param payer Account that supplied the funds.
    /// @param beneficiary Account credited.
    /// @param amount Amount credited, equal to the amount sent to the treasury, in base units.
    /// @param treasury Address that received the funds.
    /// @param newTotal The beneficiary's lifetime total after this top-up.
    /// @dev `newTotal` is the post-state, not just a delta, so a consumer can assert
    ///      `newTotal == previousTotal + amount` and detect a gap or duplicate immediately.
    ///      `treasury` is retained although it is now constant: it keeps the consumer's schema
    ///      stable across the migration from the previous router, and a record that names its own
    ///      destination stays self-contained.
    event ToppedUp(
        address indexed payer,
        address indexed beneficiary,
        uint256 amount,
        address treasury,
        uint256 newTotal
    );

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice A top-up was attempted with zero value.
    error ZeroAmount();

    /// @notice A top-up was below `MIN_TOPUP`.
    error BelowMinimum(uint256 sent, uint256 minimum);

    /// @notice A top-up named the zero address as beneficiary.
    error ZeroBeneficiary();

    /// @notice The treasury refused the funds or consumed too much gas; nothing was credited.
    error TreasuryTransferFailed();

    /// @notice The treasury address was zero at construction.
    error ZeroAddress();

    /// @notice The treasury address was this contract, which is never a valid destination.
    error SelfAddress();

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy the router pointed at its permanent treasury.
    /// @param initialTreasury Address that will receive all top-ups, forever.
    /// @dev Takes exactly one argument (003 FR-014b): there is no role to configure and no
    ///      minimum to set. No chain id or address is hardcoded here (constitution Principle VI);
    ///      the deployment script validates the network before broadcasting.
    ///
    ///      Emits nothing. The previous version emitted initial-state events so an indexer could
    ///      reconstruct from block zero; with an immutable public treasury there is no state an
    ///      indexer could miss.
    ///
    ///      VALIDATE `initialTreasury` OFF-CHAIN FIRST. It cannot be changed afterwards by anyone,
    ///      and a destination that reverts on receipt makes every future top-up fail permanently.
    ///      The two checks below catch only the two mistakes that are detectable on-chain.
    constructor(address initialTreasury) {
        if (initialTreasury == address(0)) revert ZeroAddress();
        if (initialTreasury == address(this)) revert SelfAddress();

        treasury = initialTreasury;
    }

    /*//////////////////////////////////////////////////////////////
                                 TOP-UP
    //////////////////////////////////////////////////////////////*/

    /// @notice Top up on behalf of `beneficiary`, forwarding the attached value to the treasury.
    /// @param beneficiary Account to credit. May be the caller or anyone else.
    /// @dev Attach the amount as transaction value, in base units of native USDC (18 decimals).
    ///      There is no approval step and no token parameter: the payment asset is the chain's
    ///      own currency. The full amount reaches the treasury in this same call.
    function topUp(address beneficiary) external payable {
        _topUp(beneficiary);
    }

    /// @notice Top up your own account.
    /// @dev Convenience equivalent of `topUp(msg.sender)`; identical guards and event.
    function topUpSelf() external payable {
        _topUp(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL: TOP-UP LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev The single top-up implementation. Both entry points route through here so neither can
    ///      drift from the other or lose a guard.
    ///
    ///      Strict checks-effects-interactions:
    ///        1. CHECKS      - validate amount and beneficiary
    ///        2. EFFECTS     - write both totals, emit the record
    ///        3. INTERACTION - transfer to the treasury, LAST statement
    ///
    ///      A hostile treasury re-entering here finds fully written state and is stopped by
    ///      `nonReentrant`; its revert propagates and unwinds everything.
    ///
    ///      There is no pause check and no role check: this function behaves identically for every
    ///      caller at every moment of the contract's life (003 FR-005). The only reasons a top-up
    ///      is refused are the three validation rules below and a treasury that will not accept.
    ///
    ///      The credited amount comes solely from `msg.value`. `address(this).balance` is never
    ///      read, so funds forced in via SELFDESTRUCT cannot inflate a credit or corrupt
    ///      reconciliation (INV-9).
    function _topUp(address beneficiary) internal nonReentrant {
        uint256 amount = msg.value;

        // --- CHECKS ---
        if (amount == 0) revert ZeroAmount();
        if (amount < MIN_TOPUP) revert BelowMinimum(amount, MIN_TOPUP);
        if (beneficiary == address(0)) revert ZeroBeneficiary();

        // Read the immutable into a local so the emitted record and the transfer provably name the
        // same address, and the event-emission code stays identical to the previous version.
        address destination = treasury;

        // --- EFFECTS ---
        // No `unchecked`: Solidity 0.8 overflow checks stay on in the accounting path. The gas
        // saving is not worth weakening INV-2 (constitution Principle IV).
        uint256 newTotal = contributions[beneficiary] + amount;
        contributions[beneficiary] = newTotal;
        totalRouted += amount;

        emit ToppedUp(msg.sender, beneficiary, amount, destination, newTotal);

        // --- INTERACTION (last) ---
        //
        // Justification for the two suppressions below (constitution Principle IV requires every
        // suppressed finding to carry one):
        //
        // arbitrary-send-eth: `destination` is NOT user-controlled and is not controlled by anyone
        //   at all. It is `treasury`, an `immutable` fixed at construction with no setter at any
        //   visibility — the strongest form this justification can take, and stronger than the
        //   timelock argument it replaces. A plain `transfer`/`send` cannot be used: their
        //   2300-gas stipend breaks for a contract treasury, including a Safe, which is the
        //   intended production destination (research R-006). The return value IS checked below.
        //
        // reentrancy-eth: the linter reports that `_status` is not yet reset during the transfer.
        //   That is exactly the protection working, not a gap - OpenZeppelin's ReentrancyGuard
        //   resets `_status` in `_nonReentrantAfter()`, which runs AFTER the function body, so
        //   `_status` is ENTERED for the whole duration of this call and any reentry reverts.
        //   Proven empirically, not just argued: test/attack/Reentrancy.t.sol deploys a treasury
        //   that re-enters `topUp` on receipt and asserts the whole transaction unwinds with
        //   nobody credited twice.
        //
        // slither-disable-start low-level-calls,arbitrary-send-eth,reentrancy-events
        // forge-lint: disable-next-line(arbitrary-send-eth, reentrancy-eth)
        (bool ok,) = destination.call{value: amount}("");
        // slither-disable-end low-level-calls,arbitrary-send-eth,reentrancy-events
        if (!ok) revert TreasuryTransferFailed();
    }
}

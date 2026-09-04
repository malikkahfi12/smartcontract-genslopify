// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TopUpRouter
/// @author Forgeify
/// @notice Accepts native USDC top-ups on Arc and forwards them straight to a treasury address,
///         recording who paid and who was credited. There is no way to get funds back out.
///
/// @dev ## Immutability
///      This contract is IMMUTABLE and NON-UPGRADEABLE (spec 001 FR-018). There is no proxy and no
///      upgrade hook. A defect cannot be patched in place; the only responses are pausing top-ups
///      and deploying a replacement. Treat every line here as permanent.
///
/// @dev ## No withdrawal - the central guarantee
///      No function moves funds out of this contract, for any caller, in any role (001 FR-015/016/
///      017). The contract holds no user funds between transactions: each top-up forwards its full
///      value to the treasury within the same call. There is deliberately no `receive`/`fallback`,
///      no sweep/rescue/withdraw, and no arbitrary-call helper. Adding any of them would break the
///      contract's reason for existing.
///
/// @dev ## Threat model (research R-001)
///      Assets at risk: (1) funds in flight during a single `topUp`; (2) the FUTURE stream of
///      top-ups, controlled by whoever controls `treasury`; (3) the integrity of the contribution
///      record, which the off-chain ledger trusts.
///
///      Assumed adversary: can call anything with any arguments; can deploy hostile contracts and
///      make them the treasury or the caller; can force native funds in via SELFDESTRUCT; can
///      reorder and front-run within a block; can nudge block timestamps by seconds; may compromise
///      a single key.
///
///      | Threat                              | Mitigation                                        |
///      |-------------------------------------|---------------------------------------------------|
///      | Reentrancy via hostile treasury     | CEI ordering + `nonReentrant`; transfer is last   |
///      | Credit without payment              | Amount is `msg.value` only; state written first   |
///      | Forced-balance accounting corruption| `address(this).balance` is NEVER read             |
///      | Treasury redirection                | 2-day delay + quorum + public pending + cancel    |
///      | Delay bypass via authority swap     | Authority transfer carries the SAME delay         |
///      | Delay bypass via parameter change   | `DELAY` is a constant, not storage                |
///      | Griefing by reverting treasury      | Success checked; whole tx reverts, funds safe     |
///      | Governance lockout                  | Zero/self address rejected on every write         |
///
/// @dev ## Payment asset
///      The payment asset is NATIVE USDC on Arc, 18 decimals (spec 001 Q1 -> A). It is also the gas
///      token, so a user cannot top up their entire balance. This contract handles no ERC-20 tokens
///      and has no token-receiving facility (001 FR-031).
contract TopUpRouter is Pausable, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Which piece of governance state a pending change targets.
    enum Subject {
        Treasury,
        Admin,
        Pauser
    }

    /// @notice A proposed governance change and the moment it becomes applicable.
    /// @param target The proposed new address. Zero means "no pending change".
    /// @param eta Absolute timestamp from which the change may be applied.
    struct PendingChange {
        address target;
        uint64 eta;
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTANTS & IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The waiting period every governance change must serve: exactly 2 days.
    /// @dev MUST remain a compile-time constant, never storage and never a constructor parameter
    ///      (spec 002 FR-008/FR-008a). The delay constrains the admin, so the admin cannot be able
    ///      to change it - and neither can a deployer, or testnet and mainnet builds would differ.
    uint256 public constant DELAY = 2 days;

    /// @notice Smallest accepted top-up, fixed at deployment (001 FR-005).
    /// @dev Immutable rather than constant because the sensible floor depends on Arc gas costs at
    ///      launch. Fixed at construction and never changeable thereafter.
    // Justification for the suppression below: slither expects mixedCase for immutables.
    // SCREAMING_SNAKE_CASE is the prevailing convention for values fixed at construction and
    // reads correctly alongside `DELAY`; renaming would make the two look unrelated. Style only,
    // no behavioural impact.
    // slither-disable-next-line naming-convention
    uint256 public immutable MIN_TOPUP;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Destination receiving every top-up. Never zero, never this contract.
    address public treasury;

    /// @notice Governing authority. Initially a single primary key; later a multisig.
    address public admin;

    /// @notice Authority permitted to pause and resume top-ups, and nothing else.
    address public pauser;

    /// @notice True once `admin` has been a contract. Latches permanently; never unset.
    /// @dev Enforces the one-way exit from single-key governance (002 FR-023).
    bool public multisigEstablished;

    /// @notice System-wide lifetime total routed to treasuries. Monotonically non-decreasing.
    uint256 public totalRouted;

    /// @notice Per-beneficiary lifetime total credited. Zero for accounts never credited.
    mapping(address account => uint256 total) public contributions;

    // Justification for the suppression below: all three ARE written, via the storage pointer
    // returned by `_pendingSlot` in `_propose`, `_applyPending` and `_cancel`. The linter does
    // not trace writes through a storage-pointer return, so it reports a false positive. Proven
    // by the round-trip tests, e.g. test/unit/TreasuryRotation.t.sol asserts a proposal is
    // written and read back. Resolving this by inlining three copies of the engine would be a
    // clear loss for auditability (constitution Principle IV).
    // forge-lint: disable-start(uninitialized-state)

    // slither-disable-start uninitialized-state
    // Justification: all three ARE written, through the storage pointer `_pendingSlot` returns
    // in `_propose`, `_applyPending` and `_cancel`. Neither slither nor forge lint traces writes
    // through a storage-pointer return. Proven by round-trip tests in
    // test/unit/TreasuryRotation.t.sol and test/unit/AuthorityTransfer.t.sol.

    /// @notice Pending treasury change, if any.
    PendingChange public pendingTreasury;

    /// @notice Pending administrative authority change, if any.
    PendingChange public pendingAdmin;

    /// @notice Pending pauser change, if any.
    PendingChange public pendingPauser;
    // slither-disable-end uninitialized-state

    // forge-lint: disable-end(uninitialized-state)

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted for every successful top-up. The sole input to the off-chain credit ledger.
    /// @param payer Account that supplied the funds.
    /// @param beneficiary Account credited.
    /// @param amount Amount credited, equal to the amount sent to the treasury.
    /// @param treasury Address that actually received the funds.
    /// @param newTotal The beneficiary's lifetime total after this top-up.
    /// @dev `newTotal` is the post-state, not just a delta, so a consumer can assert
    ///      `newTotal == previousTotal + amount` and detect a gap or duplicate immediately
    ///      (001 FR-010, research R-008). `treasury` is included so the record names the address
    ///      that actually received the funds, which matters if a rotation lands in the same block.
    event ToppedUp(
        address indexed payer,
        address indexed beneficiary,
        uint256 amount,
        address treasury,
        uint256 newTotal
    );

    /// @notice A governance change was proposed and is now waiting out its delay.
    event ChangeProposed(Subject indexed subject, address indexed target, uint64 eta);

    /// @notice A pending governance change took effect.
    event ChangeApplied(Subject indexed subject, address indexed previous, address indexed target);

    /// @notice A pending governance change was cancelled and can never be applied.
    event ChangeCancelled(Subject indexed subject, address indexed target);

    /// @notice Governance moved to a contract authority; single-key control is now impossible.
    event MultisigEstablished(address indexed admin);

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

    /// @notice Caller is not the current administrative authority.
    error NotAdmin();

    /// @notice Caller is not the current pauser.
    error NotPauser();

    /// @notice An address argument was zero where a real address is required.
    error ZeroAddress();

    /// @notice An address argument was this contract, which is never a valid target.
    error SelfAddress();

    /// @notice There is no pending change for the requested subject.
    error NoPendingChange();

    /// @notice The waiting period has not fully elapsed yet.
    error TimelockNotElapsed(uint256 currentTime, uint256 eta);

    /// @notice Governance has already moved to a contract authority; an EOA is no longer allowed.
    error MustBeContract();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Restricts to the current administrative authority.
    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @dev Restricts to the current pauser. Deliberately separate from `onlyAdmin` so an urgent
    ///      pause never needs a treasury-rotation quorum (002 FR-024).
    modifier onlyPauser() {
        if (msg.sender != pauser) revert NotPauser();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy the router with its initial governance configuration.
    /// @param initialTreasury Address that will receive all top-ups.
    /// @param initialAdmin Governing authority. May be a single primary key at launch (002 FR-019).
    /// @param initialPauser Authority permitted to pause and resume top-ups.
    /// @param minTopUp Smallest accepted top-up amount; must be non-zero.
    /// @dev No chain id or address is hardcoded here (constitution Principle VI); the deployment
    ///      script validates the network before broadcasting.
    // forge-lint: disable-start(missing-zero-check)
    // Justification: every address below is validated on the first three lines of the body by
    // _requireValidAddress, which reverts ZeroAddress and SelfAddress. The linter does not trace
    // validation through an internal helper, so this is a false positive. Duplicating the checks
    // inline would satisfy the linter at the cost of the single shared validation path that every
    // governance write uses - a worse trade for auditability (constitution Principle IV).
    constructor(
        address initialTreasury,
        address initialAdmin,
        address initialPauser,
        uint256 minTopUp
    ) {
        // forge-lint: disable-end(missing-zero-check)
        _requireValidAddress(initialTreasury);
        _requireValidAddress(initialAdmin);
        _requireValidAddress(initialPauser);
        if (minTopUp == 0) revert ZeroAmount();

        // slither-disable-start missing-zero-check
        // Justification: all three are validated on the three lines above by
        // `_requireValidAddress`, which reverts ZeroAddress and SelfAddress. Static analysis does
        // not trace validation through an internal helper. Covered by
        // test/unit/Deployment.t.sol::test_RevertWhen_ConstructorGivenZeroAddress.
        treasury = initialTreasury;
        admin = initialAdmin;
        pauser = initialPauser;
        // slither-disable-end missing-zero-check
        MIN_TOPUP = minTopUp;

        // If governance starts on a contract authority, latch immediately: there is no reason to
        // permit a later downgrade to a single key just because deployment skipped that step.
        if (initialAdmin.code.length > 0) {
            multisigEstablished = true;
            emit MultisigEstablished(initialAdmin);
        }

        // Emit initial state so an indexer can reconstruct history from block zero with no gaps.
        emit ChangeApplied(Subject.Treasury, address(0), initialTreasury);
        emit ChangeApplied(Subject.Admin, address(0), initialAdmin);
        emit ChangeApplied(Subject.Pauser, address(0), initialPauser);
    }

    /*//////////////////////////////////////////////////////////////
                                 TOP-UP
    //////////////////////////////////////////////////////////////*/

    /// @notice Top up on behalf of `beneficiary`, forwarding the attached value to the treasury.
    /// @param beneficiary Account to credit. May be the caller or anyone else (001 FR-006).
    /// @dev Attach the amount as transaction value. There is no approval step: the payment asset
    ///      is native USDC on Arc. The full amount reaches the treasury in this same call.
    function topUp(address beneficiary) external payable {
        _topUp(beneficiary);
    }

    /// @notice Top up your own account.
    /// @dev Convenience equivalent of `topUp(msg.sender)`; identical guards and event.
    function topUpSelf() external payable {
        _topUp(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                          PAUSE (IMMEDIATE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Immediately halt all new top-ups.
    ///
    /// @dev security: This is the ONLY fast lever in the system and the only incident response
    ///      available at all. The code is immutable (001 FR-018), so a defect cannot be patched,
    ///      and top-ups are irreversible (001 FR-015), so funds already sent cannot be recovered.
    ///      Everything a pause can do is stop the bleeding.
    ///
    ///      It therefore takes effect in the same transaction, with NO waiting period (002
    ///      FR-025), and sits on `pauser` rather than `admin` so an urgent halt never needs a
    ///      treasury-rotation quorum (002 FR-024). Because it is the fastest authority it is also
    ///      the narrowest: a pauser can deny service and nothing else. It cannot move funds,
    ///      rotate the treasury, or transfer authority (002 FR-026).
    ///
    ///      Pausing deliberately does NOT block governance (002 FR-027). Freezing top-ups while
    ///      also freezing the ability to rotate to a safe treasury would make the control
    ///      self-defeating during the exact incident it exists for.
    function pause() external onlyPauser {
        _pause();
    }

    /// @notice Resume top-ups after a pause.
    /// @dev Recorded totals are untouched by a pause, so accounting continues from prior values.
    function unpause() external onlyPauser {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                          GOVERNANCE: TREASURY
    //////////////////////////////////////////////////////////////*/

    /// @notice Propose a new treasury destination. Takes effect after the 2-day delay.
    /// @param newTreasury The proposed destination. Must be non-zero and not this contract.
    /// @dev Replaces any existing proposal and RESTARTS the full delay (002 FR-012). Re-proposing
    ///      can therefore never shorten the wait, only extend it.
    function proposeTreasury(address newTreasury) external onlyAdmin {
        _propose(Subject.Treasury, newTreasury);
    }

    /// @notice Execute a proposed treasury change once its delay has elapsed.
    /// @dev Deliberately PERMISSIONLESS. Authorization happened at proposal time and the delay is
    ///      the protection; requiring the admin to appear a second time would add no security
    ///      while creating an availability risk if signers are unreachable.
    function applyTreasury() external {
        address previous = treasury;
        address next = _applyPending(Subject.Treasury);
        treasury = next;
        emit ChangeApplied(Subject.Treasury, previous, next);
    }

    /// @notice Cancel a pending treasury change before it takes effect.
    /// @dev A cancelled change can never be applied (002 FR-011): the slot is cleared, and
    ///      `_applyPending` rejects an empty slot. This is what makes the 2-day window a real
    ///      control rather than merely an announcement of an imminent change.
    function cancelTreasury() external onlyAdmin {
        _cancel(Subject.Treasury);
    }

    /*//////////////////////////////////////////////////////////////
                      GOVERNANCE: ADMINISTRATIVE AUTHORITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Propose a new administrative authority. Takes effect after the 2-day delay.
    /// @param newAdmin The proposed authority. Must be non-zero and not this contract.
    ///
    /// @dev security: This transfer is delayed by exactly the same 2 days as a treasury rotation,
    ///      and that is NOT incidental symmetry - it is the whole point. If authority could change
    ///      instantly, an attacker holding `admin` would transfer authority to themselves and
    ///      rotate the treasury in one transaction, and the delay protecting the treasury would be
    ///      worth nothing. The delay is only as strong as the fastest route to the asset it
    ///      guards, so every route carries it (002 FR-017).
    ///
    ///      Do NOT "optimise" this by making authority transfer immediate, however convenient an
    ///      urgent signer rotation would be. The pause control is the fast response; this is not.
    ///      test/attack/TimelockBypass.t.sol proves the bypass fails.
    function proposeAdmin(address newAdmin) external onlyAdmin {
        _propose(Subject.Admin, newAdmin);
    }

    /// @notice Execute a proposed authority transfer once its delay has elapsed.
    /// @dev Permissionless for the same reason as `applyTreasury`.
    ///
    /// @dev security: The `multisigEstablished` latch enforces the one-way exit from single-key
    ///      governance (002 FR-023). Once authority has rested on a contract, it can never return
    ///      to an externally owned account, so observed multi-signature governance is a durable
    ///      guarantee rather than a revocable claim.
    ///
    ///      LIMITATION, stated plainly so nobody over-trusts it: `code.length > 0` proves the
    ///      target is A CONTRACT. It does NOT prove the target is a multisig, is honest, or
    ///      requires more than one signature. Someone holding `admin` could hand authority to a
    ///      contract that forwards everything to a single key, and this check would pass. It
    ///      reliably blocks the accidental and the plain-EOA cases; it is not a proof of
    ///      decentralisation. What actually lets observers catch a bad handover is that `admin`
    ///      is publicly readable (002 FR-018) and every change is announced 2 days in advance.
    ///
    ///      The check is evaluated HERE, at apply time, rather than at propose time, because the
    ///      state that matters is the moment authority actually transfers.
    function applyAdmin() external {
        address previous = admin;
        address next = _applyPending(Subject.Admin);

        bool targetIsContract = next.code.length > 0;
        if (multisigEstablished && !targetIsContract) revert MustBeContract();

        admin = next;
        emit ChangeApplied(Subject.Admin, previous, next);

        if (targetIsContract && !multisigEstablished) {
            multisigEstablished = true;
            emit MultisigEstablished(next);
        }
    }

    /// @notice Cancel a pending authority transfer before it takes effect.
    function cancelAdmin() external onlyAdmin {
        _cancel(Subject.Admin);
    }

    /*//////////////////////////////////////////////////////////////
                           GOVERNANCE: PAUSER
    //////////////////////////////////////////////////////////////*/

    /// @notice Propose a new pauser. Takes effect after the 2-day delay.
    /// @param newPauser The proposed pauser. Must be non-zero and not this contract.
    /// @dev Changing WHO may pause is a governance action and is delayed. USING the pause itself
    ///      is immediate (002 FR-025) - the speed belongs to the action, not to the appointment.
    function proposePauser(address newPauser) external onlyAdmin {
        _propose(Subject.Pauser, newPauser);
    }

    /// @notice Execute a proposed pauser change once its delay has elapsed.
    function applyPauser() external {
        address previous = pauser;
        address next = _applyPending(Subject.Pauser);
        pauser = next;
        emit ChangeApplied(Subject.Pauser, previous, next);
    }

    /// @notice Cancel a pending pauser change before it takes effect.
    function cancelPauser() external onlyAdmin {
        _cancel(Subject.Pauser);
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
    ///      `nonReentrant`; its revert propagates and unwinds everything (001 FR-025/FR-026).
    ///
    ///      The credited amount comes solely from `msg.value`. `address(this).balance` is never
    ///      read, so funds forced in via SELFDESTRUCT cannot inflate a credit or corrupt
    ///      reconciliation (001 FR-008, INV-9).
    function _topUp(address beneficiary) internal nonReentrant whenNotPaused {
        uint256 amount = msg.value;

        // --- CHECKS ---
        if (amount == 0) revert ZeroAmount();
        if (amount < MIN_TOPUP) revert BelowMinimum(amount, MIN_TOPUP);
        if (beneficiary == address(0)) revert ZeroBeneficiary();

        // Cache the destination so the emitted record names the address that actually received
        // the funds, even if a rotation is applied in the same block (001 edge case).
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
        // arbitrary-send-eth: `destination` is NOT user-controlled. It is `treasury`, which only
        //   changes through a quorum-approved proposal that has served a full 2-day delay
        //   (002 FR-001/FR-005). A plain `transfer`/`send` cannot be used: their 2300-gas stipend
        //   breaks for a contract treasury, including a Safe, which is the intended production
        //   destination (research R-006). The return value IS checked on the next line.
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

    /*//////////////////////////////////////////////////////////////
                       INTERNAL: PENDING-CHANGE ENGINE
    //////////////////////////////////////////////////////////////*/

    /// @dev Records a proposal, always with a full fresh delay.
    function _propose(Subject subject, address target) internal {
        _requireValidAddress(target);

        // Justification for the suppression below: uint64 holds ~1.8e19 seconds, so this
        // truncates no earlier than roughly the year 584 billion. uint64 is used rather than
        // uint256 so `target` (20 bytes) and `eta` (8 bytes) pack into a single storage slot,
        // halving the cost of every proposal.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 eta = uint64(block.timestamp + DELAY);

        PendingChange storage slot = _pendingSlot(subject);
        slot.target = target;
        slot.eta = eta;

        emit ChangeProposed(subject, target, eta);
    }

    /// @dev Validates and consumes a pending change, returning its target.
    ///      Reverts unless a proposal exists AND its delay has fully elapsed. The slot is cleared
    ///      before the caller writes the new value, so a change can never be applied twice.
    function _applyPending(Subject subject) internal returns (address target) {
        PendingChange storage slot = _pendingSlot(subject);
        target = slot.target;

        if (target == address(0)) revert NoPendingChange();
        // Justification for the suppression below: timestamp dependence is deliberate here
        // (research R-007). Validators can nudge a timestamp by seconds; against a 172,800-second
        // delay that is immaterial and cannot bring a change forward by any meaningful amount. A
        // block-count delay was rejected because Arc's block time is not guaranteed stable, so
        // N blocks would not reliably mean two days - the property the spec actually requires.
        // slither-disable-start timestamp
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < slot.eta) revert TimelockNotElapsed(block.timestamp, slot.eta);
        // slither-disable-end timestamp

        delete slot.target;
        delete slot.eta;
    }

    /// @dev Clears a pending change, making it permanently unapplicable.
    function _cancel(Subject subject) internal {
        PendingChange storage slot = _pendingSlot(subject);
        address target = slot.target;

        if (target == address(0)) revert NoPendingChange();

        delete slot.target;
        delete slot.eta;

        emit ChangeCancelled(subject, target);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Resolves a subject to its storage slot. One slot per subject makes 002 FR-012
    ///      ("never two applicable pending changes") structurally true rather than something
    ///      enforced by a check that could be wrong.
    function _pendingSlot(Subject subject) internal view returns (PendingChange storage slot) {
        if (subject == Subject.Treasury) return pendingTreasury;
        if (subject == Subject.Admin) return pendingAdmin;
        return pendingPauser;
    }

    /// @dev Rejects the zero address and this contract's own address. Used on every governance
    ///      write so the system can never be left ungovernable or pointed at itself.
    function _requireValidAddress(address candidate) internal view {
        if (candidate == address(0)) revert ZeroAddress();
        if (candidate == address(this)) revert SelfAddress();
    }
}

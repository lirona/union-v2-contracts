//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {SafeCastUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";

import {Controller} from "../Controller.sol";
import {IAssetManager} from "../interfaces/IAssetManager.sol";
import {IUserManager} from "../interfaces/IUserManager.sol";
import {IComptroller} from "../interfaces/IComptroller.sol";
import {IUnionToken} from "../interfaces/IUnionToken.sol";
import {IUToken} from "../interfaces/IUToken.sol";

/**
 * @title UserManager Contract
 * @dev Manages the Union members stake and vouches.
 */
contract UserManager is Controller, IUserManager, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeCastUpgradeable for uint256;
    using SafeCastUpgradeable for uint128;

    /* -------------------------------------------------------------------
      Storage Types 
    ------------------------------------------------------------------- */

    struct Vouch {
        // staker receiving the vouch
        address staker;
        // trust amount
        uint96 trust;
        // message from voucher about the vouchee
        string message;
        // amount of stake locked by this vouch
        uint96 locked;
        // only update when lockedCoinAge is updated
        uint64 lastUpdated;
    }

    struct Staker {
        bool isMember;
        uint96 stakedAmount;
        uint96 locked;
        uint64 lastUpdated; // only update when stakedCoinAge is updated
        uint256 stakedCoinAge;
        uint256 lockedCoinAge;
    }

    struct Index {
        bool isSet;
        uint128 idx;
    }

    struct Vouchee {
        address borrower;
        uint96 voucherIndex;
    }

    /* -------------------------------------------------------------------
      Memory Types 
    ------------------------------------------------------------------- */

    struct CoinAge {
        uint256 stakedCoinAge;
        uint256 lockedCoinAge;
        uint256 frozenCoinAge;
        uint256 sinceLastWithdrawRewards;
    }

    /* -------------------------------------------------------------------
      Storage 
    ------------------------------------------------------------------- */

    /**
     *  @dev Max amount that can be staked of the staking token
     */
    uint96 public maxStakeAmount;

    /**
     *  @dev The staking token that is staked in the comptroller
     */
    address public stakingToken;

    /**
     *  @dev Address of the UNION token contract
     */
    address public unionToken;

    /**
     *  @dev Address of the asset manager contract
     */
    address public assetManager;

    /**
     *  @dev uToken contract
     */
    IUToken public uToken;

    /**
     *  @dev Comptroller contract
     */
    IComptroller public comptroller;

    /**
     * @dev Number of vouches needed to become a member
     */
    uint256 public effectiveCount;

    /**
     *  @dev New member fee
     */
    uint256 public newMemberFee;

    /**
     *  @dev Total amount of staked staked token
     */
    uint256 public totalStaked;

    /**
     *  @dev Total amount of stake frozen
     */
    uint256 public totalFrozen;

    /**
     *  @dev Max duration (in seconds) can be overdue for
     */
    uint256 public maxOverdueTime;

    /**
     * @dev Max voucher limit
     */
    uint256 public maxVouchers;

    /**
     * @dev Max vouchees limit
     */
    uint256 public maxVouchees;

    /**
     *  @dev Union Stakers
     */
    mapping(address => Staker) public stakers;

    /**
     *  @dev Borrower (borrower) mapped to received vouches (staker)
     */
    mapping(address => Vouch[]) public vouchers;

    /**
     * @dev Borrower mapped to Staker mapped to index in vouchers array
     */
    mapping(address => mapping(address => Index)) public voucherIndexes;

    /**
     *  @dev Staker (staker) mapped to vouches given (borrower)
     */
    mapping(address => Vouchee[]) public vouchees;

    /**
     * @dev Borrower mapped to Staker mapped to index in vochee array
     */
    mapping(address => mapping(address => Index)) public voucheeIndexes;

    /**
     * @dev Stakers frozen amounts
     */
    mapping(address => uint256) public memberFrozen;

    /**
     * @dev Stakers mapped to frozen coin age
     */
    mapping(address => uint256) public frozenCoinAge;

    /**
     * @dev Stakers mapped the block timestamp of latest rewards withdrawal
     */
    mapping(address => uint256) public gLastWithdrawRewards;

    /* -------------------------------------------------------------------
      Errors 
    ------------------------------------------------------------------- */

    error AuthFailed();
    error ErrorSelfVouching();
    error TrustAmountLtLocked();
    error NoExistingMember();
    error NotEnoughStakers();
    error StakeLimitReached();
    error AssetManagerDepositFailed();
    error AssetManagerWithdrawFailed();
    error InsufficientBalance();
    error LockedStakeNonZero();
    error NotOverdue();
    error ExceedsLocked();
    error AmountZero();
    error LockedRemaining();
    error VoucherNotFound();
    error VouchWhenOverdue();
    error MaxVouchers();
    error MaxVouchees();
    error InvalidParams();

    /* -------------------------------------------------------------------
      Events 
    ------------------------------------------------------------------- */

    /**
     *  @dev Add new member event
     *  @param member New member address
     */
    event LogAddMember(address member);

    /**
     *  @dev Update vouch for existing member event
     *  @param staker Trustee address
     *  @param borrower The address gets vouched for
     *  @param trustAmount Vouch amount
     *  @param message Message from voucher about the vouchee
     */
    event LogUpdateTrust(address indexed staker, address indexed borrower, uint256 trustAmount, string message);

    /**
     *  @dev New member application event
     *  @param account New member's voucher address
     *  @param borrower New member address
     */
    event LogRegisterMember(address indexed account, address indexed borrower);

    /**
     *  @dev Cancel vouching for other member event
     *  @param account New member's voucher address
     *  @param borrower The address gets vouched for
     */
    event LogCancelVouch(address indexed account, address indexed borrower);

    /**
     *  @dev Stake event
     *  @param account The staker's address
     *  @param amount The amount of tokens to stake
     */
    event LogStake(address indexed account, uint256 amount);

    /**
     *  @dev Unstake event
     *  @param account The staker's address
     *  @param amount The amount of tokens to unstake
     */
    event LogUnstake(address indexed account, uint256 amount);

    /**
     *  @dev DebtWriteOff event
     *  @param staker The staker's address
     *  @param borrower The borrower's address
     *  @param amount The amount of write off
     */
    event LogDebtWriteOff(address indexed staker, address indexed borrower, uint256 amount);

    /**
     *  @dev set utoken address
     *  @param uToken new uToken address
     */
    event LogSetUToken(address uToken);

    /**
     *  @dev set new member fee
     *  @param oldMemberFee old member fee
     *  @param newMemberFee new member fee
     */
    event LogSetNewMemberFee(uint256 oldMemberFee, uint256 newMemberFee);

    /**
     *  @dev set max stake amount
     *  @param oldMaxStakeAmount Old amount
     *  @param newMaxStakeAmount New amount
     */
    event LogSetMaxStakeAmount(uint256 oldMaxStakeAmount, uint256 newMaxStakeAmount);

    /**
     *  @dev set max overdue time
     *  @param oldMaxOverdueTime Old value
     *  @param newMaxOverdueTime New value
     */
    event LogSetMaxOverdueTime(uint256 oldMaxOverdueTime, uint256 newMaxOverdueTime);

    /**
     *  @dev set effective count
     *  @param oldEffectiveCount Old value
     *  @param newEffectiveCount New value
     */
    event LogSetEffectiveCount(uint256 oldEffectiveCount, uint256 newEffectiveCount);

    /**
     * @dev Set max voucher
     * @param maxVouchers new max voucher limit
     */
    event LogSetMaxVouchers(uint256 maxVouchers);

    /**
     * @dev Set max vouchees
     * @param maxVouchees new max voucher limit
     */
    event LogSetMaxVouchees(uint256 maxVouchees);

    /* -------------------------------------------------------------------
      Constructor/Initializer 
    ------------------------------------------------------------------- */

    function __UserManager_init(
        address assetManager_,
        address unionToken_,
        address stakingToken_,
        address comptroller_,
        address admin_,
        uint256 maxOverdueTime_,
        uint256 effectiveCount_,
        uint256 maxVouchers_,
        uint256 maxVouchees_
    ) public initializer {
        Controller.__Controller_init(admin_);
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        comptroller = IComptroller(comptroller_);
        assetManager = assetManager_;
        unionToken = unionToken_;
        stakingToken = stakingToken_;
        newMemberFee = 1 ether;
        maxStakeAmount = 10_000e18;
        maxOverdueTime = maxOverdueTime_;
        effectiveCount = effectiveCount_;
        maxVouchers = maxVouchers_;
        maxVouchees = maxVouchees_;
    }

    /* -------------------------------------------------------------------
      Modifiers 
    ------------------------------------------------------------------- */

    modifier onlyMember(address account) {
        if (!checkIsMember(account)) revert AuthFailed();
        _;
    }

    modifier onlyMarket() {
        if (address(uToken) != msg.sender) revert AuthFailed();
        _;
    }

    /* -------------------------------------------------------------------
      Setters 
    ------------------------------------------------------------------- */

    /**
     * @dev Set the max amount that a user can stake
     * Emits {LogSetMaxStakeAmount} event
     * @param maxStakeAmount_ The max stake amount
     */
    function setMaxStakeAmount(uint96 maxStakeAmount_) external onlyAdmin {
        uint96 oldMaxStakeAmount = maxStakeAmount;
        maxStakeAmount = maxStakeAmount_;
        emit LogSetMaxStakeAmount(uint256(oldMaxStakeAmount), uint256(maxStakeAmount));
    }

    /**
     * @dev set the UToken contract address
     * Emits {LogSetUToken} event
     * @param uToken_ UToken contract address
     */
    function setUToken(address uToken_) external onlyAdmin {
        uToken = IUToken(uToken_);
        emit LogSetUToken(uToken_);
    }

    /**
     * @dev set New Member fee
     * @dev The amount of UNION an account must burn to become a member
     * Emits {LogSetNewMemberFee} event
     * @param amount New member fee amount
     */
    function setNewMemberFee(uint256 amount) external onlyAdmin {
        uint256 oldMemberFee = newMemberFee;
        newMemberFee = amount;
        emit LogSetNewMemberFee(oldMemberFee, amount);
    }

    /**
     * @dev set New max overdue timestamp
     * Emits {LogSetMaxOverdueTime} event
     * @param _maxOverdueTime New maxOverdueTime value
     */
    function setMaxOverdueTime(uint256 _maxOverdueTime) external onlyAdmin {
        uint256 oldMaxOverdueTime = maxOverdueTime;
        maxOverdueTime = _maxOverdueTime;
        emit LogSetMaxOverdueTime(oldMaxOverdueTime, _maxOverdueTime);
    }

    /**
     * @dev set New effective count
     * @dev this is the number of vouches an account needs in order
     *      to register as a member
     * Emits {LogSetEffectiveCount} event
     * @param _effectiveCount New effectiveCount value
     */
    function setEffectiveCount(uint256 _effectiveCount) external onlyAdmin {
        uint256 oldEffectiveCount = effectiveCount;
        effectiveCount = _effectiveCount;
        emit LogSetEffectiveCount(oldEffectiveCount, _effectiveCount);
    }

    function setMaxVouchers(uint256 _maxVouchers) external onlyAdmin {
        maxVouchers = _maxVouchers;
        emit LogSetMaxVouchers(_maxVouchers);
    }

    function setMaxVouchees(uint256 _maxVouchees) external onlyAdmin {
        maxVouchees = _maxVouchees;
        emit LogSetMaxVouchees(_maxVouchees);
    }

    /* -------------------------------------------------------------------
      View Functions 
    ------------------------------------------------------------------- */

    /**
     *  @dev Check if the account is a valid member
     *  @param account Member address
     *  @return Address whether is member
     */
    function checkIsMember(address account) public view returns (bool) {
        return stakers[account].isMember;
    }

    /**
     *  @dev  Get the member's available credit limit
     *  @dev  IMPORTANT: This function can take up a tonne of gas as the vouchers[address] array
     *        grows in size. the maxVoucher limit will ensure this function can always run within a
     *        single block but it is intended only to be used as a view function called from a UI
     *  @param borrower Member address
     *  @return total Credit line amount
     */
    function getCreditLimit(address borrower) external view returns (uint256 total) {
        for (uint256 i = 0; i < vouchers[borrower].length; i++) {
            Vouch memory vouch = vouchers[borrower][i];
            Staker memory staker = stakers[vouch.staker];
            total += _min(staker.stakedAmount - staker.locked, vouch.trust - vouch.locked);
        }
    }

    /**
     *  @dev  Get the count of vouchers
     *        Vouchers are addresses that this borrower is receiving a vouch from.
     *  @param borrower Address of borrower
     */
    function getVoucherCount(address borrower) external view returns (uint256) {
        return vouchers[borrower].length;
    }

    /**
     *  @dev  Get the count of vouchees
     *        Vouchers are addresses that this staker is vouching for
     *  @param staker Address of staker
     */
    function getVoucheeCount(address staker) external view returns (uint256) {
        return vouchees[staker].length;
    }

    /**
     *  @dev Get the user's deposited stake amount
     *  @param account Member address
     *  @return Deposited stake amount
     */
    function getStakerBalance(address account) external view returns (uint256) {
        return stakers[account].stakedAmount;
    }

    /**
     *  @dev Get Total locked stake
     *  @param staker Staker address
     */
    function getTotalLockedStake(address staker) external view returns (uint256) {
        return stakers[staker].locked;
    }

    /**
     *  @dev Get staker locked stake for a borrower
     *  @param staker Staker address
     *  @param borrower Borrower address
     *  @return LockedStake
     */
    function getLockedStake(address staker, address borrower) external view returns (uint256) {
        Index memory index = voucherIndexes[borrower][staker];
        if (!index.isSet) return 0;
        return vouchers[borrower][index.idx].locked;
    }

    /**
     *  @dev Get vouching amount
     *  @param _staker Staker address
     *  @param borrower Borrower address
     */
    function getVouchingAmount(address _staker, address borrower) external view returns (uint256) {
        Index memory index = voucherIndexes[borrower][_staker];
        Staker memory staker = stakers[_staker];
        if (!index.isSet) return 0;
        uint96 trustAmount = vouchers[borrower][index.idx].trust;
        return trustAmount < staker.stakedAmount ? trustAmount : staker.stakedAmount;
    }

    /* -------------------------------------------------------------------
      Core Functions 
    ------------------------------------------------------------------- */

    /**
     *  @dev Manually add union members and bypass all the requirements of `registerMember`
     *  Only accepts calls from the admin
     *  Emit {LogAddMember} event
     *  @param account Member address
     */
    function addMember(address account) external onlyAdmin {
        stakers[account].isMember = true;
        emit LogAddMember(account);
    }

    /**
     *  @dev  Update the trust amount for existing members.
     *  @dev  Trust is the amount of the underlying token you would in theory be
     *        happy to lend to another member. Vouch is derived from trust and stake.
     *        Vouch is the minimum of trust and staked amount.
     *  Emits {LogUpdateTrust} event
     *  @param borrower Account address
     *  @param trustAmount Trust amount
     */
    function updateTrust(address borrower, uint96 trustAmount, string message) external onlyMember(msg.sender) whenNotPaused {
        address staker = msg.sender;
        if (borrower == staker) revert ErrorSelfVouching();

        // Check if this staker is already vouching for this borrower
        // If they are already vouching then update the existing vouch record
        // If this is a new vouch then insert a new Vouch record
        Index memory index = voucherIndexes[borrower][staker];
        if (index.isSet) {
            // Update existing record checking that the new trust amount is
            // not less than the amount of stake currently locked by the borrower
            Vouch storage vouch = vouchers[borrower][index.idx];
            if (trustAmount < vouch.locked) revert TrustAmountLtLocked();
            vouch.trust = trustAmount;
            vouch.message = message;
        } else {
            // If the member is overdue they cannot create new vouches they can
            // only update existing vouches
            if (uToken.checkIsOverdue(staker)) revert VouchWhenOverdue();

            // This is a new vouch so we need to check that the
            // member has not reached the max voucher limit
            uint256 voucheeIndex = vouchees[staker].length;
            if (voucheeIndex >= maxVouchees) revert MaxVouchees();

            // Get the new index that this vouch is going to be inserted at
            // Then update the voucher indexes for this borrower as well as
            // Adding the Vouch the the vouchers array for this staker
            uint256 voucherIndex = vouchers[borrower].length;
            if (voucherIndex >= maxVouchers) revert MaxVouchers();
            voucherIndexes[borrower][staker] = Index(true, voucherIndex.toUint128());
            vouchers[borrower].push(Vouch(staker, trustAmount, message, 0, 0));

            // Add the voucherIndex of this new vouch to the vouchees array for this
            // staker then update the voucheeIndexes with the voucheeIndex
            vouchees[staker].push(Vouchee(borrower, voucherIndex.toUint96()));
            voucheeIndexes[borrower][staker] = Index(true, voucheeIndex.toUint128());
        }

        emit LogUpdateTrust(staker, borrower, trustAmount, message);
    }

    /**
     *  @dev Remove voucher for member
     *  Can be called by either the borrower or the staker. It will remove the voucher from
     *  the voucher array by replacing it with the last item of the array and resting the array
     *  size to -1 by popping off the last item
     *  Only callable by a member when the contract is not paused
     *  Emit {LogCancelVouch} event
     *  @param staker Staker address
     *  @param borrower borrower address
     */
    function _cancelVouchInternal(address staker, address borrower) internal {
        Index memory removeVoucherIndex = voucherIndexes[borrower][staker];
        if (!removeVoucherIndex.isSet) revert VoucherNotFound();

        // Check that the locked amount for this vouch is 0
        Vouch memory vouch = vouchers[borrower][removeVoucherIndex.idx];
        if (vouch.locked > 0) revert LockedStakeNonZero();

        // Remove borrower from vouchers array by moving the last item into the position
        // of the index being removed and then popping the last item off the array
        {
            // Cache the last voucher
            Vouch memory lastVoucher = vouchers[borrower][vouchers[borrower].length - 1];
            // Move the lastVoucher to the index of the voucher we are removing
            vouchers[borrower][removeVoucherIndex.idx] = lastVoucher;
            // Pop the last vouch off the end of the vouchers array
            vouchers[borrower].pop();
            // Delete the voucher index for this borrower => staker pair
            delete voucherIndexes[borrower][staker];
            // Update the last vouchers corresponding Vouchee item
            uint128 voucheeIdx = voucheeIndexes[borrower][lastVoucher.staker].idx;
            vouchees[lastVoucher.staker][voucheeIdx].voucherIndex = removeVoucherIndex.idx.toUint96();
            // Update the voucher indexes of the moved pair to the new voucher index
            voucherIndexes[borrower][lastVoucher.staker].idx = removeVoucherIndex.idx;
        }

        // Update the vouchee entry for this borrower => staker pair
        {
            Index memory removeVoucheeIndex = voucheeIndexes[borrower][staker];
            // Cache the last vouchee
            Vouchee memory lastVouchee = vouchees[staker][vouchees[staker].length - 1];
            // Move the last vouchee to the index of the removed vouchee
            vouchees[staker][removeVoucheeIndex.idx] = lastVouchee;
            // Pop the last vouchee off the end of the vouchees array
            vouchees[staker].pop();
            // Delete the vouchee index for this borrower => staker pair
            delete voucheeIndexes[borrower][staker];
            // Update the vouchee indexes to the new vouchee index
            voucheeIndexes[lastVouchee.borrower][staker].idx = removeVoucheeIndex.idx;
        }

        emit LogCancelVouch(staker, borrower);
    }

    /**
     *  Cancels a vouch between a staker and a borrower.
     *  @dev The function can only be called by a member of the stakers list.
     *  @param staker The address of the staker who made the vouch.
     *  @param borrower The address of the borrower who received the vouch.
     */
    function cancelVouch(address staker, address borrower) public onlyMember(msg.sender) whenNotPaused {
        if (staker != msg.sender && borrower != msg.sender) revert AuthFailed();
        _cancelVouchInternal(staker, borrower);
    }

    /**
     *  @notice Register a a member using a signed permit
     *  @dev See registerMember
     *  @param newMember New member address
     *  @param value Amount approved by permit
     *  @param deadline Timestamp for when the permit expires
     *  @param v secp256k1 signature part
     *  @param r secp256k1 signature part
     *  @param s secp256k1 signature part
     */
    function registerMemberWithPermit(
        address newMember,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused {
        IUnionToken(unionToken).permit(msg.sender, address(this), value, deadline, v, r, s);
        registerMember(newMember);
    }

    /**
     *  @notice Register a a member, and burn the application fee
     *  @dev    In order to register as a member an address must be receiving x amount
     *          of vouches greater than 0 from stakers. x is defined by `effectiveCount`
     *          Emits {LogRegisterMember} event
     *  @param newMember New member address
     */
    function registerMember(address newMember) public virtual whenNotPaused {
        _validateNewMember(newMember);

        IUnionToken(unionToken).burnFrom(msg.sender, newMemberFee);

        emit LogRegisterMember(msg.sender, newMember);
    }

    /**
     *  @notice Stake staking tokens
     *  @dev    Stake is used to underwrite loans and becomes locked if a
     *          member a staker has vouched for borrows against it.
     *          Stake also earns rewards from the comptroller
     *  Emits a {LogStake} event.
     *  @param amount Amount to stake
     */
    function stake(uint96 amount) public whenNotPaused nonReentrant {
        IERC20Upgradeable erc20Token = IERC20Upgradeable(stakingToken);

        comptroller.withdrawRewards(msg.sender, stakingToken);

        Staker storage staker = stakers[msg.sender];

        if (staker.stakedAmount + amount > maxStakeAmount) revert StakeLimitReached();

        staker.stakedAmount += amount;
        totalStaked += amount;

        erc20Token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 currentAllowance = erc20Token.allowance(address(this), assetManager);
        if (currentAllowance < amount) {
            erc20Token.safeIncreaseAllowance(assetManager, amount - currentAllowance);
        }

        if (!IAssetManager(assetManager).deposit(stakingToken, amount)) revert AssetManagerDepositFailed();
        emit LogStake(msg.sender, amount);
    }

    /**
     *  @notice Unstake staking token
     *  @dev    Tokens can only be unstaked if they are not locked. ie a
     *          vouchee is not borrowing against them.
     *  Emits {LogUnstake} event
     *  @param amount Amount to unstake
     */
    function unstake(uint96 amount) external whenNotPaused nonReentrant {
        Staker storage staker = stakers[msg.sender];

        // Stakers can only unstaked stake balance that is unlocked. Stake balance
        // becomes locked when it is used to underwrite a borrow.
        if (staker.stakedAmount - staker.locked < amount) revert InsufficientBalance();

        comptroller.withdrawRewards(msg.sender, stakingToken);

        uint256 remaining = IAssetManager(assetManager).withdraw(stakingToken, msg.sender, amount);
        if (remaining > amount) {
            revert AssetManagerWithdrawFailed();
        }
        uint96 actualAmount = amount - remaining.toUint96();

        staker.stakedAmount -= actualAmount;
        totalStaked -= actualAmount;

        emit LogUnstake(msg.sender, actualAmount);
    }

    /**
     *  @dev collect staker rewards from the comptroller
     */
    function withdrawRewards() external whenNotPaused nonReentrant {
        comptroller.withdrawRewards(msg.sender, stakingToken);
    }

    /**
     *  @notice Write off a borrowers debt
     *  @dev    Used the stakers locked stake to write off the loan, transferring the
     *          Stake to the AssetManager and adjusting balances in the AssetManager
     *          and the UToken to repay the principal
     *  @dev    Emits {LogDebtWriteOff} event
     *  @param stakerAddress address of staker
     *  @param borrowerAddress address of borrower
     *  @param amount amount to writeoff
     */
    function debtWriteOff(address stakerAddress, address borrowerAddress, uint256 amount) external {
        if (amount == 0) revert AmountZero();
        uint256 overdueTime = uToken.overdueTime();
        uint256 lastRepay = uToken.getLastRepay(borrowerAddress);
        uint256 currTime = getTimestamp();

        // This function is only callable by the public if the loan is overdue by
        // overdue time + maxOverdueTime. This stops the system being left with
        // debt that is overdue indefinitely and no ability to do anything about it.
        if (currTime <= lastRepay + overdueTime + maxOverdueTime) {
            if (stakerAddress != msg.sender) revert AuthFailed();
        }

        Index memory index = voucherIndexes[borrowerAddress][stakerAddress];
        if (!index.isSet) revert VoucherNotFound();
        Vouch storage vouch = vouchers[borrowerAddress][index.idx];
        uint256 locked = vouch.locked;
        if (amount > locked) revert ExceedsLocked();

        comptroller.accrueRewards(stakerAddress, stakingToken);

        Staker storage staker = stakers[stakerAddress];

        staker.stakedAmount -= amount.toUint96();
        staker.locked -= amount.toUint96();
        staker.lastUpdated = currTime.toUint64();

        totalStaked -= amount;

        // update vouch trust amount
        vouch.trust -= amount.toUint96();
        vouch.locked -= amount.toUint96();
        vouch.lastUpdated = currTime.toUint64();

        // Update total frozen and member frozen. We don't want to move th
        // burden of calling updateFrozenInfo into this function as it is quite
        // gas intensive. Instead we just want to remove the amount that was
        // frozen which is now being written off. However, it is possible that
        // member frozen has not been updated prior to calling debtWriteOff and
        // the amount being written off could be greater than the amount frozen.
        // To avoid an underflow here we need to check this condition
        uint256 stakerFrozen = memberFrozen[stakerAddress];
        if (amount > stakerFrozen) {
            // The amount being written off is more than the amount that has
            // been previously frozen for this staker. Reset their frozen stake
            // to zero and adjust totalFrozen
            memberFrozen[stakerAddress] = 0;
            totalFrozen -= stakerFrozen;
        } else {
            totalFrozen -= amount;
            memberFrozen[stakerAddress] -= amount;
        }

        if (vouch.trust == 0) {
            _cancelVouchInternal(stakerAddress, borrowerAddress);
        }

        // Notify the AssetManager and the UToken market of the debt write off
        // so they can adjust their balances accordingly
        IAssetManager(assetManager).debtWriteOff(stakingToken, amount);
        uToken.debtWriteOff(borrowerAddress, amount);
        emit LogDebtWriteOff(msg.sender, borrowerAddress, amount);
    }

    /**
     *  @notice Borrowing from the market
     *  @dev    Locks/Unlocks the borrowers stakers staked amounts in a first in
     *          First out order. Meaning the members that vouched for this borrower
     *          first will be the first members to get their stake locked or unlocked
     *          following a borrow or repayment.
     *  @param borrower The address of the borrower
     *  @param amount Lock/Unlock amount
     *  @param lock If the amount is being locked or unlocked
     */
    function updateLocked(address borrower, uint256 amount, bool lock) external onlyMarket {
        uint96 remaining = (amount).toUint96();
        uint96 innerAmount = 0;
        Staker storage staker;
        uint256 currTime = getTimestamp();

        uint256 vouchersLength = vouchers[borrower].length;
        for (uint256 i = 0; i < vouchersLength; i++) {
            Vouch storage vouch = vouchers[borrower][i];
            staker = stakers[vouch.staker];

            staker.lockedCoinAge += _calcLockedCoinAge(currTime, vouch.locked, staker.lastUpdated, vouch.lastUpdated);

            vouch.lastUpdated = currTime.toUint64();
            if (lock) {
                // Look up the staker and determine how much unlock stake they
                // have available for the borrower to borrow. If there is 0
                // then continue to the next voucher in the array
                uint96 availableStake = staker.stakedAmount - staker.locked;
                uint96 lockAmount = _min(availableStake, vouch.trust - vouch.locked);
                if (lockAmount == 0) continue;
                // Calculate the amount to add to the lock then
                // add the extra amount to lock to the stakers locked amount
                // and also update the vouches locked amount and lastUpdated timestamp
                innerAmount = _min(remaining, lockAmount);
                staker.locked += innerAmount;
                vouch.locked += innerAmount;
            } else {
                // Look up how much this vouch has locked. If it is 0 then
                // continue to the next voucher. Then calculate the amount to
                // unlock which is the min of the vouches lock and what is
                // remaining to unlock
                uint96 locked = vouch.locked;
                if (locked == 0) continue;
                innerAmount = _min(locked, remaining);
                // Update the stored locked values and last updated timestamp
                staker.locked -= innerAmount;
                vouch.locked -= innerAmount;
            }

            remaining -= innerAmount;
            // If there is no remaining amount to lock/unlock
            // we can stop looping through vouchers
            if (remaining <= 0) break;
        }

        // If we have looped through all the available vouchers for this
        // borrower and we still have a remaining amount then we have to
        // revert as there is not enough vouchers to lock/unlock
        if (remaining > 0) revert LockedRemaining();
    }

    /**
     * @dev Get the staker's latest info based on stored coinage
     * @param stakerAddress Staker address
     * @return  user's effective staked amount
     * @return  user's effective locked amount
     * @return  user's frozen amount
     */
    function _getEffectiveAmounts(address stakerAddress) private view returns (uint256, uint256, uint256) {
        Staker memory staker = stakers[stakerAddress];
        uint256 currTime = getTimestamp();

        CoinAge memory stakerCoinAges = CoinAge({
            stakedCoinAge: staker.stakedCoinAge,
            lockedCoinAge: staker.lockedCoinAge,
            frozenCoinAge: frozenCoinAge[stakerAddress],
            sinceLastWithdrawRewards: currTime - gLastWithdrawRewards[stakerAddress]
        });

        // update staked coin age
        stakerCoinAges.stakedCoinAge += _calcStakedCoinAge(currTime, staker.stakedAmount, staker.lastUpdated);

        // Loop through all of the stakers vouchees sum their total
        // locked balance and sum their total currDefaultFrozenCoinAge
        uint256 voucheesLength = vouchees[stakerAddress].length;
        uint256 lastRepay = 0;
        uint256 stakerFrozen = 0;
        Vouchee memory vouchee;
        Vouch memory vouch;
        uint256 overdueTime = uToken.overdueTime();
        for (uint256 i = 0; i < voucheesLength; i++) {
            // Get the vouchee record and look up the borrowers voucher record
            // to get the locked amount and lastUpdated time
            vouchee = vouchees[stakerAddress][i];
            vouch = vouchers[vouchee.borrower][vouchee.voucherIndex];

            // update locked coin age
            stakerCoinAges.lockedCoinAge += _calcLockedCoinAge(
                currTime,
                vouch.locked,
                staker.lastUpdated,
                vouch.lastUpdated
            );

            // update frozen coin age
            lastRepay = uToken.getLastRepay(vouchee.borrower);
            if (
                (// skip the member never staked
                staker.lastUpdated != 0 &&
                    // skip the debt all repaid
                    lastRepay != 0)
            ) {
                if (currTime - lastRepay > overdueTime) // for the debt overdue
                {
                    stakerFrozen += vouch.locked;
                    stakerCoinAges.frozenCoinAge += _calcFrozenCoinAge(
                        currTime,
                        vouch.locked,
                        staker.lastUpdated,
                        lastRepay + overdueTime
                    );
                }
            }
        }

        if (stakerCoinAges.sinceLastWithdrawRewards == 0) {
            return (
                staker.stakedAmount - stakerFrozen, // effective staked
                staker.locked - stakerFrozen, // effective locked
                stakerFrozen
            );
        } else {
            return (
                // staker's total effective staked = (staked coinage - frozen coinage) / (time since last rewards withdrawal)
                (stakerCoinAges.stakedCoinAge - stakerCoinAges.frozenCoinAge) / stakerCoinAges.sinceLastWithdrawRewards,
                // effective locked amount = (locked coinage - frozen coinage) / (time since last rewards withdrawal)
                (stakerCoinAges.lockedCoinAge - stakerCoinAges.frozenCoinAge) / stakerCoinAges.sinceLastWithdrawRewards,
                stakerFrozen
            );
        }
    }

    /**
     *  @dev Get the staker's effective staked and locked amount
     *  @param staker Staker address
     *  @return isMember
     *          effectiveStaked user's effective staked amount
     *          effectiveLocked user's effective locked amount
     *          staker's total frozen amount
     */
    function getStakeInfo(
        address staker
    ) external view returns (bool isMember, uint256 effectiveStaked, uint256 effectiveLocked, uint256 stakerFrozen) {
        (effectiveStaked, effectiveLocked, stakerFrozen) = _getEffectiveAmounts(staker);
        isMember = stakers[staker].isMember;
    }

    /**
     * @dev Update the frozen info by the comptroller when withdraw rewards is called
     * @param staker Staker address
     * @return  effectiveStaked user's total stake - frozen
     *          effectiveLocked user's locked amount - frozen
     *          isMember
     */
    function onWithdrawRewards(
        address staker
    ) external returns (uint256 effectiveStaked, uint256 effectiveLocked, bool isMember) {
        if (address(comptroller) != msg.sender) revert AuthFailed();
        uint256 memberTotalFrozen = 0;
        (effectiveStaked, effectiveLocked, memberTotalFrozen) = _getEffectiveAmounts(staker);
        stakers[staker].stakedCoinAge = 0;
        uint256 currTime = getTimestamp();
        stakers[staker].lastUpdated = currTime.toUint64();
        gLastWithdrawRewards[staker] = currTime;
        stakers[staker].lockedCoinAge = 0;
        frozenCoinAge[staker] = 0;

        uint256 memberFrozenBefore = memberFrozen[staker];
        if (memberFrozenBefore != memberTotalFrozen) {
            memberFrozen[staker] = memberTotalFrozen;
            totalFrozen = totalFrozen - memberFrozenBefore + memberTotalFrozen;
        }

        isMember = stakers[staker].isMember;
    }

    /**
     * @dev Make sure only update the frozen info when borrower's overdue
     * @param borrower Borrower address
     * @param overdueTime Timestamp since last repay
     */
    function onRepayBorrow(address borrower, uint256 overdueTime) external {
        if (address(uToken) != msg.sender) revert AuthFailed();

        Vouch[] memory borrowerVouchers = vouchers[borrower];
        uint256 vouchersLength = borrowerVouchers.length;
        Vouch memory vouch;
        uint256 currTime = getTimestamp();
        // assuming the borrower's already overdue, accumulating all his vouchers' previous frozen coin age
        for (uint256 i = 0; i < vouchersLength; i++) {
            vouch = borrowerVouchers[i];
            if (vouch.locked == 0) continue;
            frozenCoinAge[vouch.staker] += _calcFrozenCoinAge(
                currTime,
                vouch.locked,
                stakers[vouch.staker].lastUpdated,
                overdueTime
            );
        }
    }

    /**
     * @dev Update the frozen info for external scripts
     * @param stakerList Stakers address
     */
    function batchUpdateFrozenInfo(address[] calldata stakerList) external whenNotPaused {
        uint256 stakerLength = stakerList.length;
        if (stakerLength == 0) revert InvalidParams();

        // update member's frozen amount and global frozen amount
        uint256 tmpTotalFrozen = totalFrozen;
        address staker = address(0);
        for (uint256 i = 0; i < stakerLength; i++) {
            staker = stakerList[i];
            (, , uint256 memberTotalFrozen) = _getEffectiveAmounts(staker);

            uint256 memberFrozenBefore = memberFrozen[staker];
            if (memberFrozenBefore != memberTotalFrozen) {
                memberFrozen[staker] = memberTotalFrozen;
                tmpTotalFrozen = tmpTotalFrozen - memberFrozenBefore + memberTotalFrozen;
            }
        }
        totalFrozen = tmpTotalFrozen;

        comptroller.updateTotalStaked(stakingToken, totalStaked - totalFrozen);
    }

    function globalTotalStaked() external view returns (uint256 globalTotal) {
        globalTotal = totalStaked - totalFrozen;
    }

    /* -------------------------------------------------------------------
       Internal Functions 
    ------------------------------------------------------------------- */

    function _min(uint96 a, uint96 b) private pure returns (uint96) {
        return a < b ? a : b;
    }

    function _max(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }

    function _validateNewMember(address newMember) internal {
        if (stakers[newMember].isMember) revert NoExistingMember();

        uint256 count = 0;
        uint256 vouchersLength = vouchers[newMember].length;
        Vouch memory vouch;
        Staker memory staker;

        // Loop through all the vouchers to count how many active vouches there
        // are that are greater than 0. Vouch is the min of stake and trust
        for (uint256 i = 0; i < vouchersLength; i++) {
            vouch = vouchers[newMember][i];
            staker = stakers[vouch.staker];
            if (staker.stakedAmount > 0) count++;
            if (count >= effectiveCount) break;
        }

        if (count < effectiveCount) revert NotEnoughStakers();

        stakers[newMember].isMember = true;
    }

    /**
     * @dev Calculate a staker's frozen coin age
     * @param currTime Current timestamp
     * @param locked Stakers locked amount
     * @param lastStakeUpdated Block timestamp when staked coin age is updated
     * @param overdueTime Loan over due period in seconds
     */
    function _calcFrozenCoinAge(
        uint256 currTime,
        uint256 locked,
        uint256 lastStakeUpdated,
        uint256 overdueTime
    ) private pure returns (uint) {
        return locked * (currTime - _max(lastStakeUpdated, overdueTime));
    }

    /**
     * @dev Calculate a staker's locked coin age
     * @param currTime Current timestamp
     * @param locked Stakers locked amount
     * @param lastStakeUpdated Block timestamp when staked coin age is updated
     * @param lastLockedUpdated Block timestamp when locked coin age is updated
     */
    function _calcLockedCoinAge(
        uint256 currTime,
        uint256 locked,
        uint256 lastStakeUpdated,
        uint256 lastLockedUpdated
    ) private pure returns (uint) {
        return locked * (currTime - _max(lastStakeUpdated, lastLockedUpdated));
    }

    /**
     * @dev Calculate a staker's staked coin age
     * @param currTime Current timestamp
     * @param stakedAmount Stakers staked amount
     * @param lastStakeUpdated Block timestamp when staked coin age is updated
     */
    function _calcStakedCoinAge(
        uint256 currTime,
        uint256 stakedAmount,
        uint256 lastStakeUpdated
    ) private pure returns (uint) {
        return stakedAmount * (currTime - lastStakeUpdated);
    }

    /**
     *  @dev Function to simply retrieve block timestamp
     *  This exists mainly for inheriting test contracts to stub this result.
     */
    function getTimestamp() internal view returns (uint256) {
        return block.timestamp;
    }
}

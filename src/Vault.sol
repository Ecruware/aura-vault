// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";
import {ERC20Permit} from "openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IFeed} from "./vendor/IEcruFeed.sol";
import {IPool} from "./vendor/IAuraPool.sol";
import {IVault} from "./interfaces/IVault.sol";

// Authenticated Roles
bytes32 constant VAULT_ADMIN_ROLE = keccak256("VAULT_ADMIN_ROLE");

/// @title AuraVault
/// @notice `A 4626 vault that compounds rewards from an Aura RewardsPool
contract AuraVault is IVault, AccessControl, ERC20Permit, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ========== Storage ========== */

    /// @notice The incentive sent to claimer
    uint256 public claimerIncentive;

    /// @notice The incentive sent to lockers
    uint256 public lockerIncentive;

    /// @notice The locker rewards distributor
    uint256 public lockerRewards;

    /* ========== Constants ========== */

    /// @notice The Aura pool distributing rewards
    address public immutable rewardPool;

    /// @notice The LP token deposited in vault
    address public immutable override asset;

    address public immutable rewardToken;
    address public immutable secondaryRewardToken;

    /// @notice The max permitted claimer incentive
    uint256 public immutable maxClaimerIncentive;

    /// @notice The max permitted locker incentive
    uint256 public immutable maxLockerIncentive;

    /* ========== Events ========== */

    /// @notice `caller` has exchanged `shares`, owned by `owner`, for
    ///         `assets`, and transferred those `assets` to `receiver`.
    event Claimed(
        address indexed caller,
        uint256 rewardTokenClaimed,
        uint256 secondaryRewardTokenClaimed,
        uint256 lpTokenCompounded
    );

    constructor(
        address rewardPool_,
        address asset_,
        address rewardToken_,
        address secondaryRewardToken_,
        uint256 maxClaimerIncentive_,
        uint256 maxLockerIncentive_,
        string memory tokenName_,
        string memory tokenSymbol_
    ) public ERC20(tokenName_, tokenSymbol_) ERC20Permit(tokenName_) {
        asset = asset_;
        IERC20(asset).safeApprove(rewardPool_, type(uint256).max);

        rewardPool = rewardPool_;
        rewardToken = rewardToken_;
        secondaryRewardToken = secondaryRewardToken_;
        maxClaimerIncentive = maxClaimerIncentive_;
        maxLockerIncentive = maxLockerIncentive_;
    }

    /* ========== 4626 Vault ========== */

    /**
     * @notice Total amount of the underlying asset that is "managed" by Vault.
     */
    function totalAssets() external view virtual override returns(uint256){
        return _totalAssets();
    }

    function _totalAssets() internal view virtual returns(uint256){
        return rewardPool.balanceOf(address(this));
    }

    /**
     * @notice Mints `shares` Vault shares to `receiver`.
     * @dev Because `asset` is not actually what is collected here, first wrap to required token in the booster.
     *
     * TODO: account for unclaimed rewards
     */
    function deposit(uint256 assets, address receiver) public virtual override nonReentrant returns (uint256) {

        // Transfer "asset" from sender
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);

        // Compute shares to mint for receiver
        uint256 mintShares = convertToShares(assets);

        // Update receiver shares
        _balances[receiver] = _balances[receiver] + mintShares;
        _totalSupply = _totalSupply + mintShares;

        // Deposit "asset" in reward pool
        IPool(rewardPool).deposit(assets, address(this));

        emit Deposit(msg.sender, receiver, assets, mintShares);
        return mintShares;
    }

    /**
     * @notice Mints exactly `shares` Vault shares to `receiver`
     * by depositing `assets` of underlying tokens.
     *
     * TODO: account for unclaimed rewards
     */
    function mint(uint256 shares, address receiver) external virtual override nonReentrant returns (uint256) {

        // Compute amount of assets to deposit
        uint256 depositAssets = convertToAssets();

        // Transfer "asset" from sender
        IERC20(asset).safeTransferFrom(msg.sender, address(this), depositAssets);

        // Update receiver shares
        _balances[receiver] = _balances[receiver] + shares;
        _totalSupply = _totalSupply + shares;

        // Deposit "asset" in reward pool
        IPool(rewardPool).deposit(depositAssets, address(this));

        emit Deposit(msg.sender, receiver, depositAssets, shares);
        return depositAssets;
    }

    /**
     * @notice Redeems `shares` from `owner` and sends `assets`
     * of underlying tokens to `receiver`.
     *
     * TODO: account for unclaimed rewards
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override nonReentrant returns (uint256) {

        // Compute shares to burn for owner
        uint256 burnShares = convertToShares(assets);

        // Check allowance
        if (msg.sender != owner) {
            _approve(owner, msg.sender, _allowances[owner][msg.sender].sub(burnShares, "ERC4626: withdrawal amount exceeds allowance"));
        }

        // Update owner shares
        // TODO: revert with explicit msg instead of underflow
        _balances[owner] = _balances[owner] - burnShares;
        _totalSupply = _totalSupply - burnShares;
        
        // Withdraw "asset" from Aura reward pool and send to "receiver"
        IPool(rewardPool).withdraw(assets, address(this), receiver);

        emit Withdraw(msg.sender, receiver, owner, assets, burnShares);
        return burnShares;
    }

    /**
     * @notice Redeems `shares` from `owner` and sends `assets`
     * of underlying tokens to `receiver`.
     *
     * TODO account for unclaimed rewards
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external virtual override returns (uint256) {

        // Check allowance
        if (msg.sender != owner) {
            _approve(owner, msg.sender, _allowances[owner][msg.sender].sub(shares, "ERC4626: withdrawal amount exceeds allowance"));
        }

        // Compute assets to withdraw
        uint256 withdrawAssets = convertToAssets(shares);

        // Update owner shares
        // TODO: revert with explicit msg instead of underflow
        _balances[owner] = _balances[owner] - shares;
        _totalSupply = _totalSupply - shares;
        
        // Withdraw "asset" from Aura reward pool and send to "receiver"
        IPool(rewardPool).withdraw(assets, address(this), receiver);

        emit Withdraw(msg.sender, receiver, owner, withdrawAssets, shares);
        return withdrawAssets;
    }

    /**
     * @notice The amount of shares that the vault would
     * exchange for the amount of assets provided, in an
     * ideal scenario where all the conditions are met.
     */
    function convertToShares(uint256 assets) public view virtual override returns (uint256) {
        return assets * _totalSupply / _totalAssets();
    }

    /**
     * @notice The amount of assets that the vault would
     * exchange for the amount of shares provided, in an
     * ideal scenario where all the conditions are met.
     */
    function convertToAssets(uint256 shares) public view virtual override returns (uint256) {
        return shares * _totalAssets() / _totalSupply;
    }

    /**
     * @notice Total number of underlying assets that can
     * be deposited by `owner` into the Vault, where `owner`
     * corresponds to the input parameter `receiver` of a
     * `deposit` call.
     */
    function maxDeposit(address /* owner */) public view virtual override returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @notice Allows an on-chain or off-chain user to simulate
     * the effects of their deposit at the current block, given
     * current on-chain conditions.
     */    
    function previewDeposit(uint256 assets) external view virtual override returns(uint256){
        return convertToShares(assets);
    }

    /**
     * @notice Total number of underlying shares that can be minted
     * for `owner`, where `owner` corresponds to the input
     * parameter `receiver` of a `mint` call.
     */
    function maxMint(address owner) external view virtual override returns (uint256) {
        return type(uint256).max;
    }

    /**    
     * @notice Allows an on-chain or off-chain user to simulate
     * the effects of their mint at the current block, given
     * current on-chain conditions.
     */
    function previewMint(uint256 shares) external view virtual override returns(uint256){
        return convertToAssets(shares);
    }

    /**
     * @notice Total number of underlying assets that can be
     * withdrawn from the Vault by `owner`, where `owner`
     * corresponds to the input parameter of a `withdraw` call.
     */
    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        return convertToAssets(maxRedeem(owner));
    }

    /**    
     * @notice Allows an on-chain or off-chain user to simulate
     * the effects of their withdrawal at the current block,
     * given current on-chain conditions.
     */
    function previewWithdraw(uint256 assets) public view virtual override returns(uint256 shares){
        return convertToShares(assets);
    }

    /**
     * @notice Total number of shares that can be
     * redeemed from the Vault by `owner`, where `owner` corresponds
     * to the input parameter of a `redeem` call.
     */
    function maxRedeem(address owner) external view virtual override returns (uint256) {
        return balanceOf(owner);
    }
    /**    
     * @notice Allows an on-chain or off-chain user to simulate
     * the effects of their redeemption at the current block,
     * given current on-chain conditions.
     */
    function previewRedeem(uint256 shares) external view virtual override returns(uint256){
        return convertToAssets(shares);
    }

    /* ========== Reward Compounding ========== */

    /**
     * @notice Allows anyone to claim accumulated rewards by depositing WETH instead
     * @param amounts An array of reward amounts to be claimed ordered as [rewardToken, secondaryRewardToken]
     * @param maxInAmount The max amount of WETH to be sent to the Vault
     */
    function claim(uint256[] amounts, uint256 maxAmountIn) external returns (uint256) {
        // Claim rewards from Aura reward pool
        IPool(rewardPool).getReward();

        // Compute lpToken amount to be sent to the Vault
        uint256 _amountIn;
        uint256 _rewardTokenOut = amounts[0] * (1e18 - lockerIncentive) / 1e18;
        uint256 _secondaryRewardTokenOut = amounts[1] * (1e18 - lockerIncentive) / 1e18;
        _amountIn = _rewardTokenOut * IFeed(_feed).price(rewardToken) / IFeed(_feed).price(lpToken);
        _amountIn = _amountIn + _secondaryRewardTokenOut * IFeed(_feed).price(secondaryRewardToken) / IFeed(_feed).price(lpToken);
        _amountIn = _amountIn * (1e18 - claimerIncentive) / 1e18;

        // Transfer lpToken to Vault
        require(_amountIn <= maxAmountIn, "!Slippage");
        IERC20(lpToken).safeTransferFrom(msg.sender, address(this), _amountIn);

        // Compound lpToken into "asset" balance
        IPool(rewardPool).deposit(_amountIn, address(this));

        // Collect "Locker" rewards
        IERC20(rewardToken).safeTransfer(lockerRewards, amounts[0] - _rewardTokenOut);
        IERC20(secondaryRewardToken).safeTransfer(lockerRewards, amounts[1] - _secondaryRewardTokenOut);

        // Transfer reward tokens to caller
        IERC20(rewardToken).safeTransfer(msg.sender, _rewardTokenOut);
        IERC20(secondaryRewardToken).safeTransfer(msg.sender, _secondaryRewardTokenOut);

        emit Claimed(msg.sender, amounts[0], amounts[1], _amountIn);
    }

    /* ========== Admin ========== */

    function setRewards(uint256 _claimerIncentive, uint256 _lockerIncentive, address _lockerRewards) public onlyRole(VAULT_ADMIN_ROLE)  returns (bool) {
        require (_claimerIncentive <= maxClaimerIncentive, "!Config");
        require (_lockerIncentive <= maxLockerIncentive, "!Config");
        require (_lockerRewards != address(0x0), "!Config");

        claimerIncentive = _claimerIncentive;
        lockerIncentive = _lockerIncentive;
        lockerRewards = _lockerRewards;

        return true;
    }

}
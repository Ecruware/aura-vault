// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC4626} from "openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC4626} from "openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20Permit} from "openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";

import {IFeed} from "./vendor/IEcruFeed.sol";
import {IPool} from "./vendor/IAuraPool.sol";
import {IVault} from "./interfaces/IVault.sol";

// Authenticated Roles
bytes32 constant VAULT_ADMIN_ROLE = keccak256("VAULT_ADMIN_ROLE");

/// @title AuraVault
/// @notice `A 4626 vault that compounds rewards from an Aura RewardsPool
contract AuraVault is IVault, ERC4626, AccessControl {
    using SafeERC20 for IERC20;

    /* ========== Constants ========== */

    /// @notice The Aura pool distributing rewards
    address public immutable rewardPool;

    /// @notice The primary reward token distributed in the Aura pool
    address public immutable rewardToken;

    /// @notice The secondary reward token distributed in the Aura pool
    address public immutable secondaryRewardToken;

    /// @notice The max permitted claimer incentive
    uint32 public immutable maxClaimerIncentive;

    /// @notice The max permitted locker incentive
    uint32 public immutable maxLockerIncentive;

    /// @notice The feed providing USD prices for asset, rewardToken and secondaryRewardToken
    address public immutable feed;

    /// @notice The incentive rates denomination
    uint256 public constant INCENTIVE_BASIS = 10000;

    /* ========== Storage ========== */

    struct VaultConfig {
        /// @notice The incentive sent to claimer (in bps)
        uint32 claimerIncentive;
        /// @notice The incentive sent to lockers (in bps)
        uint32 lockerIncentive;
        /// @notice The locker rewards distributor
        address lockerRewards;
    }
    /// @notice CDPVault configuration
    VaultConfig public vaultConfig;

    /* ========== Events ========== */

    /// @notice `caller` has exchanged `shares`, owned by `owner`, for
    ///         `assets`, and transferred those `assets` to `receiver`.
    event Claimed(
        address indexed caller,
        uint256 rewardTokenClaimed,
        uint256 secondaryRewardTokenClaimed,
        uint256 lpTokenCompounded
    );

    /* ========== Initialization ========== */

    // TODO: check inputs
    constructor(
        address rewardPool_,
        address asset_,
        address rewardToken_,
        address secondaryRewardToken_,
        address feed_,
        uint32 maxClaimerIncentive_,
        uint32 maxLockerIncentive_,
        string memory tokenName_,
        string memory tokenSymbol_
    ) ERC4626(IERC20(asset_)) ERC20(tokenName_, tokenSymbol_) {
        IERC20(asset()).safeApprove(rewardPool_, type(uint256).max);

        rewardPool = rewardPool_;
        rewardToken = rewardToken_;
        secondaryRewardToken = secondaryRewardToken_;
        feed = feed_;
        maxClaimerIncentive = maxClaimerIncentive_;
        maxLockerIncentive = maxLockerIncentive_;
    }

    /* ========== 4626 Vault ========== */

    /**
     * @notice Total amount of the underlying asset that is "managed" by Vault.
     */
    function totalAssets() public view virtual override(IERC4626, ERC4626) returns (uint256){
        return IPool(rewardPool).balanceOf(address(this));
    }

    /**
     * @notice Mints `shares` Vault shares to `receiver`.
     * @dev Because `asset` is not actually what is collected here, first wrap to required token in the booster.
     *
     * TODO: account for unclaimed rewards
     */
    function deposit(uint256 assets, address receiver) public virtual override(IERC4626, ERC4626) returns (uint256) {
        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);

        // Deposit  in reward pool
        IPool(rewardPool).deposit(assets, address(this));

        return shares;
    }

    /**
     * @notice Mints exactly `shares` Vault shares to `receiver`
     * by depositing `assets` of underlying tokens.
     *
     * TODO: account for unclaimed rewards
     */
    function mint(uint256 shares, address receiver) public virtual override(IERC4626, ERC4626) returns (uint256) {
        uint256 assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);

        // Deposit assets in reward pool
        IPool(rewardPool).deposit(assets, address(this));

        return assets;
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
    ) public virtual override(IERC4626, ERC4626) returns (uint256) {
        require(assets <= maxWithdraw(owner), "ERC4626: withdraw more than max");

        uint256 shares = previewWithdraw(assets);

        // Withdraw assets from Aura reward pool and send to "receiver"
        IPool(rewardPool).withdraw(assets, false);

        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return shares;
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
    ) public virtual override(IERC4626, ERC4626) returns (uint256) {
        require(shares <= maxRedeem(owner), "ERC4626: redeem more than max");

        uint256 assets = previewRedeem(shares);

        // Withdraw assets from Aura reward pool and send to "receiver"
        IPool(rewardPool).withdraw(assets, false);

        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return assets;
    }

    /* ========== Reward Compounding ========== */

    /**
     * @notice Allows anyone to claim accumulated rewards by depositing WETH instead
     * @param amounts An array of reward amounts to be claimed ordered as [rewardToken, secondaryRewardToken]
     * @param maxAmountIn The max amount of WETH to be sent to the Vault
     */
    function claim(uint256[] memory amounts, uint256 maxAmountIn) external returns (uint256) {
        // Claim rewards from Aura reward pool
        IPool(rewardPool).getReward();

        // Compute lpToken amount to be sent to the Vault
        VaultConfig memory _config = vaultConfig;
        uint256 _amountIn;
        uint256 _rewardTokenOut = amounts[0] * _config.lockerIncentive / INCENTIVE_BASIS;
        uint256 _secondaryRewardTokenOut = amounts[1] * _config.lockerIncentive / INCENTIVE_BASIS;
        _amountIn = _rewardTokenOut * IFeed(feed).price(rewardToken) / IFeed(feed).price(asset());
        _amountIn = _amountIn + _secondaryRewardTokenOut * IFeed(feed).price(secondaryRewardToken) / IFeed(feed).price(asset());
        _amountIn = _amountIn * _config.claimerIncentive / INCENTIVE_BASIS;

        // Transfer lpToken to Vault
        require(_amountIn <= maxAmountIn, "!Slippage");
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), _amountIn);

        // Compound lpToken into "asset" balance
        IPool(rewardPool).deposit(_amountIn, address(this));

        // Collect "Locker" rewards
        IERC20(rewardToken).safeTransfer(_config.lockerRewards, amounts[0] - _rewardTokenOut);
        IERC20(secondaryRewardToken).safeTransfer(_config.lockerRewards, amounts[1] - _secondaryRewardTokenOut);

        // Transfer reward tokens to caller
        IERC20(rewardToken).safeTransfer(msg.sender, _rewardTokenOut);
        IERC20(secondaryRewardToken).safeTransfer(msg.sender, _secondaryRewardTokenOut);

        emit Claimed(msg.sender, amounts[0], amounts[1], _amountIn);
    }

    /* ========== Admin ========== */

    function setVaultConfig(uint32 _claimerIncentive, uint32 _lockerIncentive, address _lockerRewards) public onlyRole(VAULT_ADMIN_ROLE)  returns (bool) {
        require (_claimerIncentive <= maxClaimerIncentive, "!Config");
        require (_lockerIncentive <= maxLockerIncentive, "!Config");
        require (_lockerRewards != address(0x0), "!Config");

        vaultConfig = VaultConfig({
            claimerIncentive: _claimerIncentive,
            lockerIncentive: _lockerIncentive,
            lockerRewards: _lockerRewards
        });

        return true;
    }

}
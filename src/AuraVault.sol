// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC4626} from "openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC4626} from "openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20Permit} from "openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";

import {AuraMath} from "./vendor/AuraMath.sol";
import {IFeed} from "./vendor/IEcruFeed.sol";
import {IPool} from "./vendor/IAuraPool.sol";
import {IVault} from "./interfaces/IVault.sol";

// Authenticated Roles
bytes32 constant VAULT_ADMIN_ROLE = keccak256("VAULT_ADMIN_ROLE");

/// @title AuraVault
/// @notice `A 4626 vault that compounds rewards from an Aura RewardsPool
contract AuraVault is IVault, ERC4626, AccessControl {
    using SafeERC20 for IERC20;
    using AuraMath for uint256;

    /* ========== Constants ========== */

    /// @notice The Aura pool distributing rewards
    address public immutable rewardPool;

    /// @notice The max permitted claimer incentive
    uint32 public immutable maxClaimerIncentive;

    /// @notice The max permitted locker incentive
    uint32 public immutable maxLockerIncentive;

    /// @notice The feed providing USD prices for asset, rewardToken and secondaryRewardToken
    address public immutable feed;

    /// @notice The incentive rates denomination
    uint256 private constant INCENTIVE_BASIS = 10000;

    /// @notice The BAL token
    address private constant BAL = 0xba100000625a3754423978a60c9317c58a424e3D;

    /// @notice The AURA token
    address private constant AURA = 0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF;

    // Utilities for AURA mining calcs
    uint256 private constant EMISSIONS_MAX_SUPPLY = 5e25; // 50m
    uint256 private constant INIT_MINT_AMOUNT = 5e25; // 50m
    uint256 private constant TOTAL_CLIFFS = 500;
    uint256 private constant REDUCTION_PER_CLIFF = 1e23; 

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
        address feed_,
        uint32 maxClaimerIncentive_,
        uint32 maxLockerIncentive_,
        string memory tokenName_,
        string memory tokenSymbol_
    ) ERC4626(IERC20(asset_)) ERC20(tokenName_, tokenSymbol_) {
        IERC20(asset_).safeApprove(rewardPool_, type(uint256).max);

        rewardPool = rewardPool_;
        feed = feed_;
        maxClaimerIncentive = maxClaimerIncentive_;
        maxLockerIncentive = maxLockerIncentive_;
    }

    /* ========== 4626 Vault ========== */

    /**
     * @notice Total amount of the underlying asset that is "managed" by Vault.
     */
    function totalAssets() public view virtual override(IERC4626, ERC4626) returns (uint256){
        return IPool(rewardPool).balanceOf(address(this)) + previewReward();
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
    function claim(uint256[] memory amounts, uint256 maxAmountIn) external returns (uint256 amountIn) {
        // Claim rewards from Aura reward pool
        IPool(rewardPool).getReward();

        // Compute lpToken amount to be sent to the Vault
        VaultConfig memory _config = vaultConfig;
        amountIn = _previewReward(amounts[0], amounts[1], _config);

        // Transfer lpToken to Vault
        require(amountIn <= maxAmountIn, "!Slippage");
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amountIn);

        // Compound lpToken into "asset" balance
        IPool(rewardPool).deposit(amountIn, address(this));

        // Collect "Locker" rewards
        IERC20(BAL).safeTransfer(_config.lockerRewards, amounts[0] * _config.lockerIncentive / INCENTIVE_BASIS);
        IERC20(AURA).safeTransfer(_config.lockerRewards, amounts[1] * _config.lockerIncentive / INCENTIVE_BASIS);

        // Transfer reward tokens to caller
        IERC20(BAL).safeTransfer(msg.sender, amounts[0]);
        IERC20(AURA).safeTransfer(msg.sender, amounts[1]);

        emit Claimed(msg.sender, amounts[0], amounts[1], amountIn);
    }

    function previewReward() public view returns (uint256 amount) {
        VaultConfig memory config = vaultConfig;
        uint256 balReward = IPool(rewardPool).earned(address(this)) + IERC20(BAL).balanceOf(address(this));
        uint256 auraReward = _previewMining(balReward) + IERC20(AURA).balanceOf(address(this));
        amount = _previewReward(balReward, auraReward, config);
    }

    function _previewReward(uint256 balReward, uint256 auraReward, VaultConfig memory config) private view returns (uint256 amount) {
        amount = balReward * IFeed(feed).price(BAL) / IFeed(feed).price(asset());
        amount = amount + auraReward * IFeed(feed).price(AURA) / IFeed(feed).price(asset());
        amount = amount * (INCENTIVE_BASIS - config.claimerIncentive) / INCENTIVE_BASIS;
    }

    /**
     * @dev Calculates the amount of AURA to mint based on the BAL supply schedule
     * See https://etherscan.io/token/0xc0c293ce456ff0ed870add98a0828dd4d2903dbf#code
     */
    function _previewMining(uint256 _amount) private view returns (uint256 amount) {
        uint256 supply = IERC20(AURA).totalSupply();
        uint256 minterMinted = 0; // TODO: fetch
        uint256 emissionsMinted = supply - INIT_MINT_AMOUNT - minterMinted;

        uint256 cliff = emissionsMinted.div(REDUCTION_PER_CLIFF);

        // e.g. 100 < 500
        if (cliff < TOTAL_CLIFFS) {
            // e.g. (new) reduction = (500 - 100) * 2.5 + 700 = 1700;
            // e.g. (new) reduction = (500 - 250) * 2.5 + 700 = 1325;
            // e.g. (new) reduction = (500 - 400) * 2.5 + 700 = 950;
            uint256 reduction = TOTAL_CLIFFS.sub(cliff).mul(5).div(2).add(700);
            // e.g. (new) amount = 1e19 * 1700 / 500 =  34e18;
            // e.g. (new) amount = 1e19 * 1325 / 500 =  26.5e18;
            // e.g. (new) amount = 1e19 * 950 / 500  =  19e17;
            amount = _amount.mul(reduction).div(TOTAL_CLIFFS);
            // e.g. amtTillMax = 5e25 - 1e25 = 4e25
            uint256 amtTillMax = EMISSIONS_MAX_SUPPLY.sub(emissionsMinted);
            if (amount > amtTillMax) {
                amount = amtTillMax;
            }
        }
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
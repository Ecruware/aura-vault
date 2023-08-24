// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import "src/AuraVault.sol";

contract AuraVaultTest is Test {
    AuraVault vault;
        address rewardPool_ = address(0x1);
        address asset_ = address(0x2);
        address rewardToken_ = address(0x3);
        address secondaryRewardToken_ = address(0x4);
        address feed_ = address(0x5);
        uint32 maxClaimerIncentive_ = 9500;
        uint32 maxLockerIncentive_ = 9000;
        string tokenName_ = "AuraVault";
        string tokenSymbol_ = "AUVA";

    function setUp() public {
        vault = new AuraVault(
            rewardPool_,
            asset_,
            rewardToken_,
            secondaryRewardToken_,
            feed_,
            maxClaimerIncentive_,
            maxLockerIncentive_,
            tokenName_,
            tokenSymbol_
        );
    }

    function testBar() public {
        assertEq(uint256(1), uint256(1), "ok");
    }

    function testFoo(uint256 x) public {
        vm.assume(x < type(uint128).max);
        assertEq(x + x, x * 2);
    }
}

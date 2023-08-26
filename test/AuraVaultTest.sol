// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import "src/AuraVault.sol";

contract AuraVaultTest is Test {
    AuraVault vault;
    address rewardPool_ = address(0x1);
    address asset_ = address(0x2);
    address feed_ = address(0x3);
    uint32 maxClaimerIncentive_ = 100;
    uint32 maxLockerIncentive_ = 100;
    string tokenName_ = "Aura Vault";
    string tokenSymbol_ = "auraVault";

    function setUp() public {
        vault = new AuraVault(
            rewardPool_,
            asset_,
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20Permit} from "openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IFeed} from "../vendor/IERC4626.sol";

interface IERC20Mintable {
    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;
}

interface IVault is IERC20Mintable, IERC20Metadata, IERC20Permit, IERC4626 {}
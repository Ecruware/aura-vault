// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20Permit} from "openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC4626} from "openzeppelin/contracts/interfaces/IERC4626.sol";


interface IVault is IERC4626 {}
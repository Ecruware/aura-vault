// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @dev Basic external oracle interface
interface IOracle {
    function spot(address token) external view returns (uint256);
    function getStatus(address token) external view returns (bool);
}
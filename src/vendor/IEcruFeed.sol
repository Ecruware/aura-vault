// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IFeed{
    function price(address feed) external view returns (uint256);
}
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IStrategy {
    function deposit() external;
    function withdraw(uint256) external;
    function balanceLPinStrategy() external view returns (uint256);
    function decommissionStrategy() external;
    function harvest() external;
    function getRewardsEarned() external view returns (uint256);
}